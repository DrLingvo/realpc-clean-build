#!/usr/bin/env python3
"""Validate the read-only host-sensor I/O device without running guest code."""
import subprocess
import sys

assert sys.argv[1] == "--"
p = subprocess.Popen(sys.argv[2:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)

def cmd(command):
    p.stdin.write(command + "\n")
    p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line:
            raise SystemExit("QEMU exited unexpectedly while testing host sensors")
        if line.startswith("FAIL"):
            raise SystemExit(f"qtest {command!r} failed: {line.strip()}")
        if line.startswith("OK"):
            return line.split()

try:
    values = {}
    for offset in range(0, 0x20, 4):
        parts = cmd(f"inl {0x610 + offset:#x}")
        values[offset] = int(parts[1], 16)
    for offset, value in values.items():
        assert 0 <= value <= 0xFFFFFFFF, (offset, value)
    for offset in (0x00, 0x04):
        value = values[offset]
        assert value == 0xFFFFFFFF or 2000 <= value <= 4000, (offset, value)
    for offset in (0x08, 0x0C, 0x10, 0x14):
        assert values[offset] == 0xFFFFFFFF or values[offset] <= 100000
    assert values[0x1C] <= 7
    print("PASS host-sensor I/O registers and fallback ranges", values)
finally:
    p.kill()
