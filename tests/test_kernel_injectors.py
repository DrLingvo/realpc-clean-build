#!/usr/bin/env python3
"""Fixture tests for the source-to-source KVM patchers (no kernel build required)."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANTIDETECT = ROOT / "kernel" / "kvm-antidetect.py"
JITTER = ROOT / "kernel" / "kvm-cpuid-jitter.py"

X86_FIXTURE = r'''
int kvm_emulate_hypercall(struct kvm_vcpu *vcpu);
static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt);

int kvm_emulate_hypercall(struct kvm_vcpu *vcpu)
{
	if (kvm_xen_hypercall_enabled(vcpu->kvm))
		return kvm_xen_hypercall(vcpu);
	return 0;
}

static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt)
{
	if (ctxt->have_exception) {
		return X86EMUL_PROPAGATE_FAULT;
	}
	return X86EMUL_CONTINUE;
}
'''

CPUID_FIXTURE = r'''
int kvm_emulate_cpuid(struct kvm_vcpu *vcpu)
{
	int rv = 0;
	if (vcpu == 0) {
		return 1;
	}
	return rv;
}
'''


class InjectorTest(unittest.TestCase):
    def run_patch(self, script, source):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "source.c"
            path.write_text(source, encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(script), str(path)],
                text=True, capture_output=True, check=False,
            )
            return proc, path.read_text(encoding="utf-8")

    def test_antidetect_replaces_only_native_hypercall_paths(self):
        proc, patched = self.run_patch(ANTIDETECT, X86_FIXTURE)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("kvm_xen_hypercall(vcpu)", patched)
        self.assertIn("kvm_hv_hypercall(vcpu)", patched)
        self.assertIn("kvm_queue_exception(vcpu, UD_VECTOR)", patched)
        self.assertIn("ctxt->exception.vector = UD_VECTOR", patched)
        self.assertIn('MODULE_INFO(realpc, "antidetect")', patched)
        self.assertNotIn("return X86EMUL_CONTINUE", patched)

    def test_antidetect_is_idempotent(self):
        first, patched = self.run_patch(ANTIDETECT, X86_FIXTURE)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second, again = self.run_patch(ANTIDETECT, patched)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(patched, again)

    def test_antidetect_failure_does_not_write_partial_patch(self):
        broken = X86_FIXTURE.replace(
            "static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt)\n{",
            "static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt);\n/*",
            1,
        )
        proc, result = self.run_patch(ANTIDETECT, broken)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(result, broken)

    def test_jitter_is_default_off_and_avoids_uint_wraparound(self):
        proc, patched = self.run_patch(JITTER, CPUID_FIXTURE)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("static unsigned int realpc_cpuid_jitter;", patched)
        self.assertIn("if (likely(!max))", patched)
        self.assertIn("budget = (u64)get_random_u32() % ((u64)max + 1);", patched)
        self.assertNotIn("get_random_u32() % (max + 1)", patched)
        self.assertIn("\n\trealpc_cpuid_delay();\n\treturn rv;", patched)

    def test_jitter_is_idempotent(self):
        first, patched = self.run_patch(JITTER, CPUID_FIXTURE)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second, again = self.run_patch(JITTER, patched)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(patched, again)


if __name__ == "__main__":
    unittest.main()
