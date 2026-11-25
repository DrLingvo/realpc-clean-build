#!/usr/bin/env python3
"""Deterministic, vendor-coherent ATA/SATA identity for one virtual disk."""
import argparse
import hashlib
import hmac
import json

# Exact decimal-byte capacities and ATA LBA counts. Do not round these values.
SKUS = (
    {"vendor": "Samsung", "model": "Samsung SSD 860 EVO 500GB",
     "firmware": "RVT04B6Q", "bytes": 500107862016, "lba": 976773168,
     "wwn_oui": 0x002538},
    {"vendor": "Samsung", "model": "Samsung SSD 870 EVO 1TB",
     "firmware": "SVT02B6Q", "bytes": 1000204886016, "lba": 1953525168,
     "wwn_oui": 0x002538},
    {"vendor": "Crucial", "model": "CT1000MX500SSD1",
     "firmware": "M3CR046", "bytes": 1000204886016, "lba": 1953525168,
     "wwn_oui": 0x00A075},
    {"vendor": "Western Digital", "model": "WDC WDS500G2B0A-00SM50",
     "firmware": "415020WD", "bytes": 500107862016, "lba": 976773168,
     "wwn_oui": 0x001B44},
)


def digest(vmid, disk, purpose):
    if not str(vmid) or not str(disk):
        raise ValueError("VM and disk identifiers must not be empty")
    key = hashlib.sha256(f"realpc-disk-v1:{vmid}".encode()).digest()
    return hmac.new(key, f"{disk}:{purpose}".encode(), hashlib.sha256).hexdigest()


def disk_identity(vmid, disk, size_bytes):
    candidates = [sku for sku in SKUS if sku["bytes"] == size_bytes]
    if not candidates:
        supported = ", ".join(str(sku["bytes"]) for sku in SKUS)
        raise ValueError(f"disk size {size_bytes} has no exact supported SKU; sizes: {supported}")
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
