#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "tools" / "disk_identity.py"
SPEC = importlib.util.spec_from_file_location("disk_identity", PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DiskIdentityTest(unittest.TestCase):
    def test_same_vm_and_disk_is_stable(self):
        a = MODULE.disk_identity("100", "sata0", 500107862016)
        b = MODULE.disk_identity("100", "sata0", 500107862016)
        self.assertEqual(a, b)
        self.assertEqual(a["lba"] * 512, a["bytes"])
        self.assertLessEqual(len(a["serial"]), 20)
        self.assertLessEqual(len(a["firmware"]), 8)

    def test_different_disks_and_vms_have_different_identities(self):
        identities = [MODULE.disk_identity(vm, disk, 1000204886016)
                      for vm in ("100", "101") for disk in ("sata0", "sata1")]
        self.assertEqual(len({item["serial"] for item in identities}), 4)
        self.assertEqual(len({item["wwn"] for item in identities}), 4)

    def test_qemu_properties_cover_all_ata_identity_fields(self):
        identity = MODULE.disk_identity("100", "sata0", 976773168 * 512)
        args = MODULE.qemu_properties(identity)
        for key in ("model", "serial", "version", "wwn"):
            self.assertIn(f"{key}={identity[key] if key != 'version' else identity['firmware']}", args)

    def test_unknown_capacity_fails_closed(self):
        with self.assertRaises(ValueError):
            MODULE.disk_identity("100", "sata0", 500107862017)

    def test_no_time_seeded_disk_randomness_in_qemu_recipe(self):
        recipe = (Path(__file__).resolve().parents[1] / "qemu" / "anti-detection.sh").read_text()
        self.assertNotIn("srand(time(NULL))", recipe)
        self.assertNotIn("rand()%1000000", recipe)
        self.assertNotIn("IDE_SERIAL_PREFIX", recipe)


if __name__ == "__main__":
    unittest.main()
