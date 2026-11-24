#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import random
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

MAP = load("chipset_map", ROOT / "tools" / "chipset_map.py")
GEN = load("gen_profile", ROOT / "tools" / "gen-profile.py")

LSPCI = """Slot: 0000:00:00.0
Class: 0600
Vendor: 8086
Device: 9b43
SVendor: 1043
SDevice: 8694

Slot: 0000:00:1f.0
Class: 0601
Vendor: 8086
Device: 4387
SVendor: 1043
SDevice: 8694

Slot: 0000:00:17.0
Class: 0106
Vendor: 8086
Device: 43d2
SVendor: 1043
SDevice: 8694
"""
DMI = """Handle 0x0002, DMI type 2, 15 bytes
Base Board Information
 Manufacturer: ASUSTeK COMPUTER INC.
 Product Name: PRIME B560M-A
Handle 0x0004, DMI type 4, 48 bytes
Processor Information
 Socket Designation: LGA1200
"""


class ChipsetMapTest(unittest.TestCase):
    def test_import_is_real_dump_scoped_and_deterministic(self):
        record = MAP.import_dump(LSPCI, DMI)
        self.assertEqual(record["board"]["socket"], "LGA1200")
        self.assertEqual(MAP.subsystem_identity(record), (0x1043, 0x8694))
        self.assertEqual(record["devices"][0]["vendor"], 0x8086)
        self.assertEqual(record["devices"][0]["device"], 0x9B43)
        self.assertEqual(record["evidence"]["lspci_sha256"], MAP.import_dump(LSPCI, DMI)["evidence"]["lspci_sha256"])
        self.assertIn("identity-only", record["behavior"])

    def test_incomplete_dump_fails_closed(self):
        with self.assertRaises(ValueError):
            MAP.import_dump(LSPCI.replace("Slot: 0000:00:00.0", "Slot: 0000:00:02.0"), DMI)
        with self.assertRaises(ValueError):
            MAP.import_dump(LSPCI, DMI.replace(" Product Name: PRIME B560M-A", ""))

    def test_profile_uses_only_observed_subsystem_ids(self):
        document = MAP.merge({"schema": 1, "records": []}, MAP.import_dump(LSPCI, DMI))
        random.seed(8)
        env, _, summary, _, _ = GEN.gen(
            "intel_desktop_lga1200", "neutral", 0, host_vendor="intel",
            host_cpu_model="Intel Host CPU", chipset_map=document)
        self.assertEqual(env["SUBSYS_VENDOR_HEX"], "0x1043")
        self.assertEqual(env["SUBSYS_DEVICE_HEX"], "0x8694")
        self.assertIn("PRIME B560M-A", summary["board"])
        random.seed(8)
        env_without, _, _, _, _ = GEN.gen(
            "intel_desktop_lga1200", "neutral", 0, host_vendor="intel",
            host_cpu_model="Intel Host CPU")
        self.assertNotIn("SUBSYS_VENDOR_HEX", env_without)
        self.assertNotIn("SUBSYS_DEVICE_HEX", env_without)

    def test_no_blind_global_vendor_substitutions_remain(self):
        recipe = (ROOT / "qemu" / "anti-detection.sh").read_text(encoding="utf-8")
        self.assertNotIn("PCI_VENDOR_ID_REDHAT             0x1b36/#define", recipe)
        self.assertNotIn("s/0x293/0x993/g", recipe)
        self.assertNotIn("s/0x1af4/0x8086/g", recipe)


if __name__ == "__main__":
    unittest.main()
