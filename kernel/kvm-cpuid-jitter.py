#!/usr/bin/env python3
"""OPTIONAL, EXPERIMENTAL: add randomized latency to the CPUID VM-exit path in kvm.ko.

Only applied when VM_EXIT_JITTER=1 is set for build-kvm.sh. It adds a module parameter
`realpc_cpuid_jitter` (max extra cycles per CPUID exit, default 0) and a tiny rdtsc busy-spin
at the top of kvm_emulate_cpuid().

Read tests/timing_tests/jitter_report.py before using this. The honest summary:
  * jitter RAISES the variance of rdtsc;cpuid;rdtsc, which can fool a naive detector that
    keys on LOW variance;
  * it NEVER lowers the median latency, so a median-based detector still sees the VM-exit;
  * it adds the configured latency to EVERY CPUID in EVERY guest on the host.
Default is 0 (no effect) even when built in, so the module behaves identically until an
operator explicitly sets the parameter. NOT boot-tested by CI.

usage: kvm-cpuid-jitter.py path/to/arch/x86/kvm/cpuid.c
Idempotent (refuses if already patched).
"""
import re
import sys

path = sys.argv[1]
src = open(path).read()

if "realpc_cpuid_jitter" in src:
    print("already patched:", path)
    sys.exit(0)

HELPER = """
/* realpc anti-detection (EXPERIMENTAL, opt-in via the realpc_cpuid_jitter module param):
 * add up to N random cycles to each CPUID VM-exit. Default 0 = no effect. See
 * tests/timing_tests/jitter_report.py for what this does and does not defeat. */
#include <linux/random.h>
static unsigned int realpc_cpuid_jitter;
module_param(realpc_cpuid_jitter, uint, 0644);
MODULE_PARM_DESC(realpc_cpuid_jitter,
\t"realpc: add up to N random cycles to each CPUID VM-exit (0=off). Defeats only "
\t"naive low-variance timing detectors and raises CPUID latency; does not hide the VM-exit.");

static __always_inline void realpc_cpuid_delay(void)
{
\tunsigned int max = READ_ONCE(realpc_cpuid_jitter);
\tu64 start, budget;

\tif (likely(!max))
\t\treturn;
\tbudget = get_random_u32() % (max + 1);
\tstart = rdtsc();
\twhile (rdtsc() - start < budget)
\t\tcpu_relax();
}
"""

# Insert the helper just before the kvm_emulate_cpuid definition, and a call to it inside
# the body just before the final `return` (NOT at the top: a statement before the local
# declarations would trip -Wdeclaration-after-statement, which is fatal under CONFIG_WERROR).
sig = "int kvm_emulate_cpuid(struct kvm_vcpu *vcpu)"
m = re.search(re.escape(sig) + r"\s*\n\{\n", src)
if not m:
    print("could not find kvm_emulate_cpuid() definition in", path, file=sys.stderr)
    sys.exit(1)

# find the matching closing brace of the function body
brace = src.index("{", m.start())
depth, j = 0, brace
while j < len(src):
    if src[j] == "{":
        depth += 1
    elif src[j] == "}":
        depth -= 1
        if depth == 0:
            break
    j += 1
if depth != 0:
    print("unbalanced braces in kvm_emulate_cpuid()", file=sys.stderr)
    sys.exit(1)

body_start, body_end = m.end(), j
ret = src.rfind("\n\treturn ", body_start, body_end)  # last top-level return in the body
if ret < 0:
    print("no return found in kvm_emulate_cpuid() body", file=sys.stderr)
    sys.exit(1)

src = (src[:m.start()] + HELPER + "\n" + src[m.start():ret]
       + "\n\trealpc_cpuid_delay();" + src[ret:])

open(path, "w").write(src)
print("patched CPUID jitter into", path, "(default off; set realpc_cpuid_jitter to enable)")
