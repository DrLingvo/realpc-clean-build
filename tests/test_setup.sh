#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export REALPC_SETUP_SOURCE_ONLY=1
# shellcheck source=../deploy/realpc-setup.sh
source "$ROOT/deploy/realpc-setup.sh"

WORKDIR="$TMP/assets"
STATE="$WORKDIR/.realpc-state"
mkdir -p "$WORKDIR"
printf qemu > "$WORKDIR/pve-qemu-kvm_1_amd64.deb"
printf ovmf > "$WORKDIR/pve-edk2-firmware-ovmf_1_all.deb"
for name in ssdt.aml ssdt-ec.aml hpet.aml; do printf '%s' "$name" > "$WORKDIR/$name"; done
(cd "$WORKDIR" && sha256sum ./* > SHA256SUMS)
required=(pve-qemu-kvm_1_amd64.deb pve-edk2-firmware-ovmf_1_all.deb
          ssdt.aml ssdt-ec.aml hpet.aml)
verify_assets "$WORKDIR" "${required[@]}" >/dev/null

printf corrupt >> "$WORKDIR/ssdt.aml"
if verify_assets "$WORKDIR" "${required[@]}" >/dev/null 2>&1; then
  echo "checksum mismatch was accepted" >&2; exit 1
fi
printf ssdt.aml > "$WORKDIR/ssdt.aml"
rm "$WORKDIR/SHA256SUMS"
if verify_assets "$WORKDIR" "${required[@]}" >/dev/null 2>&1; then
  echo "missing checksum manifest was accepted" >&2; exit 1
fi

# A syntactically valid manifest that omits a required artifact must also fail.
(cd "$WORKDIR" && sha256sum pve-qemu-kvm_1_amd64.deb > SHA256SUMS)
if verify_assets "$WORKDIR" "${required[@]}" >/dev/null 2>&1; then
  echo "incomplete checksum manifest was accepted" >&2; exit 1
fi

# Package backup must be tied to the exact currently installed versions, not a stale .deb.
mkdir -p "$WORKDIR/.backup/packages"
printf stale > "$WORKDIR/.backup/packages/pve-qemu-kvm_stale_amd64.deb"
dpkg-query(){
  case "${@: -1}" in
    pve-qemu-kvm) printf '11.1-test' ;;
    pve-edk2-firmware-ovmf) printf '4.0-test' ;;
    *) return 1 ;;
  esac
}
apt-mark(){ return 0; }
apt-get(){
  [[ "$1" == download ]] || return 1
  local spec=$2 pkg version
  pkg=${spec%%=*}; version=${spec#*=}
  printf '%s' "$version" > "${pkg}_${version}_test.deb"
}
dpkg-deb(){
  local file=$2 base
  base=$(basename "$file")
  printf '%s' "$(cut -d_ -f2 <<< "$base")"
}
backup_packages >/dev/null
for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
  backup=$(st_get "OLD_${pkg}_DEB")
  [[ -f "$backup" && "$backup" != *stale* ]] || { echo "wrong backup selected for $pkg" >&2; exit 1; }
done

# Automatic rollback must not replay state left by an earlier successful installation.
calls="$TMP/package-calls"
restore_package(){ printf '%s\n' "$1" >> "$calls"; }
st_set PKGS 1
TRANSACTION_PKGS=0; TRANSACTION_MODULE=0; TRANSACTION_VMID=""
rollback 1 >/dev/null
[[ ! -e "$calls" ]] || { echo "stale package state triggered automatic rollback" >&2; exit 1; }

# Nor should it restore a module that the current operation never tried to replace.
printf original > "$TMP/kvm.ko.orig"; printf patched > "$TMP/kvm.ko"
st_set MODULE_BACKUP "$TMP/kvm.ko.orig"; st_set MODULE_PATH "$TMP/kvm.ko"
rollback 1 >/dev/null
[[ $(cat "$TMP/kvm.ko") == patched ]] || { echo "stale module state triggered automatic rollback" >&2; exit 1; }

# A failed configvm operation rolls back only its own VM, not every VM in the state file.
for id in 101 102; do
  printf 'backup-%s\n' "$id" > "$TMP/$id.bak"
  printf 'current-%s\n' "$id" > "$TMP/$id.conf"
  st_set "CONF_BAK_$id" "$TMP/$id.bak"; st_set "CONF_PATH_$id" "$TMP/$id.conf"
done
st_set CONF_VMS "101 102"; TRANSACTION_VMID=102
rollback 1 >/dev/null
[[ $(cat "$TMP/101.conf") == current-101 ]] || { echo "unrelated VM 101 was rolled back" >&2; exit 1; }
[[ $(cat "$TMP/102.conf") == backup-102 ]] || { echo "current VM 102 was not rolled back" >&2; exit 1; }

echo "setup asset/transaction tests: PASS"
