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
        expected = VM.DISK.disk_identity("100", "sata0", 500107862016)
        self.assertEqual(expected["bytes"], 500107862016)
        self.assertTrue(disk_set.startswith(
            f"device.sata0.model={expected['model']},serial="))
        self.assertIn(f",version={expected['firmware']},wwn=0x", disk_set)
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

    def test_net0_proxmox_oui_is_replaced_not_rejected(self):
        # net0's MAC is regenerated from the profile, so a stock Proxmox/QEMU OUI there
        # must be accepted and overwritten with the coherent MAC, not rejected.
        generated = profile()
        config = self.config.replace("02:F0:5D:01:02:03", "BC:24:11:7A:59:25")
        result = VM.render(config, generated, self.sizes, "/root/realpc", "")
        self.assertIn("net0: e1000e,bridge=vmbr0,mac=" + generated["summary"]["mac"],
                      result)
        self.assertNotIn("BC:24:11:7A:59:25", result)

    def test_bad_oui_on_an_untouched_nic_is_rejected(self):
        # interfaces other than net0 are left as-is, so a stock OUI there is a real leak.
        for oui in ("52:54:00:01:02:03", "BC:24:11:01:02:03"):
            config = self.config.replace(
                "[snapshot]", f"net1: e1000e={oui},bridge=vmbr1\n[snapshot]")
            with self.subTest(oui=oui), self.assertRaises(ValueError):
                VM.render(config, profile(), self.sizes, "/acpi")

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

    def test_inactive_lvm_thin_uses_exact_pvesm_metadata_size(self):
        volume = "local-lvm:vm-101-disk-1"
        listing = """Volid                         Format Type   Size         VMID
local-lvm:vm-101-disk-1       raw    images 500107862016 101
local-lvm:vm-101-disk-10      raw    images 999999999999 101
"""
        with mock.patch.object(VM.subprocess, "run", return_value=(
                VM.subprocess.CompletedProcess(["pvesm"], 0, stdout=listing))) as query:
            self.assertEqual(VM.volume_size(volume), 500107862016)
        self.assertEqual(query.call_args.args[0], ["pvesm", "list", "local-lvm"])

    def test_pvesm_size_requires_one_exact_positive_integer(self):
        volume = "local-lvm:vm-101-disk-1"
        cases = (
            ("missing", "Volid Format Type Size VMID\n", "exactly one"),
            ("duplicate", f"{volume} raw images 1024 101\n{volume} raw images 1024 101\n", "exactly one"),
            ("approximate", f"{volume} raw images ~1024 101\n", "exact integer"),
            ("zero", f"{volume} raw images 0 101\n", "non-positive"),
            ("not-a-size", f"{volume} raw images unknown 101\n", "exact integer"),
        )
        for name, stdout, message in cases:
            with self.subTest(name=name), mock.patch.object(VM.subprocess, "run", return_value=(
                    VM.subprocess.CompletedProcess(["pvesm"], 0, stdout=stdout))):
                with self.assertRaisesRegex(ValueError, message):
                    VM.volume_size(volume)


class SkipDiskSizeTest(unittest.TestCase):
    def setUp(self):
        self.config = """memory: 16384
cores: 8
net0: virtio=02:F0:5D:01:02:03,bridge=vmbr0
virtio0: local-lvm:vm-100-disk-0
agent: 1
[snapshot]
args: snapshot-must-not-change
"""

    def test_allow_inexact_picks_nearest_real_sku(self):
        ident = VM.DISK.disk_identity("100", "sata0", 137438953472, allow_inexact=True)
        self.assertEqual(ident["bytes"], 240057409536)  # 128 GiB rounds up to a real 240 GB
        self.assertTrue(ident["model"] and ident["serial"] and ident["firmware"])

    def test_non_sku_size_raises_without_skip_but_renders_with_it(self):
        gen = profile()
        sizes = {"virtio0": 137438953472}  # 128 GiB, not an exact real SKU
        with self.assertRaises(ValueError):
            VM.render(self.config, gen, sizes, "/acpi", "")
        result = VM.render(self.config, gen, sizes, "/acpi", "", allow_inexact=True)
        args = shlex.split(next(line[6:] for line in result.splitlines()
                                if line.startswith("args: ")))
        disk_set = args[args.index("-set") + 1]
        self.assertTrue(disk_set.startswith("device.sata0.model="))
        for field in ("model=", "serial=", "version=", "wwn="):
            self.assertIn(field, disk_set)


class DiskResizeTest(unittest.TestCase):
    def _run_factory(self, path="/tmp/vm-100-disk-0.raw"):
        calls = []

        def run(cmd, **kwargs):
            calls.append(cmd)
            if cmd[:2] == ["pvesm", "path"]:
                return VM.subprocess.CompletedProcess(cmd, 0, stdout=path + "\n")
            return VM.subprocess.CompletedProcess(cmd, 0, stdout="")
        return run, calls

    def test_grows_file_disk_up_to_nearest_sku(self):
        main, _ = VM.split_main("scsi0: files:100/vm-100-disk-0.raw,size=128G\n")
        run, calls = self._run_factory()
        with mock.patch.object(VM, "volume_size",
                               side_effect=[137438953472, 240057409536]), \
                mock.patch.object(VM.os.path, "isfile", return_value=True):
            resized = VM.resize_disks_up(main, vmid="100", run=run)
        self.assertEqual(resized, [("scsi0", 137438953472, 240057409536)])
        self.assertIn(["qemu-img", "resize", "/tmp/vm-100-disk-0.raw", "240057409536"], calls)
        self.assertIn(["qm", "rescan", "--vmid", "100"], calls)

    def test_block_storage_is_rejected(self):
        main, _ = VM.split_main("scsi0: local-lvm:vm-100-disk-0,size=128G\n")
        run, _ = self._run_factory(path="/dev/pve/vm-100-disk-0")
        with mock.patch.object(VM, "volume_size", return_value=137438953472), \
                mock.patch.object(VM.os.path, "isfile", return_value=False):
            with self.assertRaisesRegex(ValueError, "block storage"):
                VM.resize_disks_up(main, run=run)

    def test_size_over_largest_sku_fails_closed(self):
        main, _ = VM.split_main("scsi0: files:100/vm-100-disk-0.raw\n")
        run, _ = self._run_factory()
        with mock.patch.object(VM, "volume_size", return_value=5 * 10 ** 12):
            with self.assertRaisesRegex(ValueError, "exceeds the largest known SKU"):
                VM.resize_disks_up(main, run=run)

    def test_exact_sku_is_left_untouched(self):
        main, _ = VM.split_main("scsi0: files:100/vm-100-disk-0.raw\n")
        run, calls = self._run_factory()
        with mock.patch.object(VM, "volume_size", return_value=500107862016):
            resized = VM.resize_disks_up(main, run=run)
        self.assertEqual(resized, [])
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
