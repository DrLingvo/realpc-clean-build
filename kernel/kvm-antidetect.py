#!/usr/bin/env python3
"""Open reimplementation of the anti-detection changes in the closed "Strong" kvm.ko.

The author ships a modified kvm.ko only as a binary (no source). Its published strings
describe what it does:
    emulate_hypercall ... return UD_VECTOR
    fix_hypercall     ... return UD_VECTOR
This script re-implements those two behaviors in the kernel's own KVM source, so you can
build the module yourself and never load the author's unverifiable binary.

Effect: a guest's VMCALL/VMMCALL (the native KVM paravirt hypercall) raises #UD, as it
would on bare metal, instead of being serviced. Xen and Hyper-V hypercall paths are left
intact, matching the author's setup (which keeps Hyper-V enlightenments with a spoofed
vendor id). The murky per-vendor "do_singlestep"/"emulated_exception" tweaks seen in the
binary are NOT reproduced: their intent is unclear and they are riskier than they are worth
on an Intel host.

WHOLE-HOST EFFECT: kvm.ko is global. With this module loaded, EVERY guest on the host loses
the native KVM paravirt hypercall (kvm-clock, PV EOI, PV spinlocks, async page faults still
work only where they don't go through the hypercall). Use on a host dedicated to these VMs.

usage: kvm-antidetect.py path/to/arch/x86/kvm/x86.c
Edits the file in place. Idempotent (refuses if already patched).
"""
import re
import sys
from pathlib import Path

path = sys.argv[1]
src = open(path).read()
original_src = src
cpuid_path = Path(path).with_name("cpuid.c")
cpuid = cpuid_path.read_text()
original_cpuid = cpuid

already_patched = "realpc anti-detection" in src


def replace_body(text, signature, new_body, label):
    """Replace the { ... } body of the function whose definition starts with `signature`.

    Skips a forward declaration (`signature;`): only the definition is followed by `{`.
    """
    pos = 0
    while True:
        i = text.index(signature, pos)
        after = text[i + len(signature):]
        m = re.match(r"\s*", after)
        nxt = after[m.end():m.end() + 1]
        if nxt == "{":
            break
        pos = i + len(signature)  # declaration or a mention; keep looking
    brace = text.index("{", i)
    depth = 0
    j = brace
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    assert depth == 0, f"unbalanced braces for {label}"
    print(f"patched {label}")
    return text[:brace] + "{\n" + new_body + "}" + text[j + 1:]


# 1. kvm_emulate_hypercall: keep Xen/Hyper-V paths, raise #UD for the native KVM hypercall.
if already_patched:
    print("already patched:", path)
else:
    src = replace_body(
        src,
        "int kvm_emulate_hypercall(struct kvm_vcpu *vcpu)",
        """\tif (kvm_xen_hypercall_enabled(vcpu->kvm))
    \t\treturn kvm_xen_hypercall(vcpu);

    \tif (kvm_hv_hypercall_enabled(vcpu))
    \t\treturn kvm_hv_hypercall(vcpu);

    \t/* realpc anti-detection: no native KVM hypercall interface (bare-metal look) */
    \tkvm_queue_exception(vcpu, UD_VECTOR);
    \treturn 1;
    """,
        "kvm_emulate_hypercall",
    )

    # 2. emulator_fix_hypercall: always synthesize #UD instead of patching VMCALL<->VMMCALL.
    src = replace_body(
        src,
        "static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt)",
        """\t/* realpc anti-detection: always synthesize #UD, never patch the insn */
    \tctxt->exception.error_code_valid = false;
    \tctxt->exception.vector = UD_VECTOR;
    \tctxt->have_exception = true;
    \treturn X86EMUL_PROPAGATE_FAULT;
    """,
        "emulator_fix_hypercall",
    )

    # 3. The native hypercall replacement leaves this helper unused under -Werror.
    src = src.replace(
        "static int complete_hypercall_exit(struct kvm_vcpu *vcpu)",
        "static int __maybe_unused complete_hypercall_exit(struct kvm_vcpu *vcpu)",
        1,
    )

    # 4. A verifiable marker in the module metadata, so tools can confirm the running kvm.ko is
    #    this build:  modinfo kvm | grep realpc   ->   realpc: antidetect
    if "MODULE_INFO(realpc" not in src:
        src = src.rstrip() + '\n\nMODULE_INFO(realpc, "antidetect");\n'


# 5. Make the architectural KVM MSRs unavailable. kvm_get_msr returning 1 injects #GP.
# This is deliberately outside kvm_emulate_cpuid: the established timing path is unchanged.
if "realpc_kvm_msr_gp" not in src:
    signature = "static int kvm_get_msr(struct kvm_vcpu *vcpu, struct msr_data *msr_info)"
    function_pos = src.find(signature)
    if function_pos < 0:
        raise SystemExit("Cannot find kvm_get_msr")
    brace = src.find("{", function_pos + len(signature))
    if brace < 0:
        raise SystemExit("Cannot find kvm_get_msr body")
    patch = """
\t/* realpc_kvm_msr_gp: bare-metal RDMSR of KVM MSRs raises #GP. */
\tif (msr_info->index >= 0x4b564d00 &&
\t    msr_info->index <= 0x4b564d08)
\t\treturn 1;
"""
    src = src[:brace + 1] + patch + src[brace + 1:]

# 6. Clear the architectural hypervisor bit and KVM paravirt leaves when userspace installs
# the vCPU CPUID. This runs during setup, not in the CPUID VM-exit/timing path.
if "realpc_clear_hypervisor_bit" not in cpuid:
    signature = "void kvm_vcpu_after_set_cpuid(struct kvm_vcpu *vcpu)"
    function_pos = cpuid.find(signature)
    if function_pos < 0:
        raise SystemExit("Cannot find kvm_vcpu_after_set_cpuid")
    anchor = "\tmemset(vcpu->arch.cpu_caps, 0, sizeof(vcpu->arch.cpu_caps));"
    anchor_pos = cpuid.find(anchor, function_pos)
    if anchor_pos < 0:
        raise SystemExit("Cannot find kvm_vcpu_after_set_cpuid initialization anchor")
    patch = """\t/* realpc_clear_hypervisor_bit: CPUID.1:ECX[31] is clear on bare metal. */
\tbest = kvm_find_cpuid_entry(vcpu, 1);
\tif (best)
\t\tbest->ecx &= ~BIT(31);

\t/* realpc_hide_kvm_cpuid: no KVM signature or PV feature bits. */
\tfor (i = 0; i < vcpu->arch.cpuid_nent; i++) {
\t\tentry = &vcpu->arch.cpuid_entries[i];
\t\tif (entry->function == KVM_CPUID_SIGNATURE ||
\t\t    entry->function == KVM_CPUID_FEATURES)
\t\t\tmemset(entry, 0, sizeof(*entry));
\t}

"""
    cpuid = cpuid[:anchor_pos] + patch + cpuid[anchor_pos:]

# Validate and prepare both files before writing either one. A missing anchor must not leave
# a half-patched kernel tree that a later retry could mistake for a complete injection.
if src != original_src:
    open(path, "w").write(src)
    print("done:", path)
if cpuid != original_cpuid:
    cpuid_path.write_text(cpuid)
    print("done:", cpuid_path)
