#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("smbios_tables", ROOT / "tools" / "smbios_tables.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SMBIOSTableTest(unittest.TestCase):
    def test_cache_binary_matches_observed_size_type_and_associativity(self):
        record = MODULE.cache_record({"level": 1, "type": "Data", "size_kb": 48, "ways": 12}, 0)
        header = struct.unpack("<BBHBHHHHHBBBB", record[:19])
        self.assertEqual(header[0:3], (7, 19, 0x0700))
        self.assertEqual(header[4], 0x180)
        self.assertEqual(header[5:7], (48, 48))
        self.assertEqual(header[-2:], (4, 9))
        self.assertTrue(record.endswith(b"L1 Data Cache\0\0"))

    def test_large_cache_uses_64k_granularity(self):
        field = MODULE.cache_size_field(32 * 1024)
        self.assertEqual(field, 0x8000 | 512)
        with self.assertRaises(ValueError):
            MODULE.cache_size_field(32769)

    def test_every_host_cache_is_emitted_and_linked(self):
        profile = {"summary": {"caches": [
            {"level": 1, "type": "Data", "size_kb": 32, "ways": 8},
            {"level": 1, "type": "Instruction", "size_kb": 32, "ways": 8},
            {"level": 2, "type": "Unified", "size_kb": 256, "ways": 4},
            {"level": 3, "type": "Unified", "size_kb": 20480, "ways": 16},
        ]}}
        with tempfile.TemporaryDirectory() as tmp:
            paths = MODULE.write_cache_records(profile, tmp)
            self.assertEqual(len(paths), 4)
            for instance, path in enumerate(paths):
                data = Path(path).read_bytes()
                self.assertEqual(struct.unpack_from("<H", data, 2)[0], 0x0700 + instance)
            self.assertEqual(profile["summary"]["smbios_files"], paths)

    def test_unknown_associativity_fails_closed(self):
        with self.assertRaises(ValueError):
            MODULE.cache_record({"level": 2, "type": "Unified", "size_kb": 256, "ways": 3}, 0)

    def test_qemu_patch_has_no_fixed_cache_sizes(self):
        patch = (ROOT / "qemu" / "smbios.patch").read_text(encoding="utf-8")
        self.assertNotIn("smbios_build_type_7_table", patch)
        self.assertNotIn("cores_per_socket * 0x20", patch)
        self.assertNotIn("0x4000, 0x06", patch)


if __name__ == "__main__":
    unittest.main()
