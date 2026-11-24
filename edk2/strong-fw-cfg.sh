#!/bin/bash
# Keep OVMF's four-byte legacy fw_cfg probe synchronized with QEMU.
set -euo pipefail
: "${FW_CFG_BRAND:?}"
[[ "$FW_CFG_BRAND" =~ ^[A-Z0-9]{4}$ ]] || { echo "FW_CFG_BRAND must be four ASCII characters" >&2; exit 1; }
mapfile -t files < <(grep -RIl --include='*.c' '"QEMU"' OvmfPkg/Library/QemuFwCfgLib)
[[ ${#files[@]} -gt 0 ]] || { echo "ERROR: no OVMF fw_cfg QEMU signature found" >&2; exit 1; }
for file in "${files[@]}"; do
  sed -i 's/"QEMU"/"'"${FW_CFG_BRAND}"'"/g' "$file"
  grep -q '"'"${FW_CFG_BRAND}"'"' "$file" || exit 1
done
printf 'strong-fw-cfg: OVMF signature applied in %d source files\n' "${#files[@]}"
