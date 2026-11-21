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

path = sys.argv[1]
src = open(path).read()

if "realpc anti-detection" in src:
    print("already patched:", path)
    sys.exit(0)


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

# 3. A verifiable marker in the module metadata, so tools can confirm the running kvm.ko is
#    this build:  modinfo kvm | grep realpc   ->   realpc: antidetect
if "MODULE_INFO(realpc" not in src:
    src = src.rstrip() + '\n\nMODULE_INFO(realpc, "antidetect");\n'

open(path, "w").write(src)
print("done:", path)
