#!/bin/bash
# Build an open kvm.ko (with the anti-detection changes from kernel/kvm-antidetect.py)
# ON the Proxmox VE host, against the exact running kernel. Building here rather than in
# CI is deliberate: the module must match the running kernel's version and config exactly,
# and the only way to guarantee that ABI match is to build against this host's own source.
#
# EXPERIMENTAL. This replaces a core kernel module. Keep the backup this script makes and
# know how to boot a previous kernel before you load the result. Not boot-tested by CI.
#
# usage (as root on the PVE host):
#   KSRC=/path/to/kernel/source ./build-kvm.sh      # if you already have matching source
#   ./build-kvm.sh                                   # tries apt-get source for this kernel
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
KREL=$(uname -r)                       # e.g. 7.0.14-6-pve
echo "Running kernel: $KREL"

apt-get install -y --no-install-recommends build-essential libelf-dev flex bison bc \
  libssl-dev dwarves >/dev/null

# --- locate kernel source matching $KREL ------------------------------------------------
if [ -z "${KSRC:-}" ]; then
  pkg="proxmox-kernel-${KREL}"
  srcdir="/usr/src/kernel-src-$KREL"
  mkdir -p "$srcdir"; cd "$srcdir"
  echo "Fetching source for $pkg (needs a deb-src line for the Proxmox repo)..."
  if ! apt-get source "$pkg" 2>/dev/null; then
    cat >&2 <<EOF
Could not apt-get source $pkg.
Add a deb-src entry for the Proxmox repo, or pass KSRC=/path to a kernel source tree that
matches $KREL, then re-run. On Proxmox the source also lives in the pve-kernel git
(submodule ubuntu-kernel) at the tag for this version.
EOF
    exit 1
  fi
  KSRC=$(dirname "$(find "$srcdir" -maxdepth 3 -path '*arch/x86/kvm/Makefile' | head -1)")
  KSRC=${KSRC%/arch/x86/kvm}
fi
[ -f "$KSRC/arch/x86/kvm/Makefile" ] || { echo "no kvm source under KSRC=$KSRC" >&2; exit 1; }
echo "Kernel source: $KSRC"

# --- configure the tree to match the running kernel -------------------------------------
cd "$KSRC"
if [ -f "/boot/config-$KREL" ]; then
  cp "/boot/config-$KREL" .config
elif [ -f "/lib/modules/$KREL/build/.config" ]; then
  cp "/lib/modules/$KREL/build/.config" .config
else
  echo "no /boot/config-$KREL; using the tree's default config" >&2
  make defconfig
fi
# keep the exact version suffix so vermagic matches ("-pve", etc.)
scripts/config --set-str LOCALVERSION "" >/dev/null 2>&1 || true
make olddefconfig >/dev/null
built_release=$(make -s kernelrelease)
[ "$built_release" = "$KREL" ] || {
  echo "source/config kernelrelease is '$built_release', running kernel is '$KREL'" >&2
  echo "refusing to build against a different kernel source or LOCALVERSION" >&2; exit 1
}

# vermagic alone is not an ABI check when CONFIG_MODVERSIONS is enabled. Reuse the exact
# running kernel's symbol CRCs instead of silently building a module that cannot load.
if scripts/config --state MODVERSIONS 2>/dev/null | grep -qx y; then
  symvers="/lib/modules/$KREL/build/Module.symvers"
  [ -s "$symvers" ] || {
    echo "CONFIG_MODVERSIONS=y, but $symvers is missing" >&2
    echo "install the exact proxmox-headers-$KREL package or provide its Module.symvers" >&2
    exit 1
  }
  cp "$symvers" Module.symvers
fi

# --- apply the open anti-detection edits -----------------------------------------------
python3 -I "$here/kvm-antidetect.py" arch/x86/kvm/x86.c

# Optional, experimental: CPUID VM-exit jitter (off by default). Even when built in it stays
# inert until an operator sets the realpc_cpuid_jitter module parameter. See
# tests/timing_tests/jitter_report.py for exactly what it defeats (naive low-variance
# detectors only) and its latency cost.
if [ "${VM_EXIT_JITTER:-0}" = "1" ]; then
  echo "VM_EXIT_JITTER=1: adding the opt-in CPUID jitter hook"
  python3 -I "$here/kvm-cpuid-jitter.py" arch/x86/kvm/cpuid.c
fi

# --- build just the kvm modules --------------------------------------------------------
make prepare modules_prepare -j"$(nproc)"
make -j"$(nproc)" M=arch/x86/kvm

out="$here/out"; mkdir -p "$out"
cp arch/x86/kvm/kvm.ko "$out/kvm.ko-$KREL"
echo
echo "Built: $out/kvm.ko-$KREL"
echo "vermagic: $(modinfo -F vermagic "$out/kvm.ko-$KREL")"
echo "running : $KREL  (these must match before you load it)"
echo "Install with kernel/install-kvm.sh (makes a backup and reloads)."
