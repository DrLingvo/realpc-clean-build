#!/bin/bash
# Preserve SeaBIOS signature validation while matching optional QEMU fw_cfg identity.
set -euo pipefail
: "${FW_CFG_BRAND:?}"
[[ "$FW_CFG_BRAND" =~ ^[A-Z0-9]{4}$ ]] || { echo "FW_CFG_BRAND must be four ASCII characters" >&2; exit 1; }
file=src/fw/paravirt.c
grep -q 'char \*sig = "QEMU";' "$file" || { echo "ERROR: SeaBIOS signature anchor missing" >&2; exit 1; }
sed -i 's/char \*sig = "QEMU";/char *sig = "'"${FW_CFG_BRAND}"'";/' "$file"
grep -q 'if (inb(PORT_QEMU_CFG_DATA) != sig\[i\])' "$file" || { echo "ERROR: signature validation missing" >&2; exit 1; }
grep -q 'return 0;' "$file" || { echo "ERROR: signature failure path missing" >&2; exit 1; }
echo "strong-fw-cfg: SeaBIOS signature applied"
