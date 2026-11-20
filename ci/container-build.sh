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
apt-get install -y --no-install-recommends ca-certificates curl gnupg sudo

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
cd "$here/.."
STAGES="${1:-qemu edk2 acpi}" WORK=/build ./build.sh
