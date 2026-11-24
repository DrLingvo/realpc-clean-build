#!/bin/bash
# Print a single hash of the build "recipe": the pinned upstream commits plus every patch and
# script that shapes the output. The produced binaries are NOT byte-reproducible (edk2 embeds a
# random per-build stack cookie; SeaBIOS embeds a build timestamp), so instead we pin and hash
# the INPUTS. Same recipe-hash => same sources + same edits, whoever builds it.
set -euo pipefail
cd "$(dirname "$0")/.."

files=$(git ls-files 2>/dev/null | grep -E \
  '^(config\.env|build\.sh|qemu/.*\.(patch|sh|c)|edk2/.*\.(patch|sh)|seabios/.*\.(patch|sh)|acpi/.*\.(dsl|sh|py)|kernel/.*\.(py|sh)|ci/container-build\.sh|tools/.*\.py|\.github/workflows/build\.yml)$' \
  | sort || true)
[ -n "$files" ] || { echo "run inside the git repo" >&2; exit 1; }

echo "# recipe inputs:"
# Per-file hashes (so a change is easy to localize), then one combined hash. External artwork
# named in config.env is also an input: hash its contents, not its machine-specific path.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
set -a; . ./config.env; set +a
{
  for f in $files; do sha256sum "$f"; done
  for var in LOGO_BMP BOOTSPLASH_JPG; do
    path=${!var:-}
    [ -n "$path" ] || continue
    [ -f "$path" ] || { echo "$var points to a missing file: $path" >&2; exit 1; }
    printf '%s  %s\n' "$(sha256sum "$path" | awk '{print $1}')" "$var"
  done
} | tee "$tmp" | sed 's/^/  /'
echo
echo "RECIPE-SHA256: $(sha256sum < "$tmp" | awk '{print $1}')"
