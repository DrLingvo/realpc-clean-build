#!/bin/bash
# Runs inside a stock debian:trixie container (see .github/workflows/build.yml).
# Adds the official Proxmox VE 9 repository and runs build.sh for the given stages.
#
# Repository key: if ci/proxmox-archive-keyring.gpg is committed (copy it from your own PVE
# host: /usr/share/keyrings/proxmox-archive-keyring.gpg), that file is used. Otherwise the
# key is downloaded from download.proxmox.com over HTTPS and its fingerprints are printed,
# so you can compare them with `gpg --show-keys` on your host.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg sudo ccache

KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
if [ -f "$here/proxmox-archive-keyring.gpg" ]; then
  echo "Using committed Proxmox keyring"
  install -m 0644 "$here/proxmox-archive-keyring.gpg" "$KEYRING"
else
  echo "Downloading Proxmox keyring (trust on first use, compare fingerprints below)"
  curl -fsSL -o "$KEYRING" https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
fi
gpg --show-keys --with-fingerprint "$KEYRING"

cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: $KEYRING
EOF

apt-get update

# Compiler cache (mounted + cached by the workflow at CCACHE_DIR). Putting /usr/lib/ccache
# first makes gcc/g++/cc/c++ resolve to the ccache wrappers during the QEMU/edk2 build.
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"
mkdir -p "$CCACHE_DIR"
export PATH="/usr/lib/ccache:$PATH"
update-ccache-symlinks 2>/dev/null || true
ccache -M 2G >/dev/null 2>&1 || true
ccache -z  >/dev/null 2>&1 || true

cd "$here/.."
STAGES="${1:-qemu edk2 acpi}" WORK="${WORK:-/build}" ./build.sh

echo "=== ccache stats ==="; ccache -s 2>/dev/null || true

# Trim the cached source trees: keep only each repo's .git object store (bounded cache); the
# next run re-checks out from it instead of re-cloning. Submodule objects live under .git/modules.
for d in "${WORK:-/build}"/pve-qemu "${WORK:-/build}"/pve-edk2-firmware; do
  [ -d "$d/.git" ] || continue
  ( cd "$d" && find . -maxdepth 1 -mindepth 1 ! -name .git -exec rm -rf {} + ) || true
done
