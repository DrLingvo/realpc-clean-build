#!/usr/bin/env python3
import importlib.util
import json
import os
import random
import re
import sys
import tempfile
import unittest
import uuid
from unittest import mock
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "tools" / "gen-profile.py"
SPEC = importlib.util.spec_from_file_location("gen_profile", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProfileTest(unittest.TestCase):
    def setUp(self):
        random.seed(12345)

    def socket_fixture(self, text):
        return mock.patch.object(
            MODULE.subprocess, "run",
            return_value=MODULE.subprocess.CompletedProcess(
                ["dmidecode", "-t", "processor"], 0, stdout=text, stderr=""))

    def test_oem_socket_designation_uses_smbios_upgrade(self):
        dmi = """
Processor Information
        Socket Designation: U3E1
        Version: Intel(R) Core(TM) i7-10700T CPU @ 2.00GHz
        Upgrade: Socket LGA1200
"""
        with self.socket_fixture(dmi):
            self.assertEqual(MODULE.detect_host_socket(), "LGA1200")

    def test_known_socket_designation_is_preserved(self):
        dmi = "Processor Information\n        Socket Designation: LGA1700\n        Upgrade: Other\n"
        with self.socket_fixture(dmi):
            self.assertEqual(MODULE.detect_host_socket(), "LGA1700")

    def test_oem_designation_without_upgrade_is_not_guessed(self):
        dmi = "Processor Information\n        Socket Designation: U3E1\n        Upgrade: Other\n"
        with self.socket_fixture(dmi):
            self.assertEqual(MODULE.detect_host_socket(), "U3E1")

    def test_vendor_mismatch_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.gen("amd_desktop_am5", "neutral", 1, host_vendor="intel")
        with self.assertRaises(ValueError):
            MODULE.gen("intel_desktop_lga1700", "neutral", 1, host_vendor="amd")

    def test_host_sensors_follow_real_host_vendor(self):
        _, intel_args, _, _, _ = MODULE.gen(
            "intel_desktop_lga1700", "neutral", 1, host_vendor="intel",
            host_cpu_model="Intel(R) Core(TM) i7-10700T CPU @ 2.00GHz")
        self.assertIn("host-sensors=on", intel_args)
        _, amd_args, _, _, _ = MODULE.gen(
            "amd_desktop_am5", "neutral", 1, host_vendor="amd",
            host_cpu_model="AMD Ryzen 7 7700 8-Core Processor")
        self.assertNotIn("host-sensors=on", amd_args)
        _, unknown_args, _, _, _ = MODULE.gen(
            "intel_desktop_lga1700", "neutral", 1, host_vendor="unknown",
            host_cpu_model="Test Host CPU")
        self.assertNotIn("host-sensors=on", unknown_args)

    def test_generated_uuid_is_rfc4122_version_4(self):
        _, args, _, _, _ = MODULE.gen(
            "intel_desktop_lga1700", "neutral", 0, host_vendor="intel",
            host_cpu_model="Intel(R) Core(TM) i7-10700T CPU @ 2.00GHz")
        value = re.search(r"uuid=([0-9a-f-]+)", args).group(1)
        parsed = uuid.UUID(value)
        self.assertEqual(parsed.version, 4)
        self.assertEqual(parsed.variant, uuid.RFC_4122)

    def test_every_platform_generates_with_matching_host(self):
        for platform in MODULE.PLATFORMS:
            with self.subTest(platform=platform):
                _, args, _, _, _ = MODULE.gen(
                    platform, "gaming", 1, host_vendor=MODULE.platform_vendor(platform),
                    host_cpu_model="Exact Host CPU")
                self.assertIn("-cpu host", args)
                self.assertRegex(args, r'-smbios type=4,[^\n]*manufacturer=')
                self.assertIn('version="Exact Host CPU"', args)
                self.assertIn("pmu=on", args)

    def test_smbios_identity_is_board_and_chassis_coherent(self):
        _, args, summary, _, _ = MODULE.gen(
            "intel_desktop_lga1200", "neutral", 0, host_vendor="intel",
            host_cpu_model="Intel Host CPU")
        board_model = re.search(r'-smbios type=1,.*?product="([^"]+)"', args).group(1)
        bios = summary["bios_record"]
        self.assertEqual((bios["version"], bios["date"], bios["release"]),
                         MODULE.BOARD_BIOS[board_model])
        serials = re.findall(r"-smbios type=[123],[^\n]*?serial=([^\s,]+)", args)
        self.assertEqual(len(serials), 3)
        self.assertEqual(len(set(serials)), 3)
        self.assertIn("pcidev=net0", args)
        self.assertIn("processor-id=" + summary["processor_id"], args)
        self.assertEqual(summary["memory_module_mb"], 16384)
        self.assertIn("uefi=on", args)

    def test_smbios_commas_are_escaped_for_qemu_option_parser(self):
        _, args, _, _, _ = MODULE.gen(
            "intel_desktop_lga1200", "neutral", 0, host_vendor="intel",
            host_cpu_model="Intel Host CPU, Unlocked")
        self.assertIn('vendor="American Megatrends International,, LLC."', args)
        self.assertIn('manufacturer="Micro-Star International Co.,, Ltd."', args)
        self.assertIn('version="Intel Host CPU,, Unlocked"', args)
        self.assertEqual(MODULE.qemu_opt("a,b"), "a,,b")

    def test_real_mode_never_accepts_an_arbitrary_sku(self):
        with self.assertRaises(ValueError):
            MODULE.gen("intel_desktop_lga1200", "neutral", 0, host_vendor="intel",
                       host_cpu_model="Real CPU", cpu_model="Fake CPU")
        with self.assertRaises(ValueError):
            MODULE.gen("intel_desktop_lga1200", "neutral", 0, host_vendor="intel")

    def test_skin_mode_is_an_explicit_skeleton(self):
        _, args, summary, _, _ = MODULE.gen(
            "intel_desktop_lga1200", "neutral", 0, host_vendor="intel",
            cpu_source="model", cpu_model="Example SKU")
        self.assertEqual(summary["cpu_source"], "model")
        self.assertIn('version="Example SKU"', args)
        self.assertIn("-cpu host", args)


class SocketInferenceTest(unittest.TestCase):
    def test_u3e1_is_not_a_known_socket(self):
        self.assertNotIn("U3E1", MODULE.KNOWN_SOCKETS)
        self.assertIn("LGA1200", MODULE.KNOWN_SOCKETS)

    def test_socket_from_cpu_maps_known_microarchitectures(self):
        self.assertEqual(MODULE.socket_from_cpu("intel", (6, 165)), "LGA1200")  # Comet Lake
        self.assertEqual(MODULE.socket_from_cpu("intel", (6, 151)), "LGA1700")  # Alder Lake
        self.assertEqual(MODULE.socket_from_cpu("amd", (25, 33)), "AM4")        # Zen3 Vermeer
        self.assertEqual(MODULE.socket_from_cpu("amd", (25, 97)), "AM5")        # Zen4 Raphael

    def test_socket_from_cpu_does_not_guess_unknown(self):
        self.assertIsNone(MODULE.socket_from_cpu("intel", (6, 999)))
        self.assertIsNone(MODULE.socket_from_cpu("intel", None))
        self.assertIsNone(MODULE.socket_from_cpu("unknown", (6, 165)))

    def test_detect_host_family_model_parses_cpuinfo(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("processor\t: 0\ncpu family\t: 6\nmodel\t\t: 165\nstepping\t: 5\n")
            path = f.name
        try:
            self.assertEqual(MODULE.detect_host_family_model(path), (6, 165))
        finally:
            os.unlink(path)

    def test_oem_host_resolves_platform_from_cpu(self):
        """A host whose SMBIOS reports U3E1 (not a socket) still generates a profile."""
        caches = [{"name": "L1d", "size_kb": 32, "ways": 8, "type": "Data", "level": 1},
                  {"name": "L2", "size_kb": 256, "ways": 4, "type": "Unified", "level": 2},
                  {"name": "L3", "size_kb": 16384, "ways": 16, "type": "Unified", "level": 3}]
        with tempfile.TemporaryDirectory() as out:
            argv = ["gen-profile.py", "--cpu-source", "host", "--host-vendor", "intel",
                    "--vmid", "100", "--seed", "100", "--out", out]
            with mock.patch.object(sys, "argv", argv), \
                 mock.patch.object(MODULE, "detect_host_socket", return_value="U3E1"), \
                 mock.patch.object(MODULE, "detect_host_cpu_model",
                                   return_value="Intel(R) Core(TM) i7-10700T CPU @ 2.00GHz"), \
                 mock.patch.object(MODULE, "detect_host_family_model", return_value=(6, 165)), \
                 mock.patch.object(MODULE, "detect_host_topology",
                                   return_value={"sockets": 1, "cores": 8, "threads": 2}), \
                 mock.patch.object(MODULE, "detect_host_caches", return_value=caches), \
                 mock.patch.object(MODULE, "detect_host_processor_id", return_value=0x000A0655):
                MODULE.main()
            data = json.loads((Path(out) / "profile.json").read_text())
            self.assertEqual(data["summary"]["socket"], "LGA1200")
            self.assertEqual(data["summary"]["platform"], "intel_desktop_lga1200")

    def test_explicit_socket_is_never_overridden_by_cpu(self):
        """--socket wins even if the CPU map would infer a different socket."""
        caches = [{"name": "L1d", "size_kb": 32, "ways": 8, "type": "Data", "level": 1},
                  {"name": "L2", "size_kb": 256, "ways": 4, "type": "Unified", "level": 2},
                  {"name": "L3", "size_kb": 16384, "ways": 16, "type": "Unified", "level": 3}]
        with tempfile.TemporaryDirectory() as out:
            argv = ["gen-profile.py", "--cpu-source", "host", "--host-vendor", "intel",
                    "--socket", "LGA1700", "--vmid", "100", "--seed", "100", "--out", out]
            with mock.patch.object(sys, "argv", argv), \
                 mock.patch.object(MODULE, "detect_host_cpu_model",
                                   return_value="Intel(R) Core(TM) i7-12700K"), \
                 mock.patch.object(MODULE, "detect_host_family_model", return_value=(6, 165)), \
                 mock.patch.object(MODULE, "detect_host_topology",
                                   return_value={"sockets": 1, "cores": 8, "threads": 2}), \
                 mock.patch.object(MODULE, "detect_host_caches", return_value=caches), \
                 mock.patch.object(MODULE, "detect_host_processor_id", return_value=0x000A0655):
                MODULE.main()
            data = json.loads((Path(out) / "profile.json").read_text())
            self.assertEqual(data["summary"]["socket"], "LGA1700")


if __name__ == "__main__":
    unittest.main()
