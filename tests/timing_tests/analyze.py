#!/usr/bin/env python3
"""Compare timing-test results against reference/thresholds.json and print a verdict.

Each test is classified:
  OK        - looks native / as expected
  TELL      - a VM-detectable signal that this project could in principle address
  KNOWN     - a VM tell that is a documented known-limitation on plain KVM (not a bug)
  SKIP      - test was intentionally skipped for a stated environmental reason
  ERROR     - test did not run, is missing, or returned malformed results

Exit code: 1 if any actionable TELL is present, 2 for any ERROR, else 0.
KNOWN limitations do not fail. An empty or incomplete result set is never a success.
"""
import json
import math
import sys
from pathlib import Path

HARD = {"rdtsc_cpuid_rdtsc"}  # known-undefeatable on vanilla KVM


def load(path):
    with open(path, encoding="utf-8") as f:
        value = json.load(f)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def number(result, key, default=0):
    """Read a finite JSON number; bool and malformed values are schema errors."""
    value = result.get(key, default)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{key}: expected a number, got {value!r}")
    if not math.isfinite(value):
        raise ValueError(f"{key}: expected a finite number")
    return value


def verdict(name, result, thresholds):
    """Return (status, message)."""
    if result.get("error"):
        detail = result.get("error")
        return "ERROR", detail if isinstance(detail, str) else "test command failed"
    if result.get("skipped"):
        detail = result.get("skipped")
        return "SKIP", detail if isinstance(detail, str) else "skipped by test"
    th = thresholds.get(name, {})

    if name == "rdtsc_cpuid_rdtsc":
        median = number(result, "median")
        cv = number(result, "cv", 1)
        vm_like = median > th.get("median_cycles_native_max", 800)
        stable = cv < th.get("cv_min_native", 0.08)
        msg = (f"median {median:.0f} cyc ({number(result, 'median_ns'):.0f} ns), "
               f"cv {cv:.3f}")
        if vm_like:
            msg += " (VM-exit visible" + (", low-variance" if stable else "") + ")"
        return ("KNOWN" if vm_like else "OK"), msg

    if name == "cache_latency":
        l1 = number(result, "l1_cycles")
        l2 = number(result, "l2_cycles")
        l3 = number(result, "l3_cycles")
        ram = number(result, "ram_cycles")
        bad = []
        if l1 > th.get("l1_cycles_max", 8):
            bad.append("L1")
        if l2 > th.get("l2_cycles_max", 20):
            bad.append("L2")
        if l3 and ram < th.get("ram_cycles_min", 120):
            bad.append("RAM")
        msg = f"L1 {l1:.1f} L2 {l2:.1f} L3 {l3:.1f} RAM {ram:.1f}"
        return (("TELL", msg + f" (odd: {','.join(bad)})") if bad else ("OK", msg))

    if name == "tsc_sync":
        off = number(result, "min_abs_offset")
        spread = number(result, "offset_spread")
        bad = off > th.get("min_abs_offset_max", 200)
        if "offset_spread_max" in th and spread > th["offset_spread_max"]:
            bad = True
        return ("TELL" if bad else "OK"), f"min |offset| {off} cyc, spread {spread}"

    if name == "hpet_tsc_ratio":
        cv = number(result, "ratio_cv", 1)
        bad = cv > th.get("ratio_cv_max", 0.002)
        return ("TELL" if bad else "OK"), \
            f"TSC/ns {number(result, 'tsc_per_ns'):.3f}, ratio cv {cv:.5f}"

    if name == "pmu_check":
        version = number(result, "version")
        counters = number(result, "gp_counters")
        width = number(result, "gp_width")
        if result.get("vendor") == "AuthenticAMD" and version == 0:
            return "SKIP", "Intel architectural PMU CPUID leaf is not applicable to AMD"
        bad = (version < th.get("min_version", 1)
               or counters < th.get("min_gp_counters", 2)
               or width < th.get("min_gp_width", 40))
        return ("TELL" if bad else "OK"), \
            f"version {version:g}, gp {counters:g}x{width:g}bit"

    if name == "rapl_check":
        if not result.get("available"):
            if not th.get("require_available", True):
                return "SKIP", "RAPL is not required for this profile"
            return "TELL", "RAPL MSRs not present (check the host-sensors/RAPL configuration)"
        if th.get("require_increasing", True) and not result.get("pkg_increasing"):
            return "TELL", "RAPL present but package energy not increasing"
        return "OK", f"RAPL present, +{number(result, 'delta_joules'):.3f} J/200ms"

    return "ERROR", f"no rule for test {name!r}"


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <results_dir> <thresholds.json>", file=sys.stderr)
        sys.exit(2)
    rdir = Path(sys.argv[1])
    try:
        thresholds = load(Path(sys.argv[2]))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot load thresholds: {exc}", file=sys.stderr)
        sys.exit(2)

    expected = [name for name in thresholds if not name.startswith("_")]
    errors = 0
    tells = 0
    print(f"{'TEST':22} {'STATUS':6} DETAIL")
    print("-" * 70)
    for name in sorted(expected):
        path = rdir / f"{name}.json"
        try:
            result = load(path)
            actual_name = result.get("test", name)
            if actual_name != name:
                raise ValueError(f"expected test={name!r}, got {actual_name!r}")
            status, msg = verdict(name, result, thresholds)
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
            status, msg = "ERROR", str(exc)
        if status == "ERROR":
            errors += 1
        elif status == "TELL" and name not in HARD:
            tells += 1
        print(f"{name:22} {status:6} {msg}")
    print("-" * 70)

    # Unknown extra JSON files usually indicate a wrong result directory or a stale schema.
    extras = sorted(p.name for p in rdir.glob("*.json") if p.stem not in expected) if rdir.is_dir() else []
    for extra in extras:
        errors += 1
        print(f"{'ERROR':22} ERROR  unexpected result file: {extra}")

    if errors:
        print(f"{errors} test result error(s); the run is INCOMPLETE and must not pass CI.")
        sys.exit(2)
    if tells:
        print(f"{tells} actionable VM tell(s) detected. KNOWN limitations are excluded.")
        sys.exit(1)
    print("No actionable VM tells. KNOWN limitations may still apply — see README.")


if __name__ == "__main__":
    main()
