#!/bin/bash
# Runs inside a stock debian:trixie container: installs the freshly built packages
# (dependencies from the official Proxmox repo) and runs tests/check.py.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg python3 python3-pip
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
if [ -f ci/proxmox-archive-keyring.gpg ]; then install -m 0644 ci/proxmox-archive-keyring.gpg "$KEYRING"
else curl -fsSL -o "$KEYRING" https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg; fi
cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: $KEYRING
EOF
apt-get update

echo "=== artifacts"; ls -la out; (cd out && for f in SHA256SUMS*; do sha256sum -c "$f" --ignore-missing; done)
apt-get install -y --no-install-recommends ./out/pve-qemu-kvm_*_amd64.deb ./out/pve-edk2-firmware-ovmf_*_all.deb
dpkg -l pve-qemu-kvm pve-edk2-firmware-ovmf | tail -2
qemu-system-x86_64 --version

echo "=== fw_cfg dump (qtest, no guest code)"
python3 -I tests/fwcfg_dump.py /tmp/fw -- qemu-system-x86_64 -accel qtest -machine q35 -m 4096 -smp 8 \
  -display none -nodefaults -qtest stdio \
  -acpitable file=out/ssdt.aml -acpitable file=out/ssdt-ec.aml -acpitable file=out/hpet.aml \
  -smbios type=1,manufacturer=Maxsun,product=Test -smbios type=9 -smbios type=8

echo "=== OVMF extract"
pip install --break-system-packages -q uefi_firmware
mkdir -p /tmp/ovmf && cp /usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd /tmp/ovmf/
uefi-firmware-parser --brute -e -O /tmp/ovmf/OVMF_CODE_4M.fd | tail -3
find /tmp/ovmf -name "*.pe" | wc -l

echo "=== checks"
python3 -I tests/check.py /tmp/fw /tmp/ovmf/OVMF_CODE_4M.fd_output /usr/bin/qemu-system-x86_64
