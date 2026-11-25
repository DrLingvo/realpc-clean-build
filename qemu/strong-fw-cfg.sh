#!/bin/bash
# Optional, coordinated fw_cfg identity change. OVMF and SeaBIOS must be patched too.
set -euo pipefail
: "${FW_CFG_BRAND:?}" "${FW_CFG_SIGNATURE_HEX:?}" "${FW_CFG_ACPI_ID:?}"
[[ "$FW_CFG_BRAND" =~ ^[A-Z0-9]{4}$ ]] || { echo "FW_CFG_BRAND must be four ASCII characters" >&2; exit 1; }
[[ "$FW_CFG_ACPI_ID" =~ ^[A-Z0-9]{8}$ ]] || { echo "FW_CFG_ACPI_ID must be eight ASCII characters" >&2; exit 1; }
FAILED=0
S() {
  local expr=$1 file=$2 before
  [[ -f "$file" ]] || { echo "ERROR: missing $file" >&2; FAILED=1; return; }
  before=$(md5sum < "$file"); sed -i "$expr" "$file"
  [[ "$before" != "$(md5sum < "$file")" ]] || { echo "ERROR: no match in $file" >&2; FAILED=1; }
}
S 's/0x51454d5520434647ULL/'"${FW_CFG_SIGNATURE_HEX}"'ULL/g' hw/nvram/fw_cfg.c
S 's/"QEMU0002/"'"${FW_CFG_ACPI_ID}"'/g' include/standard-headers/linux/qemu_fw_cfg.h
S 's/0x51454d5520434647ULL/'"${FW_CFG_SIGNATURE_HEX}"'ULL/g' include/standard-headers/linux/qemu_fw_cfg.h
S 's/0x51454d5520434647ULL/'"${FW_CFG_SIGNATURE_HEX}"'ULL/g' pc-bios/optionrom/optionrom.h
[[ "$FAILED" == 0 ]] || exit 1
echo "strong-fw-cfg: QEMU and option ROM identity applied"
