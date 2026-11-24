#!/usr/bin/env python3
"""Render a coherent Strong-real PVE main section without touching snapshots."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("disk_identity", HERE / "disk_identity.py")
DISK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DISK)
SPEC = importlib.util.spec_from_file_location("smbios_tables", HERE / "smbios_tables.py")
SMBIOS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMBIOS)
BAD_OUIS = {"52:54:00", "BC:24:11"}
BAD_ARGS = ("virtio", "spice", "qemu-xhci", "pvpanic", "pcie-pci-bridge")


def split_main(text):
    lines = text.splitlines(keepends=True)
    end = next((i for i, line in enumerate(lines) if line.startswith("[")), len(lines))
    return lines[:end], lines[end:]


def values(main):
    result = {}
    for line in main:
        match = re.match(r"^([A-Za-z0-9]+):\s*(.*?)\s*$", line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def volume_size(value):
    volume = value.split(",", 1)[0]
    path = subprocess.run(["pvesm", "path", volume], check=True, text=True,
                          capture_output=True).stdout.strip()
    if Path(path).is_block_device():
        return int(subprocess.run(["blockdev", "--getsize64", path], check=True,
                                  text=True, capture_output=True).stdout.strip())
    info = subprocess.run(["qemu-img", "info", "--output=json", path], check=True,
                          text=True, capture_output=True)
    return int(json.loads(info.stdout)["virtual-size"])


def collect_sizes(main):
    result = {}
    for key, value in values(main).items():
        if re.fullmatch(r"(?:sata|scsi|virtio)\d+", key):
            result[key] = volume_size(value)
    return result


def put(main, key, value):
    main[:] = [line for line in main if not line.startswith(key + ":")]
    if value is not None:
        main.append(f"{key}: {value}\n")


def render(text, profile, sizes, acpi_dir, fragment_args=""):
    main, snapshots = split_main(text)
    current = values(main)
    summary = profile["summary"]
    if summary["cpu_source"] != "host":
        raise ValueError("configvm accepts only a Strong-real host profile")
    cpu_arg = re.search(r'-smbios type=4,.*?version="([^"]+)"', profile["args"])
    if not cpu_arg or cpu_arg.group(1) != summary["cpu"]:
        raise ValueError("SMBIOS type 4 does not match the host CPU profile")
    topology = summary.get("topology")
    if not topology or any(not isinstance(topology.get(key), int) or topology[key] < 1
                           for key in ("sockets", "cores", "threads")):
        raise ValueError("Strong-real profile requires observed host topology")
    if not current.get("net0"):
        raise ValueError("net0 is required so the generated coherent MAC can be applied")
    try:
        memory_mb = int(current["memory"])
        module_mb = int(summary["memory_module_mb"])
    except (KeyError, ValueError) as exc:
        raise ValueError("memory and the profile DIMM module size are required") from exc
    if memory_mb < module_mb or memory_mb % module_mb:
        raise ValueError(f"memory must be a positive multiple of the {module_mb} MiB DIMM kit")

    for key, value in current.items():
        if re.fullmatch(r"net\d+", key):
            mac = re.search(r"\b([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})\b", value)
            if mac and mac.group(1).upper()[:8] in BAD_OUIS:
                raise ValueError(f"{key} uses a Proxmox/QEMU OUI: {mac.group(1)}")
    net = current["net0"].split(",")
    mac_index = next((i for i, item in enumerate(net) if item.startswith("mac=")), None)
    if mac_index is not None:
        net.pop(mac_index)
    net[0] = "e1000e"
    net.append("mac=" + summary["mac"])
    put(main, "net0", ",".join(net))

    disk_args = []
    disks = sorted((key for key in current if re.fullmatch(r"(?:sata|scsi|virtio)\d+", key)),
                   key=lambda key: (int(re.search(r"\d+", key).group()), key))
    for old_key in disks:
        index = re.search(r"\d+", old_key).group()
        key = "sata" + index
        if key != old_key and key in current:
            raise ValueError(f"cannot convert {old_key}: {key} already exists")
        if old_key not in sizes:
            raise ValueError(f"exact byte size is required for {old_key}")
        identity = DISK.disk_identity(summary.get("vmid", current.get("vmid", "vm")), key,
                                      sizes[old_key])
        value = current[old_key]
        put(main, old_key, None)
        put(main, key, value)
        disk_args.append(f"-set device.{key}." + DISK.qemu_properties(identity))

    put(main, "machine", "q35")
    put(main, "bios", "ovmf")
    put(main, "localtime", "1")
    put(main, "tablet", "0")
    put(main, "agent", "0")
    put(main, "balloon", "0")
    put(main, "cpu", "host")
    put(main, "sockets", str(topology["sockets"]))
    put(main, "cores", str(topology["cores"]))
    put(main, "threads", str(topology["threads"]))
    put(main, "vcpus", None)
    put(main, "scsihw", None)
    put(main, "smbios1", "uuid=" + summary["uuid"])
    if not any(re.match(r"hostpci\d+:", line) and "00:02.0" in line for line in main):
        put(main, "vga", "std")

    args = profile["args"]
    for path in summary.get("smbios_files", []):
        args += " -smbios file=" + shlex.quote(path)
    if summary["host_vendor"] == "intel":
        args += " -device host-sensors"
    args += " " + " ".join(disk_args)
    args = f"-acpitable file={acpi_dir}/ssdt.aml -acpitable file={acpi_dir}/wsmt.aml " + args
    if fragment_args:
        args += " " + fragment_args.strip()
    lowered = args.lower()
    for marker in BAD_ARGS:
        if marker in lowered:
            raise ValueError(f"forbidden virtual device in args: {marker}")
    put(main, "args", args)
    return "".join(main + snapshots)


def main_cli():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--sizes", help="JSON disk byte sizes; default queries PVE storage")
    parser.add_argument("--acpi-dir", required=True)
    parser.add_argument("--fragment-args", default="")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    text = Path(args.config).read_text()
    main, _ = split_main(text)
    sizes = json.loads(Path(args.sizes).read_text()) if args.sizes else collect_sizes(main)
    profile = json.loads(Path(args.profile).read_text())
    SMBIOS.write_profile_records(profile, Path(args.profile).parent)
    result = render(text, profile, sizes, args.acpi_dir, args.fragment_args)
    Path(args.out).write_text(result)


if __name__ == "__main__":
    main_cli()
