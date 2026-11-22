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
printf '0123456789abcdef0123456789abcdef01234567\n' > "$WORKDIR/SOURCE-COMMIT"
for name in ssdt.aml ssdt-ec.aml hpet.aml; do printf '%s' "$name" > "$WORKDIR/$name"; done
(cd "$WORKDIR" && sha256sum ./* > SHA256SUMS)
required=(pve-qemu-kvm_1_amd64.deb pve-edk2-firmware-ovmf_1_all.deb SOURCE-COMMIT
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

# Package backups must match the installed payload, not merely the package version.
make_deb(){
  local pkg=$1 version=$2 payload=$3 out=$4 root="$TMP/deb-build-$pkg-$5"
  rm -rf "$root"; mkdir -p "$root/DEBIAN" "$root/usr/share/$pkg" "$(dirname "$out")"
  printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: test\nDescription: test\n' \
    "$pkg" "$version" > "$root/DEBIAN/control"
  printf '%s' "$payload" > "$root/usr/share/$pkg/payload"
  dpkg-deb --build "$root" "$out" >/dev/null
}
write_installed_md5(){
  local pkg=$1 payload=$2
  mkdir -p "$DPKG_INFO_DIR"
  printf '%s  usr/share/%s/payload\n' "$(printf '%s' "$payload" | md5sum | awk '{print $1}')" \
    "$pkg" > "$DPKG_INFO_DIR/$pkg.md5sums"
}
DPKG_INFO_DIR="$TMP/dpkg-info"
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
  cp "$TMP/repo/${pkg}_${version}.deb" . || return 1
}
for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
  [[ "$pkg" == pve-qemu-kvm ]] && version=11.1-test || version=4.0-test
  make_deb "$pkg" "$version" "stock-$pkg" "$TMP/repo/${pkg}_${version}.deb" stock
  write_installed_md5 "$pkg" "stock-$pkg"
done
backup_packages >/dev/null
for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
  backup=$(st_get "OLD_${pkg}_DEB")
  [[ -f "$backup" && "$backup" != *stale* ]] || { echo "wrong backup selected for $pkg" >&2; exit 1; }
  package_backup_matches "$pkg" "$backup" "$(dpkg-query "$pkg")" \
    || { echo "unverified backup selected for $pkg" >&2; exit 1; }
done

# A repeat update uses the exact archived custom release packages and never
# replaces them with stock packages of the same version from APT.
old_commit=cccccccccccccccccccccccccccccccccccccccc
for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
  [[ "$pkg" == pve-qemu-kvm ]] && version=11.1-test || version=4.0-test
  make_deb "$pkg" "$version" "custom-$pkg" "$TMP/${pkg}_custom.deb" custom
  write_installed_md5 "$pkg" "custom-$pkg"
done
RESOLVED_COMMIT="$old_commit"
record_installed_packages "$TMP/pve-qemu-kvm_custom.deb" "$TMP/pve-edk2-firmware-ovmf_custom.deb"
st_set SOURCE_COMMIT "$old_commit"
apt-get(){ printf 'unexpected APT download\n' >> "$TMP/custom-backup.calls"; return 1; }
backup_packages >/dev/null
[[ ! -e "$TMP/custom-backup.calls" ]] || { echo "custom backup fell back to APT" >&2; exit 1; }
for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
  cmp "$TMP/${pkg}_custom.deb" "$(st_get "OLD_${pkg}_DEB")" >/dev/null \
    || { echo "previous custom package was not preserved for $pkg" >&2; exit 1; }
done

# Old work directories preserve their previous downloads before asset cleanup.
(
  WORKDIR="$TMP/preserve-downloads"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  cp "$TMP/pve-qemu-kvm_custom.deb" "$WORKDIR/pve-qemu-kvm_11.1-test_amd64.deb"
  preserve_existing_packages
  cmp "$WORKDIR/pve-qemu-kvm_11.1-test_amd64.deb" \
    "$PRESERVED_ASSET_DIR/pve-qemu-kvm_11.1-test_amd64.deb" >/dev/null
) || { echo "previous package downloads were not preserved" >&2; exit 1; }

# If the second backup is only a same-version stock package, fail before any
# rollback journal fields are replaced by a mixed old/new set.
if (
  WORKDIR="$TMP/mismatched-backup"; STATE="$WORKDIR/.realpc-state"; DPKG_INFO_DIR="$TMP/mismatch-info"
  PRESERVED_ASSET_DIR=""; mkdir -p "$WORKDIR"
  st_set OLD_pve-qemu-kvm_DEB previous-journal-entry
  write_installed_md5 pve-qemu-kvm stock-pve-qemu-kvm
  write_installed_md5 pve-edk2-firmware-ovmf custom-pve-edk2-firmware-ovmf
  apt-get(){
    [[ "$1" == download ]] || return 1
    local spec=$2 pkg version
    pkg=${spec%%=*}; version=${spec#*=}
    cp "$TMP/repo/${pkg}_${version}.deb" . || return 1
  }
  backup_packages >/dev/null 2>&1
); then
  echo "same-version stock package was accepted as a custom backup" >&2; exit 1
fi
[[ $(sed -n 's/^OLD_pve-qemu-kvm_DEB=//p' "$TMP/mismatched-backup/.realpc-state") == previous-journal-entry ]] \
  || { echo "failed backup damaged the previous rollback journal" >&2; exit 1; }

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

# A repeat strong operation backs up the exact currently active module. It must
# not assume that the first stock-only .realpc-orig file is the previous state.
(
  WORKDIR="$TMP/module-backup"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  printf previous-custom-module > "$TMP/previous-custom.ko"
  modinfo(){ [[ "$1 $2" == "-n kvm" ]] && printf '%s\n' "$TMP/previous-custom.ko"; }
  backup_current_module test-kernel
  saved=$(st_get MODULE_BACKUP)
  [[ $(st_get MODULE_PATH) == "$TMP/previous-custom.ko" ]]
  [[ $(cat "$saved") == previous-custom-module && "$saved" != *.realpc-orig ]]
  [[ "$TRANSACTION_MODULE" == 1 ]]
) || { echo "current module backup failed" >&2; exit 1; }

# Installation metadata is committed atomically: a failed rename must preserve
# the previous mode/tag/kernel instead of leaving a partially updated record.
(
  WORKDIR="$TMP/atomic-state"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  st_set INSTALL_MODE strong; st_set RELEASE_TAG build-old; st_set KERNEL_RELEASE old-kernel
  RESOLVED_TAG=build-new; RESOLVED_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  mv(){ return 1; }
  record_install_state strong >/dev/null 2>&1
) && { echo "state rename failure was accepted" >&2; exit 1; }
[[ $(sed -n 's/^INSTALL_MODE=//p' "$TMP/atomic-state/.realpc-state") == strong ]]
[[ $(sed -n 's/^RELEASE_TAG=//p' "$TMP/atomic-state/.realpc-state") == build-old ]]
[[ $(sed -n 's/^KERNEL_RELEASE=//p' "$TMP/atomic-state/.realpc-state") == old-kernel ]]

# Update fixtures run in subshells so their stubs cannot leak into other cases.
commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
YES=1

# A recorded normal installation updates as normal and records provenance.
(
  WORKDIR="$TMP/update-normal"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  need_root(){ :; }
  fetch_assets(){ RESOLVED_TAG=build-2; RESOLVED_COMMIT="$commit"; }
  install_userspace(){ printf 'packages\n' >> "$TMP/update-normal.calls"; }
  configvm(){ printf 'configvm\n' >> "$TMP/update-normal.calls"; }
  st_set INSTALL_MODE normal; st_set RELEASE_TAG build-1
  update_install >/dev/null
  [[ $(cat "$TMP/update-normal.calls") == packages ]]
  [[ $(st_get INSTALL_MODE) == normal && $(st_get RELEASE_TAG) == build-2 ]]
  [[ $(st_get SOURCE_COMMIT) == "$commit" && -z $(st_get KERNEL_RELEASE) ]]
) || { echo "normal update routing/state failed" >&2; exit 1; }

# The same normal release is a no-op.
(
  WORKDIR="$TMP/update-normal-noop"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  need_root(){ :; }
  fetch_assets(){ RESOLVED_TAG=build-2; RESOLVED_COMMIT="$commit"; }
  install_userspace(){ echo "normal no-op reinstalled packages" >&2; exit 1; }
  st_set INSTALL_MODE normal; st_set RELEASE_TAG build-2
  update_install >/dev/null
) || { echo "normal same-release no-op failed" >&2; exit 1; }

# A recorded strong installation updates both userspace and the module.
(
  WORKDIR="$TMP/update-strong"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  need_root(){ :; }; strong_preflight(){ :; }
  fetch_assets(){ RESOLVED_TAG=build-2; RESOLVED_COMMIT="$commit"; }
  install_userspace(){ printf 'packages\n' >> "$TMP/update-strong.calls"; }
  build_install_module(){ printf 'module\n' >> "$TMP/update-strong.calls"; }
  configvm(){ printf 'configvm\n' >> "$TMP/update-strong.calls"; }
  st_set INSTALL_MODE strong; st_set RELEASE_TAG build-1; st_set KERNEL_RELEASE old-kernel
  update_install >/dev/null
  [[ $(cat "$TMP/update-strong.calls") == $'packages\nmodule' ]]
  [[ $(st_get INSTALL_MODE) == strong && $(st_get RELEASE_TAG) == build-2 ]]
  [[ $(st_get SOURCE_COMMIT) == "$commit" && $(st_get KERNEL_RELEASE) == "$(uname -r)" ]]
) || { echo "strong update routing/state failed" >&2; exit 1; }

# The same strong release on a different running kernel rebuilds only the module.
(
  WORKDIR="$TMP/update-strong-kernel"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  need_root(){ :; }; strong_preflight(){ :; }
  fetch_assets(){ RESOLVED_TAG=build-2; RESOLVED_COMMIT="$commit"; }
  install_userspace(){ printf 'packages\n' >> "$TMP/update-strong-kernel.calls"; }
  build_install_module(){ printf 'module\n' >> "$TMP/update-strong-kernel.calls"; }
  st_set INSTALL_MODE strong; st_set RELEASE_TAG build-2; st_set KERNEL_RELEASE old-kernel
  update_install >/dev/null
  [[ $(cat "$TMP/update-strong-kernel.calls") == module ]]
  [[ $(st_get KERNEL_RELEASE) == "$(uname -r)" && $(st_get RELEASE_TAG) == build-2 ]]
) || { echo "kernel-aware strong update failed" >&2; exit 1; }

# The same strong release and kernel is a no-op.
(
  WORKDIR="$TMP/update-strong-noop"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  need_root(){ :; }; strong_preflight(){ echo "preflight ran for strong no-op" >&2; exit 1; }
  fetch_assets(){ RESOLVED_TAG=build-2; RESOLVED_COMMIT="$commit"; }
  install_userspace(){ echo "strong no-op reinstalled packages" >&2; exit 1; }
  build_install_module(){ echo "strong no-op rebuilt module" >&2; exit 1; }
  st_set INSTALL_MODE strong; st_set RELEASE_TAG build-2; st_set KERNEL_RELEASE "$(uname -r)"
  update_install >/dev/null
) || { echo "strong same-release/kernel no-op failed" >&2; exit 1; }

# Missing or ambiguous state fails before downloads or system changes.
for bad_state in missing ambiguous; do
  if (
    WORKDIR="$TMP/update-bad-$bad_state"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
    need_root(){ :; }
    fetch_assets(){ printf 'download\n' >> "$TMP/update-bad-$bad_state.calls"; }
    install_userspace(){ printf 'packages\n' >> "$TMP/update-bad-$bad_state.calls"; }
    [[ "$bad_state" == ambiguous ]] && st_set INSTALL_MODE unexpected
    update_install >/dev/null 2>&1
  ); then
    echo "$bad_state state was accepted by update" >&2; exit 1
  fi
  [[ ! -e "$TMP/update-bad-$bad_state.calls" ]] || {
    echo "$bad_state state caused changes before validation" >&2; exit 1;
  }
done

# A download failure has no transaction to roll back and preserves the old state.
if (
  WORKDIR="$TMP/update-download-fail"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  need_root(){ :; }
  fetch_assets(){ die "simulated download failure"; }
  install_userspace(){ printf 'packages\n' >> "$TMP/update-download-fail.calls"; }
  st_set INSTALL_MODE normal; st_set RELEASE_TAG build-1
  update_install >/dev/null 2>&1
); then
  echo "download failure was accepted" >&2; exit 1
fi
[[ ! -e "$TMP/update-download-fail.calls" ]] || { echo "download failure installed packages" >&2; exit 1; }

# Package and strong build failures invoke automatic rollback and do not commit
# the new release state. The explicit rollback stub records its numeric argument.
for failure in packages module; do
  if (
    WORKDIR="$TMP/update-fail-$failure"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
    need_root(){ :; }; strong_preflight(){ :; }
    fetch_assets(){ RESOLVED_TAG=build-2; RESOLVED_COMMIT="$commit"; }
    install_userspace(){
      TRANSACTION_PKGS=1
      [[ "$failure" == packages ]] && die "simulated package failure"
    }
    build_install_module(){ TRANSACTION_MODULE=1; die "simulated build failure"; }
    rollback(){ printf '%s\n' "$1" >> "$TMP/update-fail-$failure.rollback"; }
    if [[ "$failure" == packages ]]; then
      st_set INSTALL_MODE normal
    else
      st_set INSTALL_MODE strong; st_set KERNEL_RELEASE old-kernel
    fi
    st_set RELEASE_TAG build-1
    update_install >/dev/null 2>&1
  ); then
    echo "$failure failure was accepted" >&2; exit 1
  fi
  [[ $(cat "$TMP/update-fail-$failure.rollback") == 1 ]] || {
    echo "$failure failure did not trigger automatic rollback" >&2; exit 1;
  }
  [[ $(sed -n 's/^RELEASE_TAG=//p' "$TMP/update-fail-$failure/.realpc-state") == build-1 ]] || {
    echo "$failure failure committed the new release state" >&2; exit 1;
  }
done

echo "setup update/state tests: PASS"
