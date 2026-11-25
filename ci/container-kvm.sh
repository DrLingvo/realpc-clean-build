#!/usr/bin/env bash
# Build the prebuilt Strong KVM module for one exact Proxmox kernel package pair.
# Runs in debian:trixie from the repository root. No host module is installed here.
set -euo pipefail

KREL=7.0.14-6-pve
PKGVER=7.0.14-6
EXPECTED_CONFIG_SHA256=d7d7c2ae6b96aa04adfc16b1262269a951a0dd33a945eab4cf2fa6937469e5f7
EXPECTED_SYMVERS_SHA256=0e39472916fa6286519fe1c8cd39740535f31140a1145e16f0e07fd62ed87f9d
KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils kmod python3 >/dev/null

keyring=/usr/share/keyrings/proxmox-archive-keyring.gpg
curl -fL --retry 3 --retry-all-errors \
  https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
  -o "$keyring"
printf '%s  %s\n' "$KEYRING_SHA256" "$keyring" | sha256sum -c -
cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: https://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: $keyring
EOF
apt-get update

packages=/tmp/realpc-pve-kernel-packages
rm -rf "$packages"
mkdir -p "$packages/kernel" "$packages/headers" "$packages/debs"
cd "$packages/debs"
apt-get download \
  "proxmox-kernel-$KREL=$PKGVER" \
  "proxmox-headers-$KREL=$PKGVER"

kernel_deb=$(find . -maxdepth 1 -type f -name "proxmox-kernel-${KREL}_*.deb" -print -quit)
headers_deb=$(find . -maxdepth 1 -type f -name "proxmox-headers-${KREL}_*.deb" -print -quit)
[ -n "$kernel_deb" ] && [ -n "$headers_deb" ]
[ "$(dpkg-deb -f "$kernel_deb" Version)" = "$PKGVER" ]
[ "$(dpkg-deb -f "$headers_deb" Version)" = "$PKGVER" ]
dpkg-deb -x "$kernel_deb" "$packages/kernel"
dpkg-deb -x "$headers_deb" "$packages/headers"

KERNEL_CONFIG=$(find "$packages/kernel" -type f -path "*/boot/config-$KREL" -print -quit)
MODULE_SYMVERS=$(find "$packages/headers" -type f \
  -path "*/usr/src/linux-headers-$KREL/Module.symvers" -print -quit)
[ -s "$KERNEL_CONFIG" ] || { echo "Exact kernel config was not found" >&2; exit 1; }
[ -s "$MODULE_SYMVERS" ] || { echo "Exact Module.symvers was not found" >&2; exit 1; }
printf '%s  %s\n' "$EXPECTED_CONFIG_SHA256" "$KERNEL_CONFIG" | sha256sum -c -
printf '%s  %s\n' "$EXPECTED_SYMVERS_SHA256" "$MODULE_SYMVERS" | sha256sum -c -

cd /kit
export KREL PKGVER KERNEL_CONFIG MODULE_SYMVERS REALPC_FORCE_GIT=1
bash kernel/build-kvm.sh

module=kernel/out/kvm.ko
[ -s "$module" ]
modinfo "$module" | grep -q '^realpc:'
vermagic=$(modinfo -F vermagic "$module")
case "$vermagic" in "$KREL "*) ;; *) echo "Wrong module vermagic: $vermagic" >&2; exit 1;; esac

out=/kit/out
mkdir -p "$out"
asset="$out/kvm-$KREL.ko"
metadata="$out/kvm-$KREL.modinfo"
cp "$module" "$asset"
module_sha256=$(sha256sum "$asset" | awk '{print $1}')
{
  modinfo "$asset"
  printf 'REALPC_KERNEL_RELEASE=%s\n' "$KREL"
  printf 'REALPC_PACKAGE_VERSION=%s\n' "$PKGVER"
  printf 'REALPC_VERMAGIC=%s\n' "$vermagic"
  printf 'REALPC_CONFIG_SHA256=%s\n' "$EXPECTED_CONFIG_SHA256"
  printf 'REALPC_MODULE_SYMVERS_SHA256=%s\n' "$EXPECTED_SYMVERS_SHA256"
  printf 'REALPC_MODULE_SHA256=%s\n' "$module_sha256"
} > "$metadata"
(
  cd "$out"
  sha256sum "kvm-$KREL.ko" "kvm-$KREL.modinfo" > SHA256SUMS.kvm
  sha256sum -c SHA256SUMS.kvm
)
echo "Prebuilt KVM candidate: $asset"
echo "This is an ABI-checked build artifact, not a real-host load or guest boot test."
