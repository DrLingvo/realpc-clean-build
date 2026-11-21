#!/usr/bin/env python3
"""Compare timing-test results against reference/thresholds.json and print a verdict.

Each test is classified:
  OK        - looks native / as expected
  TELL      - a VM-detectable signal that this project could in principle address
  KNOWN     - a VM tell that is a documented known-limitation on plain KVM (not a bug)
  SKIP      - test did not run (e.g. single vCPU, no msr module)

Exit code: 1 if any actionable TELL is present, else 0. KNOWN limitations do not fail.
"""
import json
import sys
from pathlib import Path

HARD = {"rdtsc_cpuid_rdtsc"}  # known-undefeatable on vanilla KVM


def load(p):
    with open(p) as f:
        return json.load(f)


def verdict(name, r, t):
    """Return (status, message)."""
    if r.get("error") or r.get("skipped"):
        return "SKIP", r.get("skipped", "did not run")
    th = t.get(name, {})

    if name == "rdtsc_cpuid_rdtsc":
        # CPUID on bare metal is a few hundred cycles; anything far above that is a VM-exit.
        # High latency is the primary signal; low variance (cv) only says how obvious it is.
        median = r.get("median", 0)
        vm_like = median > th.get("median_cycles_native_max", 800)
        stable = r.get("cv", 1) < th.get("cv_min_native", 0.08)
        msg = f"median {median:.0f} cyc ({r.get('median_ns',0):.0f} ns), cv {r.get('cv',0):.3f}"
        if vm_like:
            msg += " (VM-exit visible" + (", low-variance" if stable else "") + ")"
        return ("KNOWN" if vm_like else "OK", msg)

    if name == "cache_latency":
        bad = []
        if r.get("l1_cycles", 0) > th.get("l1_cycles_max", 8): bad.append("L1")
        if r.get("l3_cycles", 0) and r.get("ram_cycles", 0) < th.get("ram_cycles_min", 120): bad.append("RAM")
        m = f"L1 {r.get('l1_cycles',0):.1f} L2 {r.get('l2_cycles',0):.1f} L3 {r.get('l3_cycles',0):.1f} RAM {r.get('ram_cycles',0):.1f}"
        return ("TELL", m + f" (odd: {','.join(bad)})") if bad else ("OK", m)

    if name == "tsc_sync":
        off = r.get("min_abs_offset", 0)
        bad = off > th.get("min_abs_offset_max", 200)
        return ("TELL" if bad else "OK", f"min |offset| {off} cyc, spread {r.get('offset_spread',0)}")

    if name == "hpet_tsc_ratio":
        cv = r.get("ratio_cv", 1)
        bad = cv > th.get("ratio_cv_max", 0.002)
        return ("TELL" if bad else "OK", f"TSC/ns {r.get('tsc_per_ns',0):.3f}, ratio cv {cv:.5f}")

    if name == "pmu_check":
        bad = r.get("version", 0) < th.get("min_version", 1) or \
              r.get("gp_counters", 0) < th.get("min_gp_counters", 2) or \
              r.get("gp_width", 0) < th.get("min_gp_width", 40)
        return ("TELL" if bad else "OK",
                f"version {r.get('version',0)}, gp {r.get('gp_counters',0)}x{r.get('gp_width',0)}bit")

    if name == "rapl_check":
        if not r.get("available"):
            return "TELL", "RAPL MSRs not present (no host-sensors passthrough)"
        if th.get("require_increasing") and not r.get("pkg_increasing"):
            return "TELL", "RAPL present but package energy not increasing"
        return "OK", f"RAPL present, +{r.get('delta_joules',0):.3f} J/200ms"

    return "SKIP", "no rule"


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <results_dir> <thresholds.json>", file=sys.stderr)
        sys.exit(2)
    rdir, th = Path(sys.argv[1]), load(Path(sys.argv[2]))
    tells = 0
    print(f"{'TEST':22} {'STATUS':6} DETAIL")
    print("-" * 70)
    for jf in sorted(rdir.glob("*.json")):
        r = load(jf)
        name = r.get("test", jf.stem)
        st, msg = verdict(name, r, th)
        if st == "TELL" and name not in HARD:
            tells += 1
        print(f"{name:22} {st:6} {msg}")
    print("-" * 70)
    if tells:
        print(f"{tells} actionable VM tell(s) detected. KNOWN limitations (e.g. VM-exit latency) excluded.")
    else:
        print("No actionable VM tells. (KNOWN limitations may still apply — see README.)")
    sys.exit(1 if tells else 0)


if __name__ == "__main__":
    main()
