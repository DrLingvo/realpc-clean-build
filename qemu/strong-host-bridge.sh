#!/bin/bash
# Optional host-bridge identity only. Q35 register behavior remains unchanged.
set -euo pipefail
: "${HOST_BRIDGE_DEVICE:?}" "${HOST_BRIDGE_EVIDENCE_SHA256:?}"
[[ "$HOST_BRIDGE_EVIDENCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "Host-bridge evidence SHA-256 is required" >&2; exit 1; }
[[ "$HOST_BRIDGE_DEVICE" =~ ^0x[0-9a-fA-F]{4}$ ]] || { echo "HOST_BRIDGE_DEVICE must be 0xNNNN" >&2; exit 1; }
[[ "${HOST_BRIDGE_DEVICE,,}" != 0x29c0 ]] || { echo "Refusing a no-op host-bridge re-skin" >&2; exit 1; }
file=include/hw/pci/pci_ids.h
grep -q '#define PCI_DEVICE_ID_INTEL_P35_MCH      0x29c0' "$file" || { echo "ERROR: Q35 host-bridge anchor missing" >&2; exit 1; }
sed -i 's/#define PCI_DEVICE_ID_INTEL_P35_MCH      0x29c0/#define PCI_DEVICE_ID_INTEL_P35_MCH      '"${HOST_BRIDGE_DEVICE,,}"'/' "$file"
echo "strong-host-bridge: identity ${HOST_BRIDGE_DEVICE,,}; Q35 behavior unchanged"
