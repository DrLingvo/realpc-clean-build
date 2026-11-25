#!/usr/bin/env python3
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CiQtestTest(unittest.TestCase):
    def test_two_dimm_qtest_does_not_reserve_32_gib_on_runner(self):
        script = (ROOT / "ci" / "container-test.sh").read_text(encoding="utf-8")
        self.assertIn("memory: 32768", script)
        self.assertIn("-machine q35,memory-backend=qtest-ram -m 32768", script)
        self.assertIn(
            "-object memory-backend-ram,id=qtest-ram,size=32768M,reserve=false",
            script,
        )


if __name__ == "__main__":
    unittest.main()
