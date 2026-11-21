#!/bin/bash
# Print a single hash of the build "recipe": the pinned upstream commits plus every patch and
# script that shapes the output. The produced binaries are NOT byte-reproducible (edk2 embeds a
# random per-build stack cookie; SeaBIOS embeds a build timestamp), so instead we pin and hash
# the INPUTS. Same recipe-hash => same sources + same edits, whoever builds it.
set -euo pipefail
cd "$(dirname "$0")/.."

files=$(git ls-files 2>/dev/null | grep -E \
  '^(config\.env|build\.sh|qemu/.*\.(patch|sh)|edk2/.*\.sh|seabios/.*\.patch|acpi/.*\.(dsl|sh)|kernel/.*\.(py|sh))$' \
  | sort || true)
[ -n "$files" ] || { echo "run inside the git repo" >&2; exit 1; }

echo "# recipe inputs:"
# per-file hashes (so a change is easy to localize), then one combined hash
tmp=$(mktemp)
for f in $files; do sha256sum "$f"; done | tee "$tmp" | sed 's/^/  /'
echo
echo "RECIPE-SHA256: $(sha256sum < "$tmp" | awk '{print $1}')"
rm -f "$tmp"
