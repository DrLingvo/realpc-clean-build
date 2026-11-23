#!/usr/bin/env python3
"""Checks on the installed packages. Exit code 1 if any check fails.

usage: check.py FWCFG_DIR OVMF_EXTRACT_DIR QEMU_BINARY
"""
import os
import re
import struct
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
check("WSMT" in sigs, "ACPI WSMT table is present")
facp = acpi.find(b"FACP")
check(facp >= 0 and acpi[facp + 45] == 1, "FADT preferred PM profile is desktop (1)")
for name in (b"PNP0C14", b"PNP0C0C", b"PNP0C0E", b"PNP0D80", b"_TMP", b"_FST"):
    check(name in acpi, f"ACPI contains required power/sensor object {name.decode()}")

# ---------------------------------------------------------------- SMBIOS
t = fwfile("etc/smbios/smbios-tables")
tables = []
i = 0
while i < len(t):
    ty, ln = t[i], t[i + 1]
    j = i + ln
    end = t.index(b"\0\0", j)
    strs = [s.decode(errors="replace") for s in t[j:end].split(b"\0")] if end > j else []
    tables.append((ty, strs, t[i:j]))
    i = end + 2
    if ty == 127:
        break
types = sorted(set(ty for ty, _, _ in tables))
print("     SMBIOS types:", types)
allstr = " | ".join(s for _, ss, _ in tables for s in ss)
print("     SMBIOS strings:", allstr[:600])
for want in (7, 8, 9, 17, 26, 27, 28, 29, 39):
    check(want in types, f"SMBIOS type {want} present")
check(sum(ty != 127 for ty, _, _ in tables) > 40, "SMBIOS contains more than 40 real structures")
check(sum(ty == 8 for ty, _, _ in tables) >= 12, "SMBIOS type 8 has populated port instances")
check(sum(ty == 9 for ty, _, _ in tables) >= 12, "SMBIOS type 9 has populated slot instances")
handles = [struct.unpack_from("<H", body, 2)[0] for _, _, body in tables if len(body) >= 4]
check(len(handles) == len(set(handles)), "SMBIOS structure handles are unique")
for ty, ss, body in tables:
    if ty in (26, 28, 29):
        check(len(body) == 0x16, f"SMBIOS type {ty} has complete 0x16-byte structure")
    if ty == 27:
        check(len(body) == 0x0f, "SMBIOS type 27 has complete 0x0f-byte structure")
        check(struct.unpack_from("<H", body, 4)[0] in (0x1c00, 0x1c01),
              "SMBIOS cooling device links to a real temperature probe")
    if ty == 39:
        check(len(body) == 0x16, "SMBIOS type 39 has complete 0x16-byte structure")
        check(struct.unpack_from("<HHH", body, 0x10) == (0x1a01, 0x1b01, 0x1d00),
              "SMBIOS PSU links to valid voltage, fan, and current probes")
    if ty == 28:
        maximum = struct.unpack_from("<H", body, 6)[0]
        minimum = struct.unpack_from("<H", body, 8)[0]
        nominal = struct.unpack_from("<H", body, 0x14)[0]
        check(0 <= minimum <= nominal <= maximum <= 1200,
              "SMBIOS temperature probe uses plausible tenths-of-Celsius values")
    if ty == 4 and len(body) >= 32:
        check(struct.unpack_from("<HHH", body, 0x1a) == (0x0700, 0x0702, 0x0703),
              "SMBIOS processor cache handles link to type 7 records")
for bad in ("QEMU", "Bochs", "BOCHS", "pc-q35", "pc-i440fx", "aiiaicodo", "Standard PC"):
    check(bad not in allstr, f"SMBIOS strings contain no {bad!r}")
# memory profile must be self-consistent (no DDR3 / no laptop SODIMM on a desktop board)
for ty, ss, body in tables:
    if ty == 17 and len(body) > 0x17:
        ff, mt = body[0x0e], body[0x12]
        memnames = {0x18: "DDR3", 0x1a: "DDR4", 0x22: "DDR5"}
        print(f"     SMBIOS type17: memory_type=0x{mt:02x} ({memnames.get(mt,'?')}) form_factor=0x{ff:02x}")
        check(mt != 0x18, "SMBIOS memory is not DDR3 (author default was DDR3-1600)")
        check(ff != 0x0d, "SMBIOS memory form factor is not SODIMM (laptop) on a desktop board")

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
