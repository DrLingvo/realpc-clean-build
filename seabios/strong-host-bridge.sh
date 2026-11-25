#!/bin/bash
# Match SeaBIOS host-bridge recognition to QEMU's optional identity-only change.
set -euo pipefail
: "${HOST_BRIDGE_DEVICE:?}"
[[ "$HOST_BRIDGE_DEVICE" =~ ^0x[0-9a-fA-F]{4}$ ]] || { echo "HOST_BRIDGE_DEVICE must be 0xNNNN" >&2; exit 1; }
file=src/fw/paravirt.c
grep -q 'case 0x29c0:' "$file" || { echo "ERROR: SeaBIOS Q35 host-bridge anchor missing" >&2; exit 1; }
sed -i 's/case 0x29c0:/case '"${HOST_BRIDGE_DEVICE,,}"':/' "$file"
echo "strong-host-bridge: SeaBIOS identity ${HOST_BRIDGE_DEVICE,,}"
