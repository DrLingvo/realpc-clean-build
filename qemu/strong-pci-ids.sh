#!/bin/bash
# Optional (STRONG_PCI_IDS=1): re-brand PCI vendor IDs that identify emulated devices.
#   0x1234 (QEMU: stdvga, bochs-display, ...)   -> $STDVGA_VENDOR
#   0x1af4 (Red Hat/Qumranet: all virtio)       -> $VIRTIO_VENDOR
#   0x15ad (VMware: vmware-svga, vmxnet3, pvscsi) -> $VIRTIO_VENDOR
# Reconstructed from the author's closed "Strong" OVMF, whose video driver expects exactly
# these IDs (see edk2/anti-detection.sh). The commented-out lines of the author's published
# QEMU script used the same 0x8085 value for virtio.
# Side effects: stock virtio-win drivers will not bind; legacy VGA BIOS and iPXE ROMs no
# longer match, so use OVMF (UEFI), SATA disks and e1000 NICs, as the author recommends.
set -euo pipefail
: "${STDVGA_VENDOR:?}" "${VIRTIO_VENDOR:?}"
FAILED=0
S() {
  local expr=$1 f=$2 before
  before=$(md5sum < "$f"); sed -i "$expr" "$f"
  [ "$before" != "$(md5sum < "$f")" ] || { echo "ERROR: no match in $f: $expr" >&2; FAILED=1; }
}
S "s/^#define PCI_VENDOR_ID_QEMU               0x1234/#define PCI_VENDOR_ID_QEMU               ${STDVGA_VENDOR}/" include/hw/pci/pci.h
S "s/^#define PCI_VENDOR_ID_REDHAT_QUMRANET    0x1af4/#define PCI_VENDOR_ID_REDHAT_QUMRANET    ${VIRTIO_VENDOR}/" include/hw/pci/pci.h
S "s/^#define PCI_VENDOR_ID_VMWARE             0x15ad/#define PCI_VENDOR_ID_VMWARE             ${VIRTIO_VENDOR}/" include/hw/pci/pci.h
S "s/^#define PCI_VENDOR_ID_VMWARE             0x15ad/#define PCI_VENDOR_ID_VMWARE             ${VIRTIO_VENDOR}/" include/hw/pci/pci_ids.h
[ "$FAILED" -eq 0 ] || exit 1
echo "strong-pci-ids: applied"
