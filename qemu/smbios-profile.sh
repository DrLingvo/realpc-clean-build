#!/bin/bash
# Keep the generated desktop memory and cache profile consistent.
# Run from the QEMU source root after smbios.patch.
set -euo pipefail
: "${MEM_TYPE_HEX:?}"
f=hw/smbios/smbios.c
edit() {
  grep -qF "$1" "$f" || grep -qF "$3" "$f" || {
    echo "ERROR: SMBIOS anchor not found: $1" >&2; exit 1;
  }
  sed -i "$2" "$f"
  grep -qF "$3" "$f" || { echo "ERROR: SMBIOS edit failed: $3" >&2; exit 1; }
}
edit 't->memory_type = 0x07; /* RAM */' \
  "s/t->memory_type = 0x07; \/\* RAM \*\//t->memory_type = ${MEM_TYPE_HEX};/" \
  "memory_type = ${MEM_TYPE_HEX};"
edit 't->l1_cache_handle = cpu_to_le16(0xFFFF); /* N/A */' \
  's/t->l1_cache_handle = cpu_to_le16(0xFFFF);/t->l1_cache_handle = cpu_to_le16(0x0700);/' \
  'l1_cache_handle = cpu_to_le16(0x0700);'
edit 't->l2_cache_handle = cpu_to_le16(0xFFFF);' \
  's/t->l2_cache_handle = cpu_to_le16(0xFFFF);/t->l2_cache_handle = cpu_to_le16(0x0702);/' \
  'l2_cache_handle = cpu_to_le16(0x0702);'
edit 't->l3_cache_handle = cpu_to_le16(0xFFFF);' \
  's/t->l3_cache_handle = cpu_to_le16(0xFFFF);/t->l3_cache_handle = cpu_to_le16(0x0703);/' \
  'l3_cache_handle = cpu_to_le16(0x0703);'
edit 'SMBIOS_BUILD_TABLE_PRE(8, T0_BASE + instance, true);' \
  's/SMBIOS_BUILD_TABLE_PRE(8, T0_BASE + instance, true);/SMBIOS_BUILD_TABLE_PRE(8, T8_BASE + instance, true);/' \
  'SMBIOS_BUILD_TABLE_PRE(8, T8_BASE + instance, true);'
echo "smbios-profile: applied desktop memory type ${MEM_TYPE_HEX} and cache links"
