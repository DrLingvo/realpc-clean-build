#!/bin/bash
# Compile the ACPI tables from source (.dsl, decompiled from the author's .aml with iasl).
# The ASL compiler revision field is set to the value in the author's files so the
# output is byte-identical; SHA256SUMS.author lets you check that.
# usage: build-acpi.sh <outdir>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:?outdir}
mkdir -p "$out"
declare -A REV=( [ssdt]=20210930 [ssdt-battery]=20210930 [ssdt-ec]=20250404 [hpet]=20250404 )
for t in ssdt ssdt-battery ssdt-ec hpet; do
  # iasl can return success after reporting ASL errors. Require an explicit successful compile.
  if ! iasl -p "$out/$t" "$here/$t.dsl" >"$out/$t.iasl.log" 2>&1 || \
     ! grep -q 'Compilation successful' "$out/$t.iasl.log"; then
    cat "$out/$t.iasl.log" >&2
    exit 1
  fi
  rm -f "$out/$t.iasl.log"
  python3 -I - "$out/$t.aml" "${REV[$t]}" <<'EOF'
import sys, struct
p, rev = sys.argv[1], int(sys.argv[2], 16)
b = bytearray(open(p, 'rb').read())
b[0x20:0x24] = struct.pack('<I', rev)   # Asl Compiler Revision
b[9] = 0
b[9] = (-sum(b)) & 0xff                  # table checksum
open(p, 'wb').write(b)
EOF
done
( cd "$out" && sha256sum -c "$here/SHA256SUMS.author" ) || echo "NOTE: output differs from the author's tables (expected if you edited the .dsl files)"

python3 -I "$here/build-wsmt.py" "$out/wsmt.aml"
