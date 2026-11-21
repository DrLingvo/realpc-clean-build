#!/usr/bin/env python3
"""Quantify what VM_EXIT_JITTER actually buys (and costs) against the rdtsc;cpuid;rdtsc
detector.

Background
----------
On vanilla KVM, CPUID is always a VM-exit, so rdtsc;cpuid;rdtsc reads a HIGH median latency
with LOW variance. Two detector styles use that:

  * median-only : flags VM if median > ~800 cycles. (cpuid on bare metal is a few hundred
                  cycles, period — no VM can make a real VM-exit that cheap.)
  * low-variance: flags VM only if the latency is high AND very steady (cv < ~0.08).

VM_EXIT_JITTER adds a random delay in the CPUID exit path. This tool measures, on either a
real captured sample (--raw from the C test's --dump-raw) or a synthetic VM-exit profile,
what a sweep of jitter does to (median, cv) and therefore to each detector.

The point is honesty: jitter RAISES variance (can defeat a naive low-variance detector) but
NEVER lowers the median (a median-only detector still flags the VM), and it adds latency to
every intercepted CPUID. Use the numbers below to decide if that trade is worth it for your
threat model. It does not make the VM undetectable.

usage:
  jitter_report.py [--raw FILE] [--cv-min 0.08] [--median-max 800] [--tsc-hz N]
  (no --raw: a representative KVM VM-exit distribution is synthesized)
"""
import argparse
import random
import struct
import sys


def load_raw(path):
    with open(path, "rb") as f:
        b = f.read()
    n = len(b) // 8
    return list(struct.unpack(f"<{n}Q", b[: n * 8]))


def synth_vmexit(n=20000, floor=2900, scale=120, seed=1):
    """A representative plain-KVM cpuid VM-exit: a hard floor (the unavoidable exit cost)
    plus a light exponential tail. Gives median ~3k cyc, cv ~0.04 — the classic tell
    (high latency, low variance)."""
    rng = random.Random(seed)
    return [floor + int(rng.expovariate(1.0 / scale)) for _ in range(n)]


def stats(xs):
    xs = sorted(xs)
    n = len(xs)
    median = xs[n // 2]
    mean = sum(xs) / n
    var = sum((x - mean) ** 2 for x in xs) / n
    sd = var ** 0.5
    return median, mean, sd, (sd / mean if mean else 0.0)


def apply_jitter(xs, amp, seed=2):
    """Add uniform[0, amp] cycles per sample (what a busy-delay in the exit path does)."""
    if amp <= 0:
        return xs
    rng = random.Random(seed)
    return [x + rng.randint(0, amp) for x in xs]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", help="binary uint64 sample dump from rdtsc_cpuid_rdtsc --dump-raw")
    ap.add_argument("--cv-min", type=float, default=0.08,
                    help="low-variance detector threshold (cv below this + high median = VM)")
    ap.add_argument("--median-max", type=float, default=800,
                    help="median-only detector threshold (cycles)")
    ap.add_argument("--tsc-hz", type=float, default=0, help="for ns in the latency-cost column")
    a = ap.parse_args()

    base = load_raw(a.raw) if a.raw else synth_vmexit()
    src = "real sample" if a.raw else "synthetic KVM VM-exit"
    m0, _, _, _ = stats(base)

    def det_median(med):
        return "VM" if med > a.median_max else "native"

    def det_lowvar(med, cv):
        return "VM" if (med > a.median_max and cv < a.cv_min) else "native"

    def ns(cyc):
        return f"{cyc * 1e9 / a.tsc_hz:7.1f}ns" if a.tsc_hz else f"{cyc:7.0f}cy"

    print(f"source: {src}  (n={len(base)}, baseline median={m0:.0f} cyc)")
    print(f"detectors: median-only (median>{a.median_max:.0f}), "
          f"low-variance (median>{a.median_max:.0f} AND cv<{a.cv_min})\n")
    print(f"{'jitter':>8} {'median':>8} {'cv':>7} {'added cost/cpuid':>18}  "
          f"{'median-only':>12} {'low-variance':>13}")
    print("-" * 74)
    for amp in (0, 256, 512, 1024, 2048, 4096, 8192):
        med, mean, sd, cv = stats(apply_jitter(base, amp))
        cost = amp / 2.0  # mean of uniform[0,amp]
        print(f"{amp:>8} {med:>8.0f} {cv:>7.4f} {ns(cost):>18}  "
              f"{det_median(med):>12} {det_lowvar(med, cv):>13}")
    print("-" * 74)
    print("Reading: raising jitter raises cv (can flip low-variance -> native) but median\n"
          "never falls, so median-only stays VM. Every row also adds the shown latency to\n"
          "each intercepted CPUID. Jitter trades performance for cover against naive\n"
          "detectors only; it does not hide the VM-exit from a median-based one.")


if __name__ == "__main__":
    main()
