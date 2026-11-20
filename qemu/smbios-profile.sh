#!/bin/bash
# Make the hard-coded memory/socket profile in smbios.c consistent and configurable.
# The author's file describes DDR3-1600 SODIMM memory on an LGA1700 (Alder Lake) socket —
# DDR3 + a laptop SODIMM form factor on a desktop DDR4/DDR5 board is itself a VM tell.
# This sets the SMBIOS type-17 memory fields and the type-4 socket from config.env so they
# match the board you present in -smbios. Run from the top of the QEMU tree AFTER smbios.patch.
set -euo pipefail
: "${MEM_TYPE_HEX:?}" "${MEM_SPEED:?}" "${MEM_FORM_FACTOR_HEX:?}" "${MEM_VENDOR:?}" \
  "${MEM_PART:?}" "${MEM_VMIN:?}" "${MEM_VMAX:?}" "${MEM_VCFG:?}" "${CPU_SOCKET:?}"
f=hw/smbios/smbios.c

# Each edit: an anchor that must exist before (so we catch structural drift), the sed, and a
# result substring that must exist after. "already-correct" (value equals the author's) is fine.
edit() {   # edit <anchor-before> <sed> <expect-after>
  grep -qF "$1" "$f" || grep -qF "$3" "$f" || { echo "ERROR: anchor not found: $1" >&2; exit 1; }
  sed -i "$2" "$f"
  grep -qF "$3" "$f" || { echo "ERROR: edit did not produce: $3" >&2; exit 1; }
}

edit 'memory_type = 0x18'            "s/t->memory_type = 0x18; \/\* DDR3 \*\//t->memory_type = ${MEM_TYPE_HEX};/"              "memory_type = ${MEM_TYPE_HEX};"
edit 'form_factor = 0x0D'            "s/t->form_factor = 0x0D; \/\* SODIMM \*\//t->form_factor = ${MEM_FORM_FACTOR_HEX};/"     "form_factor = ${MEM_FORM_FACTOR_HEX};"
edit 't->speed = cpu_to_le16(1600)'  "s/t->speed = cpu_to_le16(1600);/t->speed = cpu_to_le16(${MEM_SPEED});/"                   "t->speed = cpu_to_le16(${MEM_SPEED});"
edit 'minimum_voltage = cpu_to_le16(1350)' "s/t->minimum_voltage = cpu_to_le16(1350);/t->minimum_voltage = cpu_to_le16(${MEM_VMIN});/" "minimum_voltage = cpu_to_le16(${MEM_VMIN});"
edit 'maximum_voltage = cpu_to_le16(1500)' "s/t->maximum_voltage = cpu_to_le16(1500);/t->maximum_voltage = cpu_to_le16(${MEM_VMAX});/" "maximum_voltage = cpu_to_le16(${MEM_VMAX});"
edit 'configured_voltage = cpu_to_le16(1350)' "s/t->configured_voltage = cpu_to_le16(1350);/t->configured_voltage = cpu_to_le16(${MEM_VCFG});/" "configured_voltage = cpu_to_le16(${MEM_VCFG});"
edit 'manufacturer_str, "Kingston")'  "s/manufacturer_str, \"Kingston\")/manufacturer_str, \"${MEM_VENDOR}\")/"                "manufacturer_str, \"${MEM_VENDOR}\")"
edit 'part_number_str, "KHX1600C9S3L/32G"' "s#part_number_str, \"KHX1600C9S3L/32G\"#part_number_str, \"${MEM_PART}\"#"           "part_number_str, \"${MEM_PART}\""
edit 'socket_designation_str, "LGA1700"' "s/socket_designation_str, \"LGA1700\"/socket_designation_str, \"${CPU_SOCKET}\"/"     "socket_designation_str, \"${CPU_SOCKET}\""

echo "smbios-profile: applied (${MEM_VENDOR} ${MEM_PART}, type=${MEM_TYPE_HEX} ${MEM_SPEED}MT/s, socket ${CPU_SOCKET})"
