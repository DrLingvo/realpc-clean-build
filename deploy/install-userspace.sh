#!/bin/bash
# Install the open userspace stack (QEMU + OVMF) on a Proxmox VE 9 host, from a release's
# .deb files, and drop the ACPI tables in /root. Safe and revertible (these are packages).
#   ./install-userspace.sh /path/to/downloaded/release/dir
# Revert: ./install-userspace.sh --revert
set -euo pipefail
if [ "${1:-}" = --revert ]; then
  apt-mark unhold pve-qemu-kvm pve-edk2-firmware-ovmf 2>/dev/null || true
  apt-get install --reinstall -y pve-qemu-kvm pve-edk2-firmware-ovmf
  echo "reverted to the repository packages"
  exit 0
fi
dir=${1:?usage: install-userspace.sh <dir with the release .deb and .aml files>}
cd "$dir"
if [ -f SHA256SUMS ]; then sha256sum -c SHA256SUMS --ignore-missing; fi
dpkg -i pve-qemu-kvm_*_amd64.deb pve-edk2-firmware-ovmf_*_all.deb
apt-mark hold pve-qemu-kvm pve-edk2-firmware-ovmf   # keep apt upgrade from replacing them
for f in ssdt.aml ssdt-ec.aml hpet.aml; do [ -f "$f" ] && cp "$f" /root/; done
echo
echo "Installed. In the VM config use:  bios: ovmf, machine: q35, vga: vmware,"
echo "SATA disk, e1000 NIC, and the -cpu/-smbios/-acpitable args (see deploy/vm.example.conf)."
echo "For host CPU sensors in the guest add  host-sensors=on  to -cpu (Intel)."
echo "Revert: $0 --revert"
