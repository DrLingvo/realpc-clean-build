#!/usr/bin/env python3
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AcpiRecipeTest(unittest.TestCase):
    def test_waet_definition_and_emission_are_both_removed(self):
        recipe = (ROOT / "qemu" / "anti-detection.sh").read_text(encoding="utf-8")
        self.assertIn("sed -i '/^build_waet(/,/^}/d' hw/i386/acpi-build.c", recipe)
        self.assertIn("! grep -q 'build_waet' hw/i386/acpi-build.c", recipe)
        self.assertIn("-Werror=unused-function", recipe)

    def test_qtest_checks_actual_sensor_devices_not_unimplemented_template_ids(self):
        check = (ROOT / "tests" / "check.py").read_text(encoding="utf-8")
        self.assertIn('check(b"HSEN" in acpi', check)
        self.assertIn('"PNP0C0B"', check)
        for absent in ("PNP0C14", "PNP0C0C", "PNP0C0E", "PNP0D80"):
            self.assertNotIn(absent, check)


if __name__ == "__main__":
    unittest.main()
