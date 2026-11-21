#!/bin/bash
# Install the kvm.ko built by build-kvm.sh, with compatibility checks, a backup and a revert.
#
#   !!! EXPERIMENTAL — this REPLACES a core kernel module (kvm.ko) for the WHOLE HOST. !!!
#   Every VM on this host is affected (all lose the native KVM paravirt hypercall). The module
#   is unsigned, so Secure Boot must be off. Keep a way to boot a previous/known-good kernel.
#
#   ./install-kvm.sh            # install kernel/out/kvm.ko-$(uname -r)
#   ./install-kvm.sh --revert   # restore the backup
#   ./install-kvm.sh --yes      # skip the confirmation prompt
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
KREL=$(uname -r)
moddir="/lib/modules/$KREL/kernel/arch/x86/kvm"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

# locate the currently installed module, honoring kernel module compression (.zst/.xz)
target="$(ls "$moddir"/kvm.ko* 2>/dev/null | head -1 || true)"
[ -n "$target" ] || { echo "no kvm.ko* under $moddir" >&2; exit 1; }
backup="$target.realpc-orig"

if [ "${1:-}" = --revert ]; then
  [ -f "$backup" ] || { echo "no backup at $backup" >&2; exit 1; }
  run="$(qm list 2>/dev/null | awk '$3=="running"{print $1}' | tr '\n' ' ')"
  [ -z "$run" ] || { echo "stop running VMs first: $run" >&2; exit 1; }
  rmmod kvm_intel 2>/dev/null || true; rmmod kvm_amd 2>/dev/null || true; rmmod kvm 2>/dev/null || true
  cp -f "$backup" "$target"; depmod "$KREL"
  modprobe "kvm_$(grep -qm1 GenuineIntel /proc/cpuinfo && echo intel || echo amd)" 2>/dev/null || true
  echo "restored original kvm.ko from $backup"
  exit 0
fi

yes=0; [ "${1:-}" = --yes ] && yes=1
mod="$here/out/kvm.ko-$KREL"
[ -f "$mod" ] || { echo "build it first (kernel/build-kvm.sh): $mod not found" >&2; exit 1; }

# 1) the built module carries our marker (so we know it's the patched one)
modinfo "$mod" 2>/dev/null | grep -q '^realpc:' || { echo "REFUSING: $mod has no realpc marker — not our patched module" >&2; exit 1; }

# 2) vermagic must match the running kernel's kvm module EXACTLY (version + config flags),
#    not just the release prefix — a mismatch means it will not load.
new_vm="$(modinfo -F vermagic "$mod")"
cur_vm="$(modinfo -F vermagic "$target" 2>/dev/null || true)"
echo "new vermagic: $new_vm"
echo "cur vermagic: ${cur_vm:-<unknown>}"
if [ -n "$cur_vm" ] && [ "$new_vm" != "$cur_vm" ]; then
  echo "REFUSING: vermagic differs from the installed kvm.ko — it would not load." >&2; exit 1
fi
case "$new_vm" in "$KREL"*) : ;; *) echo "REFUSING: vermagic does not start with $KREL." >&2; exit 1 ;; esac

# 3) Secure Boot off (unsigned module), and no running VMs (kvm must be unloadable)
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  echo "REFUSING: Secure Boot is enabled; an unsigned module will not load. Disable it in BIOS." >&2; exit 1
fi
run="$(qm list 2>/dev/null | awk '$3=="running"{print $1}' | tr '\n' ' ')"
[ -z "$run" ] || { echo "REFUSING: stop running VMs first (kvm is in use): $run" >&2; exit 1; }

echo
echo ">>> This replaces kvm.ko for the WHOLE HOST ($KREL). All VMs are affected. <<<"
if [ "$yes" != 1 ]; then read -r -p "Proceed? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }; fi

rmmod kvm_intel 2>/dev/null || true; rmmod kvm_amd 2>/dev/null || true
rmmod kvm 2>/dev/null || { echo "kvm is busy — are all VMs stopped?" >&2; exit 1; }
[ -f "$backup" ] || { cp -a "$target" "$backup"; echo "backup -> $backup"; }

# install, matching the target's compression
case "$target" in
  *.zst) command -v zstd >/dev/null || { apt-get install -y --no-install-recommends zstd >/dev/null; }
         zstd -q -f -o "$target" "$mod" ;;
  *.xz)  xz -f -c "$mod" > "$target" ;;
  *)     cp -f "$mod" "$target" ;;
esac
depmod "$KREL"; update-initramfs -u -k "$KREL" >/dev/null 2>&1 || true

vend="$(grep -qm1 GenuineIntel /proc/cpuinfo && echo intel || echo amd)"
modprobe "kvm_$vend"
if modinfo kvm 2>/dev/null | grep -q '^realpc:'; then
  echo "OK: patched kvm.ko loaded (modinfo realpc=antidetect)"
else
  echo "WARNING: module installed but the loaded kvm has no realpc marker — check manually" >&2
fi
echo "Revert anytime: $0 --revert   (backup: $backup)"
