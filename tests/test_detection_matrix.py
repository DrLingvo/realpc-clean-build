#!/usr/bin/env python3
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / "DETECTION-MATRIX.md").read_text(encoding="utf-8")


class DetectionMatrixTest(unittest.TestCase):
    def test_every_requested_work_item_has_a_status(self):
        for number in range(1, 15):
            match = re.search(rf"^\| R{number}(?:\s|:)[^|]*\| (CLOSED|PARTIAL|KNOWN) \|",
                              TEXT, re.MULTILINE)
            self.assertIsNotNone(match, f"R{number} has no matrix status")
        for number in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13):
            match = re.search(rf"^\| R{number}(?:\s|:)[^|]*\| (CLOSED|PARTIAL|KNOWN) \|",
                              TEXT, re.MULTILINE)
            self.assertEqual(match.group(1), "PARTIAL",
                             f"R{number} cannot be closed without its outstanding proof")

    def test_known_limitations_and_failed_probe_semantics_are_explicit(self):
        for marker in (
            "Median CPUID/VM-exit latency | KNOWN",
            "Mouse movement and lack of user input | KNOWN",
            "Gateway/network observation | KNOWN",
            "Complete VM invisibility | KNOWN",
            "NOT_TESTED`, `ERROR`, `TIMEOUT",
            "timing/jitter implementation is unchanged",
            "real mouse and keyboard",
            "Win32_MemoryDevice",
            "VEN_1B36",
        ):
            self.assertIn(marker, TEXT)

    def test_pending_machine_proofs_are_not_rewritten_as_passes(self):
        for marker in (
            "The new qtest has not run on branch-built packages",
            "No such boot test has run on this branch",
            "no Windows detector run has occurred",
            "sandbox reported no architectural PMU",
            "shipped map is empty",
        ):
            self.assertIn(marker, TEXT)


if __name__ == "__main__":
    unittest.main()
