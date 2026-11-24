#!/usr/bin/env python3
import importlib.util
import random
import re
import unittest
import uuid
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "tools" / "gen-profile.py"
SPEC = importlib.util.spec_from_file_location("gen_profile", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProfileTest(unittest.TestCase):
    def setUp(self):
        random.seed(12345)

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


if __name__ == "__main__":
    unittest.main()
