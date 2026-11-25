#!/usr/bin/env python3
"""Deterministic, vendor-coherent ATA/SATA identity for one virtual disk."""
__version__ = "1.2.0"  # bump on every change to this script
import argparse
import hashlib
import hmac
import json

# Exact decimal-byte capacities and ATA LBA counts of real SATA SSDs. Do not round these
# values: lba == bytes // 512, and both must match a genuine retail drive so a detector that
# maps model -> known capacity cannot find a mismatch. Model/firmware strings are plausible
# per vendor family; verify exact firmware revisions against real units before trusting them
# against a firmware-database detector. New sizes can be added freely (keep lba == bytes//512).
SKUS = (
    # ~60 GB (budget / older)
    {"vendor": "Kingston", "model": "KINGSTON SV300S37A60G",
     "firmware": "600ABBF0", "bytes": 60022480896, "lba": 117231408, "wwn_oui": 0x0026B7},
    # 120 GB
    {"vendor": "Kingston", "model": "KINGSTON SA400S37120G",
     "firmware": "SBFKB1D1", "bytes": 120034123776, "lba": 234441648, "wwn_oui": 0x0026B7},
    # 240 GB
    {"vendor": "Kingston", "model": "KINGSTON SA400S37240G",
     "firmware": "SBFKB1D1", "bytes": 240057409536, "lba": 468862128, "wwn_oui": 0x0026B7},
    # 250 GB
    {"vendor": "Samsung", "model": "Samsung SSD 870 EVO 250GB",
     "firmware": "SVT02B6Q", "bytes": 250059350016, "lba": 488397168, "wwn_oui": 0x002538},
    {"vendor": "Crucial", "model": "CT250MX500SSD1",
     "firmware": "M3CR046", "bytes": 250059350016, "lba": 488397168, "wwn_oui": 0x00A075},
    {"vendor": "Western Digital", "model": "WDC WDS250G2B0A-00SM50",
     "firmware": "415020WD", "bytes": 250059350016, "lba": 488397168, "wwn_oui": 0x001B44},
    # 256 GB
    {"vendor": "Samsung", "model": "Samsung SSD 850 PRO 256GB",
     "firmware": "EXM02B6Q", "bytes": 256060514304, "lba": 500118192, "wwn_oui": 0x002538},
    # 480 GB
    {"vendor": "Kingston", "model": "KINGSTON SA400S37480G",
     "firmware": "SBFKB1D1", "bytes": 480103981056, "lba": 937703088, "wwn_oui": 0x0026B7},
    # 500 GB
    {"vendor": "Samsung", "model": "Samsung SSD 860 EVO 500GB",
     "firmware": "RVT04B6Q", "bytes": 500107862016, "lba": 976773168, "wwn_oui": 0x002538},
    {"vendor": "Western Digital", "model": "WDC WDS500G2B0A-00SM50",
     "firmware": "415020WD", "bytes": 500107862016, "lba": 976773168, "wwn_oui": 0x001B44},
    {"vendor": "Crucial", "model": "CT500MX500SSD1",
     "firmware": "M3CR046", "bytes": 500107862016, "lba": 976773168, "wwn_oui": 0x00A075},
    # 512 GB
    {"vendor": "Samsung", "model": "Samsung SSD 860 PRO 512GB",
     "firmware": "RVM02B6Q", "bytes": 512110190592, "lba": 1000215216, "wwn_oui": 0x002538},
    # 1 TB
    {"vendor": "Samsung", "model": "Samsung SSD 870 EVO 1TB",
     "firmware": "SVT02B6Q", "bytes": 1000204886016, "lba": 1953525168, "wwn_oui": 0x002538},
    {"vendor": "Crucial", "model": "CT1000MX500SSD1",
     "firmware": "M3CR046", "bytes": 1000204886016, "lba": 1953525168, "wwn_oui": 0x00A075},
    {"vendor": "Western Digital", "model": "WDC WDS100T2B0A-00SM50",
     "firmware": "415020WD", "bytes": 1000204886016, "lba": 1953525168, "wwn_oui": 0x001B44},
    # 2 TB
    {"vendor": "Samsung", "model": "Samsung SSD 870 EVO 2TB",
     "firmware": "SVT02B6Q", "bytes": 2000398934016, "lba": 3907029168, "wwn_oui": 0x002538},
    {"vendor": "Crucial", "model": "CT2000MX500SSD1",
     "firmware": "M3CR046", "bytes": 2000398934016, "lba": 3907029168, "wwn_oui": 0x00A075},
    # 4 TB
    {"vendor": "Samsung", "model": "Samsung SSD 870 EVO 4TB",
     "firmware": "SVT02B6Q", "bytes": 4000787030016, "lba": 7814037168, "wwn_oui": 0x002538},
)


def nearest_sku_up(size_bytes):
    """Smallest real SKU capacity (bytes) >= size_bytes, or None if nothing is large enough.
    Grow-only: resizing a disk up is always safe, shrinking would truncate data."""
    larger = sorted({sku["bytes"] for sku in SKUS if sku["bytes"] >= size_bytes})
    return larger[0] if larger else None


def digest(vmid, disk, purpose):
    if not str(vmid) or not str(disk):
        raise ValueError("VM and disk identifiers must not be empty")
    key = hashlib.sha256(f"realpc-disk-v1:{vmid}".encode()).digest()
    return hmac.new(key, f"{disk}:{purpose}".encode(), hashlib.sha256).hexdigest()


def disk_identity(vmid, disk, size_bytes, allow_inexact=False):
    candidates = [sku for sku in SKUS if sku["bytes"] == size_bytes]
    if not candidates:
        if not allow_inexact:
            supported = ", ".join(str(sku["bytes"]) for sku in SKUS)
            raise ValueError(f"disk size {size_bytes} has no exact supported SKU; sizes: {supported}")
        # testing shortcut (--skip-disk-size): keep a coherent vendor identity but accept that
        # the model's implied capacity will not match the actual (round) disk size. This is a
        # real tell; only for exercising the rest of the release on block storage.
        target = nearest_sku_up(size_bytes) or max(sku["bytes"] for sku in SKUS)
        candidates = [sku for sku in SKUS if sku["bytes"] == target]
    selector = int(digest(vmid, disk, "sku")[:8], 16)
    sku = dict(candidates[selector % len(candidates)])
    serial_hash = digest(vmid, disk, "serial").upper()
    if sku["vendor"] == "Samsung":
        serial = "S" + serial_hash[:15]
    elif sku["vendor"] == "Crucial":
        serial = serial_hash[:16]
    else:
        serial = serial_hash[:18]
    wwn = (0x5000000000000000 | (sku["wwn_oui"] << 36) |
           (int(digest(vmid, disk, "wwn")[:9], 16) & 0xFFFFFFFFF))
    sku.update(vmid=str(vmid), disk=str(disk), serial=serial, wwn=f"0x{wwn:016x}")
    return sku


def qemu_properties(identity):
    return (f"model={identity['model']},serial={identity['serial']},"
            f"version={identity['firmware']},wwn={identity['wwn']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("vmid")
    parser.add_argument("disk")
    parser.add_argument("size_bytes", type=int)
    parser.add_argument("--qemu", action="store_true")
    args = parser.parse_args()
    identity = disk_identity(args.vmid, args.disk, args.size_bytes)
    print(qemu_properties(identity) if args.qemu else json.dumps(identity, indent=2))


if __name__ == "__main__":
    main()
