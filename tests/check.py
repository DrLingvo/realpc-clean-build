#!/usr/bin/env python3
"""Checks on the installed packages. Exit code 1 if any check fails.

usage: check.py FWCFG_DIR OVMF_EXTRACT_DIR QEMU_BINARY
"""
import os
import re
import sys

fw, ovmf_dir, qemu_bin = sys.argv[1:4]
failed = 0


def check(ok, what):
    global failed
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failed += 1


def fwfile(name):
    return open(os.path.join(fw, name.replace("/", "_")), "rb").read()


# ---------------------------------------------------------------- fw_cfg / ACPI
acpi = fwfile("etc/acpi/tables")
for bad in (b"BOCHS", b"BXPC", b"QEMU", b"WAET", b"VMGENID", b"FWCF"):
    check(bad not in acpi, f"ACPI tables contain no {bad.decode()!r}")
sigs = set(m.group(0).decode() for m in re.finditer(rb"(SSDT|DSDT|FACP|APIC|HPET|MCFG|SRAT|WSMT)", acpi))
print("     ACPI signatures seen:", sorted(sigs))
print("     fw_cfg signature:", fwfile("_signature"))

# ---------------------------------------------------------------- SMBIOS
t = fwfile("etc/smbios/smbios-tables")
tables = []
i = 0
while i < len(t):
    ty, ln = t[i], t[i + 1]
    j = i + ln
    end = t.index(b"\0\0", j)
    strs = [s.decode(errors="replace") for s in t[j:end].split(b"\0")] if end > j else []
    tables.append((ty, strs))
    i = end + 2
    if ty == 127:
        break
types = sorted(set(ty for ty, _ in tables))
print("     SMBIOS types:", types)
allstr = " | ".join(s for _, ss in tables for s in ss)
print("     SMBIOS strings:", allstr[:600])
for want in (7, 9, 17, 26, 27, 28, 29, 39):
    check(want in types, f"SMBIOS type {want} present")
for bad in ("QEMU", "Bochs", "BOCHS", "pc-q35", "pc-i440fx", "aiiaicodo", "Standard PC"):
    check(bad not in allstr, f"SMBIOS strings contain no {bad!r}")

# ---------------------------------------------------------------- QEMU binary strings
blob = open(qemu_bin, "rb").read()
for bad in (b"QEMU HARDDISK", b"QEMU DVD-ROM", b"QEMU Virtual CPU", b"KVMKVMKVM\0",
            b"QEMU USB Tablet", b"aiiaicodo", b"114514", b"BOCHS ", b"BXPC"):
    check(bad not in blob, f"qemu-system-x86_64 contains no {bad!r}")
# host-sensors is compiled in when the qemu build ran with HOST_SENSORS=1 (CI does this)
check(b"host-sensors" in blob, "qemu-system-x86_64 exposes the host-sensors CPU property")

# ---------------------------------------------------------------- OVMF
found_proxmox = False
found_qemu_video = False
modules = 0
for dp, dn, fn in os.walk(ovmf_dir):
    for f in fn:
        if f.endswith((".pe", ".te")):
            modules += 1
        b = open(os.path.join(dp, f), "rb").read()
        if "Proxmox".encode("utf-16le") in b or b"Proxmox" in b:
            found_proxmox = True
        if "QemuVideoDxe".encode("utf-16le") in b:
            found_qemu_video = True
check(modules >= 100, f"OVMF image was unpacked ({modules} PE/TE modules found)")
check(not found_proxmox, "OVMF contains no 'Proxmox' string (firmware vendor replaced)")
check(not found_qemu_video, "OVMF module QemuVideoDxe renamed")

print(f"\n{failed} check(s) failed")
sys.exit(1 if failed else 0)
