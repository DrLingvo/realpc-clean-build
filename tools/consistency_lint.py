#!/usr/bin/env python3
"""Fail closed on cross-layer Strong-real configuration inconsistencies."""
import argparse
import json
from pathlib import Path
import re
import shlex
import sys

BAD_OUIS = {"52:54:00", "BC:24:11"}
BAD_ARGS = ("virtio", "spice", "qemu-xhci", "pvpanic", "pcie-pci-bridge")


def main_section(text):
    return text.split("\n[", 1)[0]


def values(text):
    result = {}
    for line in main_section(text).splitlines():
        match = re.match(r"^([A-Za-z0-9]+):\s*(.*?)\s*$", line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def smbios_options(args, record_type):
    return [token for token in args if token.startswith(f"type={record_type},")]


def require(errors, condition, message):
    if not condition:
        errors.append(message)


def lint(text, profile, require_files=True):
    errors = []
    current = values(text)
    summary = profile["summary"]
    args_line = current.get("args", "")
    try:
        args = shlex.split(args_line)
    except ValueError as exc:
        return [f"invalid args quoting: {exc}"]
    require(errors, summary.get("cpu_source") == "host", "profile is not Strong-real")
    require(errors, current.get("cpu") == "host", "PVE cpu is not host")
    require(errors, current.get("machine") == "q35", "machine is not q35")
    require(errors, current.get("bios") == "ovmf", "BIOS is not OVMF")
    for key, expected in (("agent", "0"), ("balloon", "0"), ("tablet", "0")):
        require(errors, current.get(key) == expected, f"{key} must be 0")
    topology = summary.get("topology") or {}
    for key in ("sockets", "cores", "threads"):
        require(errors, current.get(key) == str(topology.get(key)), f"{key} differs from host topology")
    require(errors, "vcpus" not in current, "vcpus limits the host-coherent topology")

    type4 = smbios_options(args, 4)
    require(errors, len(type4) == 1, "exactly one SMBIOS type 4 override is required")
    if type4:
        match = re.search(r'version="?([^",]+)', type4[0])
        require(errors, bool(match) and match.group(1) == summary.get("cpu"),
                "type 4 version differs from host CPU")
        require(errors, "processor-id=" + summary.get("processor_id", "missing") in type4[0],
                "type 4 processor ID differs from host")
    require(errors, current.get("smbios1") == "uuid=" + summary.get("uuid", ""),
            "smbios1 UUID differs from profile")
    type1 = smbios_options(args, 1)
    require(errors, len(type1) == 1 and "uuid=" + summary.get("uuid", "") in type1[0],
            "type 1 UUID differs from profile")

    cpu = next((args[i + 1] for i, token in enumerate(args[:-1]) if token == "-cpu"), "")
    for option in ("host", "host-cache-info=on", "hypervisor=off", "vmware-cpuid-freq=false", "pmu=on"):
        require(errors, option in cpu.split(","), f"CPU option {option} is missing")
    for marker in BAD_ARGS:
        require(errors, marker not in args_line.lower(), f"forbidden virtual device marker: {marker}")

    net0 = current.get("net0", "")
    require(errors, net0.startswith("e1000e=") or net0.startswith("e1000e,"),
            "net0 is not e1000e")
    require(errors, "mac=" + summary.get("mac", "") in net0, "net0 MAC differs from profile")
    mac = re.search(r"\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b", net0)
    require(errors, bool(mac) and mac.group(1).upper()[:8] not in BAD_OUIS,
            "net0 has a Proxmox/QEMU OUI")
    require(errors, any("type=41," in token and "pcidev=net0" in token for token in args),
            "type 41 does not reference net0")

    disks = sorted(key for key in current if re.fullmatch(r"(?:sata|scsi|virtio)\d+", key))
    for key in disks:
        require(errors, key.startswith("sata"), f"disk {key} is not SATA")
        prop = next((args[i + 1] for i, token in enumerate(args[:-1])
                     if token == "-set" and args[i + 1].startswith("device." + key + ".")), "")
        for field in ("model=", "serial=", "version=", "wwn="):
            require(errors, field in prop, f"{key} ATA identity lacks {field}")
    try:
        memory = int(current["memory"])
        module = int(summary["memory_module_mb"])
        require(errors, memory > 0 and memory % module == 0,
                "memory is not a whole number of profile DIMMs")
    except (KeyError, ValueError):
        errors.append("invalid memory or DIMM size")

    type17 = smbios_options(args, 17)
    require(errors, len(type17) == 1, "one per-DIMM type 17 template is required")
    if type17:
        expected_part = profile.get("env", {}).get("MEM_PART", "")
        require(errors, expected_part and f"part={expected_part}" in type17[0],
                "type 17 part number differs from profile")
    # shlex keeps 'file=path' as one token after '-smbios' or '-acpitable'.
    file_args = [token[5:] for token in args if token.startswith("file=")
                 and Path(token[5:]).name.startswith("smbios")]
    require(errors, len([path for path in file_args if "smbios7-" in path]) == len(summary.get("caches", [])),
            "type 7 files do not match host cache count")
    chassis_name = "smbios22-battery.bin" if summary.get("chassis_type") == 10 else "smbios39-psu.bin"
    require(errors, any(path.endswith(chassis_name) for path in file_args),
            f"missing chassis record {chassis_name}")
    if require_files:
        for path in file_args:
            require(errors, Path(path).is_file() and Path(path).stat().st_size > 0,
                    f"missing or empty SMBIOS file {path}")
        for name in ("ssdt.aml", "wsmt.aml"):
            require(errors, any(token.startswith("file=") and
                                Path(token[5:]).name == name and Path(token[5:]).is_file()
                                for token in args), f"missing ACPI table {name}")
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--no-file-checks", action="store_true")
    args = parser.parse_args()
    text = Path(args.config).read_text(encoding="utf-8")
    profile = json.loads(Path(args.profile).read_text(encoding="utf-8"))
    errors = lint(text, profile, not args.no_file_checks)
    for error in errors:
        print("FAIL:", error, file=sys.stderr)
    if errors:
        raise SystemExit(1)
    print("PASS: PCI, SMBIOS, ACPI, CPU, memory, disk and network layers are coherent")


if __name__ == "__main__":
    main()
