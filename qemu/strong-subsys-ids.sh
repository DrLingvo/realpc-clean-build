#!/bin/bash
# Optional (STRONG_SUBSYS_IDS=1): replace QEMU's default PCI *subsystem* IDs.
# Any header-type-0 device that doesn't set its own subsystem id inherits these defaults —
# ich9 (LPC/SATA/SMBus), UHCI/EHCI/XHCI USB, intel-hda/AC97 audio, etc. QEMU's defaults are:
#   subsystem vendor = 0x1af4 (Red Hat/Qumranet)   -> a dead giveaway
#   subsystem device = 0x1100 (QEMU)
# On real hardware these carry the BOARD maker's id (ASUS 0x1043, Gigabyte 0x1458, ...). This
# sets both from config so onboard devices look like they belong to one real board.
# (virtio devices set their own subsystem = 0x1af4; rebrand those with STRONG_PCI_IDS instead.)
set -euo pipefail
: "${SUBSYS_VENDOR_HEX:?}" "${SUBSYS_DEVICE_HEX:?}"
f=hw/pci/pci.c
FAILED=0
S() { local e=$1 b; b=$(md5sum < "$f"); sed -i "$e" "$f"; [ "$b" != "$(md5sum < "$f")" ] || { echo "ERROR: no match: $e" >&2; FAILED=1; }; }

S "s/static uint16_t pci_default_sub_vendor_id = PCI_SUBVENDOR_ID_REDHAT_QUMRANET;/static uint16_t pci_default_sub_vendor_id = ${SUBSYS_VENDOR_HEX};/"
S "s/static uint16_t pci_default_sub_device_id = PCI_SUBDEVICE_ID_QEMU;/static uint16_t pci_default_sub_device_id = ${SUBSYS_DEVICE_HEX};/"

[ "$FAILED" -eq 0 ] || { echo "strong-subsys-ids: some edits did not apply" >&2; exit 1; }
echo "strong-subsys-ids: applied (subsys vendor ${SUBSYS_VENDOR_HEX}, device ${SUBSYS_DEVICE_HEX})"
