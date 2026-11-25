#!/usr/bin/env python3
import importlib.util
import json
import shlex
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VM = load("vm_config", ROOT / "tools" / "vm-config.py")
GEN = load("gen_profile", ROOT / "tools" / "gen-profile.py")
HOST_CPU = "Intel(R) Core(TM) i7-10700T CPU @ 2.00GHz"


def profile():
    _, args, summary, _, _ = GEN.gen(
        "intel_desktop_lga1200", "neutral", 1, host_vendor="intel",
        host_cpu_model=HOST_CPU)
    summary["vmid"] = "100"
    return {"summary": summary, "args": args, "env": {}}


class VmConfigTest(unittest.TestCase):
    def setUp(self):
        self.config = """memory: 16384
cores: 8
net0: virtio=02:F0:5D:01:02:03,bridge=vmbr0
virtio0: local:100/vm-100-disk-0.qcow2
agent: 1
balloon: 2048
tablet: 1
scsihw: virtio-scsi-single
vga: qxl
[snapshot]
args: snapshot-must-not-change
"""
        self.sizes = {"virtio0": 500107862016}

    def test_hygiene_sata_mac_and_snapshot_preservation(self):
        generated = profile()
        result = VM.render(self.config, generated, self.sizes, "/root/realpc", "")
        self.assertIn("net0: e1000e,bridge=vmbr0,mac=" + generated["summary"]["mac"], result)
        self.assertIn("sata0: local:100/vm-100-disk-0.qcow2", result)
        self.assertNotIn("virtio0:", result)
        self.assertNotIn("scsihw:", result)
        for setting in ("agent: 0", "balloon: 0", "tablet: 0", "vga: std"):
            self.assertIn(setting, result)
        args = shlex.split(next(line[6:] for line in result.splitlines()
                                if line.startswith("args: ")))
        disk_set = args[args.index("-set") + 1]
        self.assertTrue(disk_set.startswith(
            "device.sata0.model=Samsung SSD 860 EVO 500GB,serial="))
        self.assertIn(",version=RVT04B6Q,wwn=0x", disk_set)
        self.assertIn("[snapshot]\nargs: snapshot-must-not-change\n", result)
        self.assertIn('version="' + HOST_CPU + '"', result)
        topology = generated["summary"]["topology"]
        self.assertIn(f"sockets: {topology['sockets']}", result)
        self.assertIn(f"cores: {topology['cores']}", result)
        self.assertIn(f"threads: {topology['threads']}", result)
        self.assertIn("host-cache-info=on", result)
        self.assertIn("vmware-cpuid-freq=false", result)
        self.assertIn("smbios1: uuid=" + generated["summary"]["uuid"], result)
        self.assertIn("uuid=" + generated["summary"]["uuid"], result)
        self.assertIn("pcidev=net0", result)

    def test_qemu_and_proxmox_ouis_are_rejected(self):
        for oui in ("52:54:00:01:02:03", "BC:24:11:01:02:03"):
            with self.subTest(oui=oui), self.assertRaises(ValueError):
                VM.render(self.config.replace("02:F0:5D:01:02:03", oui),
                          profile(), self.sizes, "/acpi")

    def test_vgpu_vga_and_hostpci_are_preserved(self):
        config = self.config + "hostpci0: 00:02.0\nvga: none\n"
        result = VM.render(config, profile(), self.sizes, "/acpi",
                           "-set device.hostpci0.addr=02.0")
        self.assertIn("hostpci0: 00:02.0", result)
        self.assertIn("vga: none", result)
        self.assertIn("-set device.hostpci0.addr=02.0", result)

    def test_skin_profile_and_forbidden_devices_fail_closed(self):
        bad = profile()
        bad["summary"]["cpu_source"] = "model"
        with self.assertRaises(ValueError):
            VM.render(self.config, bad, self.sizes, "/acpi")
        with self.assertRaises(ValueError):
            VM.render(self.config, profile(), self.sizes, "/acpi", "-device pvpanic")
        missing_topology = profile()
        missing_topology["summary"].pop("topology")
        with self.assertRaises(ValueError):
            VM.render(self.config, missing_topology, self.sizes, "/acpi")

    def test_unknown_disk_size_fails_closed(self):
        with self.assertRaises(ValueError):
            VM.render(self.config, profile(), {}, "/acpi")
        with self.assertRaises(ValueError):
            VM.render(self.config.replace("memory: 16384", "memory: 8192"),
                      profile(), self.sizes, "/acpi")

    def test_cdrom_is_preserved_without_a_disk_size_query(self):
        for cdrom in ("none,media=cdrom", "local:iso/windows.iso,media=cdrom"):
            with self.subTest(cdrom=cdrom):
                config = self.config.replace("agent: 1", f"sata1: {cdrom}\nagent: 1")
                main, _ = VM.split_main(config)
                with mock.patch.object(VM, "volume_size", return_value=500107862016) as query:
                    sizes = VM.collect_sizes(main)
                self.assertEqual(sizes, self.sizes)
                query.assert_called_once_with("local:100/vm-100-disk-0.qcow2")
                result = VM.render(config, profile(), sizes, "/acpi")
                self.assertIn(f"sata1: {cdrom}\n", result)
                self.assertNotIn("device.sata1.", result)

    def test_empty_qemu_img_json_fails_closed_with_volume_context(self):
        volume = "local:101/vm-101-disk-0.qcow2"
        path = "/var/lib/vz/images/101/vm-101-disk-0.qcow2"

        def fake_run(command, **kwargs):
            if command[:2] == ["pvesm", "path"]:
                return VM.subprocess.CompletedProcess(command, 0, stdout=path + "\n", stderr="")
            if command[:2] == ["qemu-img", "info"]:
                return VM.subprocess.CompletedProcess(command, 0, stdout="", stderr="")
            raise AssertionError(command)

        with mock.patch.object(VM.subprocess, "run", side_effect=fake_run):
            with self.assertRaisesRegex(ValueError, "qemu-img info returned empty output.*" + volume):
                VM.volume_size(volume)

    def test_invalid_qemu_img_virtual_size_fails_closed(self):
        for stdout in ("not-json", "{}", '{"virtual-size": 0}', '{"virtual-size": true}'):
            with self.subTest(stdout=stdout):
                with mock.patch.object(VM.Path, "is_block_device", return_value=False), \
                     mock.patch.object(VM.subprocess, "run", side_effect=(
                         VM.subprocess.CompletedProcess(["pvesm"], 0, stdout="/tmp/disk.qcow2\n"),
                         VM.subprocess.CompletedProcess(["qemu-img"], 0, stdout=stdout))):
                    with self.assertRaisesRegex(ValueError, "qemu-img info"):
                        VM.volume_size("local:101/vm-101-disk-0.qcow2")


if __name__ == "__main__":
    unittest.main()
