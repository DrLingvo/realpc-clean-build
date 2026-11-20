#!/bin/bash
# Install the kvm.ko built by build-kvm.sh, with a backup and a sanity check.
# EXPERIMENTAL — replaces a core kernel module. Run as root on the PVE host.
#   ./install-kvm.sh            # install out/kvm.ko-$(uname -r)
#   ./install-kvm.sh --revert   # restore the backup
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
KREL=$(uname -r)
target="/lib/modules/$KREL/kernel/arch/x86/kvm/kvm.ko"
backup="$target.realpc-bak"

if [ "${1:-}" = --revert ]; then
  [ -f "$backup" ] || { echo "no backup at $backup" >&2; exit 1; }
  cp "$backup" "$target"
  echo "restored original kvm.ko; reboot or reload kvm to apply"
  exit 0
fi

mod="$here/out/kvm.ko-$KREL"
[ -f "$mod" ] || { echo "build it first: $mod not found" >&2; exit 1; }

have=$(modinfo -F vermagic "$mod")
want=$(modinfo -F vermagic "$target" 2>/dev/null || cat "/lib/modules/$KREL/build/include/config/kernel.release" 2>/dev/null)
echo "new vermagic: $have"
echo "host kernel : $KREL"
case "$have" in
  "$KREL"*) : ;;
  *) echo "REFUSING: vermagic does not start with the running kernel; it will not load." >&2; exit 1 ;;
esac

# Backup once, then install.
[ -f "$backup" ] || cp "$target" "$backup"
cp "$mod" "$target"
echo "installed. Stop all VMs, then:"
echo "  rmmod kvm_intel kvm; modprobe kvm_intel"
echo "  dmesg | grep -i 'anti-detection\\|kvm' | tail"
echo "Revert anytime: $0 --revert   (backup: $backup)"
