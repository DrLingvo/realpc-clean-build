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
  libssl-dev libdw-dev dwarves git patch >/dev/null

# Fetch only immutable full commits. Never build root-running code from a moving branch.
fetch_exact_commit(){
  local dir=$1 url=$2 commit=$3 attempt
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  for attempt in 1 2 3; do
    if git -C "$dir" fetch --depth 1 origin "$commit"; then
      git -C "$dir" checkout -q --detach FETCH_HEAD
      [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ]
      return
    fi
    sleep 5
  done
  echo "Could not fetch pinned commit $commit from $url" >&2
  return 1
}

fetch_pinned_source(){
  local pve_commit ubuntu_commit
  case "$KREL" in
    7.0.14-6-pve)
      pve_commit=d4439e71d7865ecaa01a48033f96ff8ac1df16f8
      ubuntu_commit=660d1f05673c4e02cc3c2c056afc0dc14c0075f0
      ;;
    *) return 1 ;;
  esac

  local root="/usr/src/realpc-kernel-$KREL"
  local pve_dir="$root/pve-kernel"
  local marker="$root/.source-ready"
  local prepared="$root/ubuntu-kernel"
  if [ -f "$marker" ] && [ -d "$prepared/.git" ] \
    && grep -Fxq "PVE_KERNEL_COMMIT=$pve_commit" "$marker" \
    && grep -Fxq "UBUNTU_KERNEL_COMMIT=$ubuntu_commit" "$marker" \
    && [ "$(git -C "$prepared" rev-parse HEAD 2>/dev/null)" = "$ubuntu_commit" ] \
    && [ -f "$root/.pristine/x86.c" ] && [ -f "$root/.pristine/cpuid.c" ]; then
    KSRC=$prepared
    cp "$root/.pristine/x86.c" "$KSRC/arch/x86/kvm/x86.c"
    cp "$root/.pristine/cpuid.c" "$KSRC/arch/x86/kvm/cpuid.c"
    echo "Kernel source: cached pinned Proxmox source in $KSRC"
    return
  fi

  rm -rf -- "$root"
  mkdir -p "$pve_dir" "$prepared"
  echo "Fetching pve-kernel commit $pve_commit..."
  fetch_exact_commit "$pve_dir" https://git.proxmox.com/git/pve-kernel.git "$pve_commit"
  local linked
  linked=$(git -C "$pve_dir" ls-tree HEAD submodules/ubuntu-kernel | awk '$1 == "160000" {print $3}')
  [ "$linked" = "$ubuntu_commit" ] || {
    echo "pve-kernel links ubuntu-kernel $linked, expected $ubuntu_commit" >&2
    return 1
  }
  echo "Fetching ubuntu-kernel commit $ubuntu_commit..."
  fetch_exact_commit "$prepared" https://git.proxmox.com/git/mirror_ubuntu-kernels.git "$ubuntu_commit"

  local upstream
  upstream=$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3}
    END{print v "." p "." s}' "$prepared/Makefile")
  [ "$upstream" = "${KREL%%-*}" ] || {
    echo "Pinned source is Linux $upstream, running kernel is $KREL" >&2
    return 1
  }
  sed -i "s/^EXTRAVERSION.*/EXTRAVERSION = -${KREL#*-}/" "$prepared/Makefile"
  grep -Fxq "EXTRAVERSION = -${KREL#*-}" "$prepared/Makefile"

  local patch_file
  for patch_file in "$pve_dir"/patches/kernel/*.patch; do
    [ -f "$patch_file" ] || { echo "No Proxmox kernel patches found" >&2; return 1; }
    echo "Applying Proxmox patch $(basename "$patch_file")"
    patch --batch -p1 -d "$prepared" < "$patch_file"
  done
  mkdir -p "$root/.pristine"
  cp "$prepared/arch/x86/kvm/x86.c" "$root/.pristine/x86.c"
  cp "$prepared/arch/x86/kvm/cpuid.c" "$root/.pristine/cpuid.c"
  printf 'PVE_KERNEL_COMMIT=%s\nUBUNTU_KERNEL_COMMIT=%s\n' \
    "$pve_commit" "$ubuntu_commit" > "$marker"
  KSRC=$prepared
}

# --- locate kernel source matching $KREL ------------------------------------------------
if [ -z "${KSRC:-}" ]; then
  pkg="proxmox-kernel-${KREL}"
  srcdir="/usr/src/kernel-src-$KREL"
  mkdir -p "$srcdir"; cd "$srcdir"
  echo "Fetching source for $pkg with apt-get source..."
  if apt-get source "$pkg"; then
    found=$(find "$srcdir" -maxdepth 6 -type f -path '*/arch/x86/kvm/Makefile' -print -quit)
    [ -n "$found" ] || { echo "apt source completed but no KVM Makefile was found" >&2; exit 1; }
    KSRC=${found%/arch/x86/kvm/Makefile}
  else
    echo "apt source is unavailable; trying immutable Proxmox git commits..."
    if ! fetch_pinned_source; then
      cat >&2 <<EOF
Could not obtain exact source for $KREL.
Pass KSRC=/path to a matching prepared kernel source tree. The automatic git fallback
currently has verified pins only for 7.0.14-6-pve; other kernels require apt deb-src.
EOF
      exit 1
    fi
  fi
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
# Keep the exact version suffix so vermagic matches ("-pve", etc.). A prepared git
# tree is intentionally dirty after Proxmox/realpc patches. Exporting an empty
# LOCALVERSION also suppresses the '+' that scripts/setlocalversion adds to git trees.
export LOCALVERSION=
scripts/config --set-str LOCALVERSION "" >/dev/null 2>&1 || true
scripts/config --disable LOCALVERSION_AUTO >/dev/null 2>&1 || true
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
cp arch/x86/kvm/kvm.ko "$out/kvm.ko"
echo
echo "Built: $out/kvm.ko"
echo "vermagic: $(modinfo -F vermagic "$out/kvm.ko")"
echo "running : $KREL  (these must match before you load it)"
echo "Install with kernel/install-kvm.sh (makes a backup and reloads)."
