#!/usr/bin/env python3
"""Import real PCI/SMBIOS dumps into a board/socket-scoped identity map.

This changes identity metadata only. It does not claim to emulate the imported chipset.
Collect inputs on the physical host:
  lspci -D -vmmnn > lspci-vmmnn.txt
  dmidecode -t baseboard -t processor > dmidecode-board.txt
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROLES = {
    "00:00.0": "host_bridge",
    "00:1f.0": "lpc",
    "00:1f.2": "sata",
    "00:17.0": "sata",
    "00:1f.3": "hda",
    "00:1f.4": "smbus",
}


def parse_lspci(text):
    devices = []
    for block in re.split(r"\n\s*\n", text.strip()):
        item = {}
        for line in block.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                item[key.strip()] = value.strip()
        slot = item.get("Slot", "")
        role = ROLES.get(slot[-7:])
        if not role:
            continue
        try:
            record = {
                "role": role,
                "bdf": slot,
                "vendor": int(item["Vendor"], 16),
                "device": int(item["Device"], 16),
                "subvendor": int(item.get("SVendor", "ffff"), 16),
                "subdevice": int(item.get("SDevice", "ffff"), 16),
            }
        except (KeyError, ValueError) as exc:
            raise ValueError(f"incomplete numeric lspci record for {slot}") from exc
        devices.append(record)
    if not any(item["role"] == "host_bridge" for item in devices):
        raise ValueError("the dump has no host bridge at 00:00.0")
    if not any(item["role"] == "lpc" for item in devices):
        raise ValueError("the dump has no LPC/eSPI bridge at 00:1f.0")
    return devices


def smbios_values(text):
    values = {}
    for line in text.splitlines():
        match = re.match(r"\s*(Manufacturer|Product Name|Socket Designation):\s*(.*?)\s*$", line)
        if match and match.group(2) not in ("Not Specified", "Default string"):
            values.setdefault(match.group(1), match.group(2))
    return values


def import_dump(lspci_text, dmidecode_text):
    smbios = smbios_values(dmidecode_text)
    missing = [key for key in ("Manufacturer", "Product Name", "Socket Designation")
               if not smbios.get(key)]
    if missing:
        raise ValueError("dmidecode is missing: " + ", ".join(missing))
    socket = smbios["Socket Designation"].upper().replace(" ", "")
    return {
        "board": {"manufacturer": smbios["Manufacturer"],
                  "product": smbios["Product Name"], "socket": socket},
        "evidence": {"lspci_sha256": hashlib.sha256(lspci_text.encode()).hexdigest(),
                     "dmidecode_sha256": hashlib.sha256(dmidecode_text.encode()).hexdigest()},
        "devices": parse_lspci(lspci_text),
        "behavior": "identity-only; QEMU device models and chipset behavior are unchanged",
    }


def board_key(board):
    return "|".join((board["manufacturer"], board["product"], board["socket"].upper()))


def merge(existing, imported):
    records = list(existing.get("records", []))
    key = board_key(imported["board"])
    records = [record for record in records if board_key(record["board"]) != key]
    records.append(imported)
    records.sort(key=lambda record: board_key(record["board"]))
    return {"schema": 1, "records": records}


def find_record(document, manufacturer, product, socket):
    key = board_key({"manufacturer": manufacturer, "product": product, "socket": socket})
    return next((record for record in document.get("records", [])
                 if board_key(record["board"]) == key), None)


def subsystem_identity(record, role="lpc"):
    device = next((item for item in record["devices"] if item["role"] == role), None)
    if not device or device["subvendor"] in (0, 0xFFFF) or device["subdevice"] == 0xFFFF:
        raise ValueError(f"no real subsystem identity for {role}")
    return device["subvendor"], device["subdevice"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lspci", required=True)
    parser.add_argument("--dmidecode", required=True)
    parser.add_argument("--map", required=True)
    args = parser.parse_args()
    lspci = Path(args.lspci).read_text(encoding="utf-8")
    dmidecode = Path(args.dmidecode).read_text(encoding="utf-8")
    path = Path(args.map)
    existing = json.loads(path.read_text()) if path.exists() else {"schema": 1, "records": []}
    result = merge(existing, import_dump(lspci, dmidecode))
    path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"imported {board_key(import_dump(lspci, dmidecode)['board'])} into {path}")


if __name__ == "__main__":
    main()
