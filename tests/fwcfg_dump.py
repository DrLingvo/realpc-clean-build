#!/usr/bin/env python3
"""Start QEMU in qtest mode (no guest code runs, no KVM needed) and read fw_cfg files
through the fw_cfg I/O ports, exactly as firmware would.

usage: fwcfg_dump.py OUTDIR -- qemu-system-x86_64 [args...]
Writes every fw_cfg file under OUTDIR (slashes replaced by '_') and prints the list.
QEMU must be started with "-qtest stdio" among its args.
"""
import json
import os
import struct
import subprocess
import sys

outdir = sys.argv[1]
assert sys.argv[2] == "--"
cmdline = sys.argv[3:]
os.makedirs(outdir, exist_ok=True)

p = subprocess.Popen(cmdline, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)


def cmd(c):
    p.stdin.write(c + "\n")
    p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line:
            raise SystemExit(f"qemu exited unexpectedly with status {p.poll()}")
        if line.startswith("OK") or line.startswith("FAIL"):
            return line.split()
        # QEMU diagnostics share stdout with qtest in this test harness.
        print(line, end="", flush=True)


def select(key):
    cmd(f"outw 0x510 {key:#x}")


def read(n):
    out = bytearray()
    while n:
        k = min(n, 4)
        # 'inb' one byte at a time; data port is byte-wide
        for _ in range(k):
            out.append(int(cmd("inb 0x511")[1], 16))
        n -= k
    return bytes(out)


select(0x0)
sig = read(4)
print("fw_cfg signature:", sig)
open(os.path.join(outdir, "_signature"), "wb").write(sig)
select(0x19)
count = struct.unpack(">I", read(4))[0]
files = []
for _ in range(count):
    size, sel, _r = struct.unpack(">IHH", read(8))
    name = read(56).split(b"\0")[0].decode()
    files.append((name, sel, size))
for name, sel, size in files:
    if size > 2 * 1024 * 1024:
        print(f"skip {name} ({size} bytes)")
        continue
    select(sel)
    data = read(size)
    open(os.path.join(outdir, name.replace("/", "_")), "wb").write(data)
    print(f"{name} {size}")


def pci_read(bus, device, function, offset):
    address = 0x80000000 | (bus << 16) | (device << 11) | (function << 8) | offset
    cmd(f"outl 0xcf8 {address:#x}")
    return int(cmd("inl 0xcfc")[1], 16)


# Capture the actual bus-0 identities as well as fw_cfg. This lets check.py verify
# the type-41 BDF and reject QEMU's 1b36 vendor instead of checking only strings.
pci = []
for device in range(32):
    for function in range(8):
        identity = pci_read(0, device, function, 0)
        vendor, device_id = identity & 0xFFFF, identity >> 16
        if vendor == 0xFFFF:
            continue
        class_code = (pci_read(0, device, function, 8) >> 16) & 0xFFFF
        pci.append({"bus": 0, "device": device, "function": function,
                    "vendor_id": vendor, "device_id": device_id,
                    "class_code": class_code})
with open(os.path.join(outdir, "pci.json"), "w", encoding="utf-8") as stream:
    json.dump(pci, stream, indent=2, sort_keys=True)
    stream.write("\n")
print(f"PCI bus 0: {len(pci)} functions")
p.kill()
