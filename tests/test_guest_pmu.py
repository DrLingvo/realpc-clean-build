#!/usr/bin/env python3
"""Build the guest PMU probe; optionally require a real counter run on this machine."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests" / "guest_pmu.c"


class GuestPMUTest(unittest.TestCase):
    def build(self, directory):
        binary = Path(directory) / "guest_pmu"
        subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-o", str(binary), str(SOURCE)], check=True)
        return binary

    def test_probe_builds_cleanly_and_uses_perf_events(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("SYS_perf_event_open", source)
        self.assertIn("PERF_COUNT_HW_CPU_CYCLES", source)
        self.assertIn("PERF_COUNT_HW_INSTRUCTIONS", source)
        self.assertIn("PERF_EVENT_IOC_RESET", source)
        with tempfile.TemporaryDirectory() as tmp:
            self.build(tmp)

    def test_real_machine_counters_when_explicitly_requested(self):
        if os.environ.get("REALPC_RUN_PMU_TEST") != "1":
            self.skipTest("set REALPC_RUN_PMU_TEST=1 on the host or guest to run counters")
        with tempfile.TemporaryDirectory() as tmp:
            binary = self.build(tmp)
            proc = subprocess.run([binary], text=True, capture_output=True, check=False)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            result = json.loads(proc.stdout.splitlines()[0])
            self.assertGreater(result["cycles_high"], result["cycles_low"])
            self.assertGreater(result["instructions_high"], result["instructions_low"] * 4)


if __name__ == "__main__":
    unittest.main()
