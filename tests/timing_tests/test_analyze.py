#!/usr/bin/env python3
"""Unit tests for analyze.py; no third-party dependencies."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ANALYZER = HERE / "analyze.py"
THRESHOLDS = HERE / "reference" / "thresholds.json"


def good_results():
    return {
        "rdtsc_cpuid_rdtsc": {"median": 100, "median_ns": 40, "cv": 0.2},
        "cache_latency": {"l1_cycles": 4, "l2_cycles": 12, "l3_cycles": 35, "ram_cycles": 200},
        "tsc_sync": {"min_abs_offset": 20, "offset_spread": 50},
        "hpet_tsc_ratio": {"ratio_cv": 0.0001, "tsc_per_ns": 2.5},
        "pmu_check": {"version": 4, "gp_counters": 4, "gp_width": 48},
        "rapl_check": {"available": True, "pkg_increasing": True, "delta_joules": 1.0},
    }


class AnalyzerTest(unittest.TestCase):
    def run_with(self, results):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for name, value in results.items():
                value = dict(value)
                value.setdefault("test", name)
                (directory / f"{name}.json").write_text(json.dumps(value), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(ANALYZER), str(directory), str(THRESHOLDS)],
                text=True, capture_output=True, check=False,
            )

    def test_complete_good_run_passes(self):
        proc = self.run_with(good_results())
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn(" ERROR ", proc.stdout)

    def test_all_failed_tests_are_an_error(self):
        results = {name: {"error": "exit code 126"} for name in good_results()}
        proc = self.run_with(results)
        self.assertEqual(proc.returncode, 2, proc.stdout)
        self.assertIn("INCOMPLETE", proc.stdout)
        self.assertNotIn("No actionable VM tells", proc.stdout)

    def test_empty_result_directory_is_an_error(self):
        proc = self.run_with({})
        self.assertEqual(proc.returncode, 2, proc.stdout)

    def test_missing_test_is_an_error(self):
        results = good_results()
        del results["pmu_check"]
        proc = self.run_with(results)
        self.assertEqual(proc.returncode, 2, proc.stdout)
        self.assertIn("pmu_check", proc.stdout)

    def test_actionable_tell_fails(self):
        results = good_results()
        results["pmu_check"] = {"version": 0, "gp_counters": 0, "gp_width": 0}
        proc = self.run_with(results)
        self.assertEqual(proc.returncode, 1, proc.stdout)

    def test_environmental_skip_does_not_fail(self):
        results = good_results()
        results["rapl_check"] = {"skipped": "permission denied: run as root with msr loaded"}
        proc = self.run_with(results)
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("SKIP", proc.stdout)

    def test_malformed_number_is_an_error(self):
        results = good_results()
        results["cache_latency"]["l1_cycles"] = "fast"
        proc = self.run_with(results)
        self.assertEqual(proc.returncode, 2, proc.stdout)

    def test_unexpected_result_file_is_an_error(self):
        results = good_results()
        results["stale"] = {"value": 1}
        proc = self.run_with(results)
        self.assertEqual(proc.returncode, 2, proc.stdout)


if __name__ == "__main__":
    unittest.main()
