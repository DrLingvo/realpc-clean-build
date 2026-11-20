#!/usr/bin/env python3
"""Write a plain 24-bit BMP (solid colour) for the OVMF boot logo.

Proxmox ships its own logo (visible at boot = VM indicator); the author ships an image
of his own. A boot logo is parsed by firmware code (see the LogoFAIL vulnerabilities),
so this kit generates one locally instead of using someone else's file.
usage: make-logo.py OUT.bmp [WIDTH HEIGHT [RRGGBB]]
"""
import struct
import sys

out = sys.argv[1]
w = int(sys.argv[2]) if len(sys.argv) > 2 else 684
h = int(sys.argv[3]) if len(sys.argv) > 3 else 451
rgb = bytes.fromhex(sys.argv[4]) if len(sys.argv) > 4 else b"\x00\x00\x00"
row = (bytes((rgb[2], rgb[1], rgb[0])) * w).ljust((w * 3 + 3) // 4 * 4, b"\0")
pixels = row * h
hdr = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
dib = struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
with open(out, "wb") as f:
    f.write(hdr + dib + pixels)
