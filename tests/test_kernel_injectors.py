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

static int kvm_get_msr(struct kvm_vcpu *vcpu, struct msr_data *msr_info)
{
	switch (msr_info->index) {
	default:
		return 1;
	}
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

CPUID_AFTER_SET_FIXTURE = r'''
void kvm_vcpu_after_set_cpuid(struct kvm_vcpu *vcpu)
{
	struct kvm_lapic *apic = vcpu->arch.apic;
	struct kvm_cpuid_entry2 *best;
	struct kvm_cpuid_entry2 *entry;
	bool allow_gbpages;
	int i;

	memset(vcpu->arch.cpu_caps, 0, sizeof(vcpu->arch.cpu_caps));
	kvm_update_cpuid_runtime(vcpu);
}
'''


class InjectorTest(unittest.TestCase):
    def run_patch(self, script, source, cpuid_source=CPUID_AFTER_SET_FIXTURE):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "source.c"
            path.write_text(source, encoding="utf-8")
            if script == ANTIDETECT:
                path.with_name("cpuid.c").write_text(cpuid_source, encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(script), str(path)],
                text=True, capture_output=True, check=False,
            )
            cpuid_path = path.with_name("cpuid.c")
            cpuid = cpuid_path.read_text(encoding="utf-8") if cpuid_path.exists() else ""
            return proc, path.read_text(encoding="utf-8"), cpuid

    def test_antidetect_replaces_only_native_hypercall_paths(self):
        proc, patched, cpuid = self.run_patch(ANTIDETECT, X86_FIXTURE)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("kvm_xen_hypercall(vcpu)", patched)
        self.assertIn("kvm_hv_hypercall(vcpu)", patched)
        self.assertIn("kvm_queue_exception(vcpu, UD_VECTOR)", patched)
        self.assertIn("ctxt->exception.vector = UD_VECTOR", patched)
        self.assertIn('MODULE_INFO(realpc, "antidetect")', patched)
        self.assertNotIn("return X86EMUL_CONTINUE", patched)
        self.assertIn("realpc_clear_hypervisor_bit", cpuid)
        self.assertIn("best = kvm_find_cpuid_entry(vcpu, 1);", cpuid)
        self.assertIn("best->ecx &= ~BIT(31);", cpuid)
        self.assertIn("entry->function == KVM_CPUID_SIGNATURE", cpuid)
        self.assertIn("entry->function == KVM_CPUID_FEATURES", cpuid)
        self.assertIn("memset(entry, 0, sizeof(*entry));", cpuid)
        self.assertLess(cpuid.index("realpc_clear_hypervisor_bit"), cpuid.index("memset("))
        self.assertIn("realpc_kvm_msr_gp", patched)
        self.assertIn("msr_info->index >= 0x4b564d00", patched)
        self.assertIn("msr_info->index <= 0x4b564d08", patched)
        self.assertLess(patched.index("realpc_kvm_msr_gp"), patched.index("switch (msr_info->index)"))

    def test_antidetect_is_idempotent(self):
        first, patched, cpuid = self.run_patch(ANTIDETECT, X86_FIXTURE)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second, again, cpuid_again = self.run_patch(ANTIDETECT, patched, cpuid)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(patched, again)
        self.assertEqual(cpuid, cpuid_again)
        self.assertEqual(cpuid_again.count("realpc_clear_hypervisor_bit"), 1)

    def test_antidetect_failure_does_not_write_partial_patch(self):
        broken = X86_FIXTURE.replace(
            "static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt)\n{",
            "static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt);\n/*",
            1,
        )
        proc, result, _ = self.run_patch(ANTIDETECT, broken)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(result, broken)

    def test_antidetect_cpuid_failure_does_not_write_partial_patch(self):
        broken = CPUID_AFTER_SET_FIXTURE.replace("void kvm_vcpu_after_set_cpuid", "void missing", 1)
        proc, result, cpuid = self.run_patch(ANTIDETECT, X86_FIXTURE, broken)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(result, X86_FIXTURE)
        self.assertEqual(cpuid, broken)

    def test_jitter_is_default_off_and_avoids_uint_wraparound(self):
        proc, patched, _ = self.run_patch(JITTER, CPUID_FIXTURE)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("static unsigned int realpc_cpuid_jitter;", patched)
        self.assertIn("if (likely(!max))", patched)
        self.assertIn("budget = (u64)get_random_u32() % ((u64)max + 1);", patched)
        self.assertNotIn("get_random_u32() % (max + 1)", patched)
        self.assertIn("\n\trealpc_cpuid_delay();\n\treturn rv;", patched)

    def test_jitter_is_idempotent(self):
        first, patched, _ = self.run_patch(JITTER, CPUID_FIXTURE)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        second, again, _ = self.run_patch(JITTER, patched)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(patched, again)


if __name__ == "__main__":
    unittest.main()
