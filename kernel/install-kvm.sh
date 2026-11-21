#!/usr/bin/env bash
# Install the kvm.ko built by build-kvm.sh, with compatibility checks, a backup and a revert.
# EXPERIMENTAL: this replaces kvm.ko for the WHOLE HOST. Stop all VMs first.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
KREL=$(uname -r)
moddir="/lib/modules/$KREL/kernel/arch/x86/kvm"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

target="$(modinfo -n kvm 2>/dev/null || true)"
case "$target" in
  "$moddir"/kvm.ko*) [ -f "$target" ] || { echo "missing $target" >&2; exit 1; } ;;
  *) echo "cannot resolve the active kvm.ko under $moddir" >&2; exit 1 ;;
esac
backup="$target.realpc-orig"
vendor() {
  case "$(grep -m1 '^vendor_id' /proc/cpuinfo | awk '{print $3}')" in
    GenuineIntel) echo intel;; AuthenticAMD) echo amd;; *) return 1;;
  esac
}
unload_kvm() {
  rmmod kvm_intel 2>/dev/null || true; rmmod kvm_amd 2>/dev/null || true
  if [ -d /sys/module/kvm ]; then rmmod kvm; fi
}
load_kvm() {
  local vend; vend=$(vendor) || { echo "unknown CPU vendor" >&2; return 1; }
  modprobe "kvm_$vend"
  [ -d /sys/module/kvm ] || { echo "kvm did not load" >&2; return 1; }
}
restore() {
  [ -f "$backup" ] || return 1
  unload_kvm || true
  cp -f "$backup" "$target" && depmod "$KREL" && load_kvm
}
no_running_vms() {
  local run; run="$(qm list 2>/dev/null | awk '$3=="running"{print $1}' | tr '\n' ' ')"
  [ -z "$run" ] || { echo "stop running VMs first: $run" >&2; return 1; }
}

if [ "${1:-}" = --revert ]; then
  [ -f "$backup" ] || { echo "no backup at $backup" >&2; exit 1; }
  no_running_vms
  restore
  update-initramfs -u -k "$KREL"
  echo "restored and loaded original kvm.ko from $backup"
  exit 0
fi

yes=0; [ "${1:-}" = --yes ] && yes=1
mod="$here/out/kvm.ko-$KREL"
[ -f "$mod" ] || { echo "build it first (kernel/build-kvm.sh): $mod not found" >&2; exit 1; }
modinfo "$mod" 2>/dev/null | grep -q '^realpc:' || { echo "REFUSING: no realpc marker in $mod" >&2; exit 1; }

new_vm="$(modinfo -F vermagic "$mod")"
cur_vm="$(modinfo -F vermagic "$target" 2>/dev/null || true)"
echo "new vermagic: $new_vm"; echo "cur vermagic: ${cur_vm:-<unknown>}"
if [ -n "$cur_vm" ] && [ "$new_vm" != "$cur_vm" ]; then
  echo "REFUSING: vermagic differs from the installed kvm.ko" >&2; exit 1
fi
case "$new_vm" in "$KREL"*) : ;; *) echo "REFUSING: wrong kernel release" >&2; exit 1 ;; esac
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  echo "REFUSING: Secure Boot is enabled" >&2; exit 1
fi
no_running_vms

echo ">>> This replaces kvm.ko for the WHOLE HOST ($KREL). All VMs are affected. <<<"
if [ "$yes" != 1 ]; then
  read -r -p "Proceed? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }
fi

# The backup is created before KVM is unloaded. Any later failure restores it automatically.
[ -f "$backup" ] || cp -a "$target" "$backup"
installing=1; success=0
on_exit() {
  rc=$?; trap - EXIT
  if [ "${installing:-0}" = 1 ] && [ "$success" = 0 ]; then
    echo "installation failed; restoring $backup" >&2
    if restore; then
      update-initramfs -u -k "$KREL" || \
        echo "module restored, but initramfs regeneration failed; rerun update-initramfs" >&2
    else
      echo "AUTOMATIC RESTORE FAILED: restore $backup to $target manually" >&2
    fi
  fi
  exit "$rc"
}
trap on_exit EXIT

unload_kvm
tmp="$target.realpc-new"; rm -f "$tmp"
case "$target" in
  *.zst) command -v zstd >/dev/null || apt-get install -y --no-install-recommends zstd
         zstd -q -f -o "$tmp" "$mod" ;;
  *.xz)  xz -f -c "$mod" > "$tmp" ;;
  *)     cp -f "$mod" "$tmp" ;;
esac
chmod --reference="$target" "$tmp"; chown --reference="$target" "$tmp"
mv -f "$tmp" "$target"
depmod "$KREL"; update-initramfs -u -k "$KREL"
load_kvm
if modinfo kvm 2>/dev/null | grep -q '^realpc:'; then
  echo "OK: patched kvm.ko installed; KVM is loaded"
else
  echo "installed module has no realpc marker" >&2; exit 1
fi
success=1; installing=0; trap - EXIT
echo "Revert: $0 --revert   (backup: $backup)"
