#!/usr/bin/env python3
"""Checks on the installed packages. Exit code 1 if any check fails.

usage: check.py FWCFG_DIR OVMF_EXTRACT_DIR QEMU_BINARY
"""
import json
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
# EisaId() stores PNP IDs as little-endian compressed EISA values, not ASCII.
pnp_ids = {
    "PNP0C02": b"\x41\xd0\x0c\x02",  # HSEN motherboard resources
    "PNP0C0B": b"\x41\xd0\x0c\x0b",  # ACPI fan devices
}
check(b"HSEN" in acpi, "ACPI contains the host-sensor device HSEN")
for name, encoded in pnp_ids.items():
    check(encoded in acpi, f"ACPI contains required sensor object {name}")
for name in (b"_TMP", b"_FST"):
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
for want in (7, 17, 26, 27, 28, 39, 41):
    check(want in types, f"SMBIOS type {want} present")
check(29 not in types, "SMBIOS has no synthetic electrical-current-probe type 29")
check(sum(ty == 7 for ty, _, _ in tables) >= 4,
      "SMBIOS contains host-derived L1/L2/L3 cache records")
check(sum(ty != 127 for ty, _, _ in tables) >= 12,
      "SMBIOS contains the expected real structure groups")
handles = [struct.unpack_from("<H", body, 2)[0] for _, _, body in tables if len(body) >= 4]
check(len(handles) == len(set(handles)), "SMBIOS structure handles are unique")
type7_handles = {struct.unpack_from("<H", body, 2)[0]
                 for ty, _, body in tables if ty == 7 and len(body) >= 4}
for ty, ss, body in tables:
    if ty in (26, 28):
        check(len(body) == 0x16, f"SMBIOS type {ty} has complete 0x16-byte structure")
    if ty == 27:
        check(len(body) == 0x0f, "SMBIOS type 27 has complete 0x0f-byte structure")
        check(struct.unpack_from("<H", body, 4)[0] in (0x1c00, 0x1c01),
              "SMBIOS cooling device links to a real temperature probe")
    if ty == 39:
        check(len(body) == 0x16, "SMBIOS type 39 has complete 0x16-byte structure")
        check(struct.unpack_from("<HHH", body, 0x10) == (0xFFFF, 0xFFFF, 0xFFFF),
              "SMBIOS PSU does not invent voltage, fan, or current probes")
    if ty == 28:
        maximum = struct.unpack_from("<H", body, 6)[0]
        minimum = struct.unpack_from("<H", body, 8)[0]
        nominal = struct.unpack_from("<H", body, 0x14)[0]
        check(0 <= minimum <= nominal <= maximum <= 1200,
              "SMBIOS temperature probe uses plausible tenths-of-Celsius values")
    if ty == 4 and len(body) >= 32:
        cache_links = struct.unpack_from("<HHH", body, 0x1a)
        check(set(cache_links) <= type7_handles,
              "SMBIOS processor cache handles link to generated type 7 records")
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


def table_string(strings, index):
    return strings[index - 1] if 0 < index <= len(strings) else ""


dimms = [(ss, body) for ty, ss, body in tables if ty == 17 and len(body) >= 0x1b]
check(len(dimms) >= 2, "SMBIOS memory test contains at least two DIMM instances")
for label, offset in (("serial", 0x18), ("asset", 0x19), ("bank", 0x11)):
    identities = [table_string(ss, body[offset]) for ss, body in dimms]
    check(all(identities) and len(identities) == len(set(identities)),
          f"SMBIOS DIMM {label} values are populated and unique per instance")

# ---------------------------------------------------------------- PCI / type 41
with open(os.path.join(fw, "pci.json"), encoding="utf-8") as stream:
    pci = json.load(stream)
pci_by_bdf = {(entry["bus"], entry["device"], entry["function"]): entry for entry in pci}
check(all(entry["vendor_id"] != 0x1B36 for entry in pci),
      "PCI bus 0 contains no QEMU VEN_1B36 function")
check(any(entry["vendor_id"] == 0x8086 and entry["device_id"] == 0x10D3
          for entry in pci), "PCI bus 0 contains the requested Intel e1000e NIC")
type41 = [(ss, body) for ty, ss, body in tables if ty == 41 and len(body) >= 0x0b]
check(len(type41) == 1, "SMBIOS has exactly one onboard-LAN type 41 record")
for ss, body in type41:
    bdf = (body[9], body[0x0a] >> 3, body[0x0a] & 7)
    nic = pci_by_bdf.get(bdf)
    check(nic is not None and nic["vendor_id"] == 0x8086 and nic["device_id"] == 0x10D3,
          "SMBIOS type 41 BDF resolves to the actual e1000e PCI function")
    check(table_string(ss, body[4]) == "Onboard LAN",
          "SMBIOS type 41 has the onboard-LAN designation")

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
