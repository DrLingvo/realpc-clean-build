#!/usr/bin/env bash
# Compatibility wrapper around the transactional installer.
#   ./install-userspace.sh /path/to/release/dir
#   ./install-userspace.sh --revert [/path/to/release/dir]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
setup="$here/realpc-setup.sh"
[ -f "$setup" ] || { echo "missing $setup" >&2; exit 1; }

if [ "${1:-}" = --revert ]; then
  workdir=${2:-/root/realpc}
  exec bash "$setup" --mode rollback --dir "$workdir" --download 0 --yes
fi

dir=${1:?usage: install-userspace.sh <dir with release .deb, .aml, SOURCE-COMMIT and SHA256SUMS>}
exec bash "$setup" --mode normal --dir "$dir" --download 0 --yes
