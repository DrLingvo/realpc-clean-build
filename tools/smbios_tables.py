#!/usr/bin/env python3
"""Build per-VM SMBIOS binary records from observed host hardware data."""
import json
from pathlib import Path
import struct

CACHE_TYPES = {"Instruction": 3, "Data": 4, "Unified": 5}
ASSOCIATIVITY = {
    1: 3, 2: 4, 4: 5, 8: 6, 12: 9, 16: 7, 20: 11, 24: 10,
    32: 16, 48: 12, 64: 13, 96: 14, 128: 15,
}


def cache_size_field(size_kb):
    if not 0 < size_kb < 0x8000000:
        raise ValueError("invalid cache size")
    if size_kb < 32768:
        return size_kb
    if size_kb % 64:
        raise ValueError("large cache size is not representable in 64 KiB units")
    return 0x8000 | (size_kb // 64)


def cache_record(cache, instance):
    level = int(cache["level"])
    size = cache_size_field(int(cache["size_kb"]))
    ways = int(cache["ways"])
    if level not in (1, 2, 3) or cache["type"] not in CACHE_TYPES:
        raise ValueError("unsupported cache level or type")
    if ways not in ASSOCIATIVITY:
        raise ValueError(f"unknown SMBIOS encoding for {ways}-way associativity")
    designation = f'L{level} {cache["type"]} Cache'.encode("ascii")
    # SMBIOS 2.1 type 7, 19-byte formatted area. Fields not exposed by lscpu
    # (SRAM and error correction) remain unknown rather than invented.
    formatted = struct.pack(
        "<BBHBHHHHHBBBB",
        7, 19, 0x0700 + instance, 1, 0x180 | (level - 1),
        size, size, 0, 0, 0, 2, CACHE_TYPES[cache["type"]], ASSOCIATIVITY[ways],
    )
    return formatted + designation + b"\0\0"


def write_cache_records(profile, directory):
    caches = profile["summary"].get("caches")
    if not caches:
        raise ValueError("Strong-real profile has no observed host cache records")
    paths = []
    for instance, cache in enumerate(caches):
        path = Path(directory) / f"smbios7-{instance}.bin"
        path.write_bytes(cache_record(cache, instance))
        paths.append(str(path))
    profile["summary"]["smbios_files"] = paths
    return paths


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    profile = json.loads(Path(args.profile).read_text(encoding="utf-8"))
    for path in write_cache_records(profile, args.out):
        print(path)


if __name__ == "__main__":
    main()
