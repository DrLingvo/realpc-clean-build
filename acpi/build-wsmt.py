#!/usr/bin/env python3
"""Build a valid Windows SMM Security Mitigations Table with no claimed flags."""
from pathlib import Path
import struct
import sys

out = Path(sys.argv[1] if len(sys.argv) > 1 else "wsmt.aml")
length = 40
header = struct.pack(
    "<4sIBB6s8sI4sI",
    b"WSMT",
    length,
    2,
    0,
    b"INTEL ",
    b"DESKTOP ",
    1,
    b"INTL",
    0x20260301,
)
table = bytearray(header + struct.pack("<I", 0))
table[9] = (-sum(table)) & 0xFF
assert len(table) == length and sum(table) & 0xFF == 0
out.write_bytes(table)
