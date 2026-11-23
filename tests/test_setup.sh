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
for name in ssdt.aml ssdt-ec.aml hpet.aml wsmt.aml; do printf '%s' "$name" > "$WORKDIR/$name"; done
(cd "$WORKDIR" && sha256sum ./* > SHA256SUMS)
required=(pve-qemu-kvm_1_amd64.deb pve-edk2-firmware-ovmf_1_all.deb SOURCE-COMMIT
          ssdt.aml ssdt-ec.aml hpet.aml wsmt.aml)
verify_assets "$WORKDIR" "${required[@]}" >/dev/null
grep -q 'dist/wsmt.aml' "$ROOT/.github/workflows/release.yml"
# QEMU 11.1.3 accepts these SMBIOS option names; do not reintroduce newer-API spellings.
grep -q 'internal_reference=J' "$ROOT/deploy/realpc-setup.sh"
grep -q 'slot_designation=SLOT' "$ROOT/deploy/realpc-setup.sh"
! grep -q 'internal_reference_designator\|external_reference_designator\|busaddr=' "$ROOT/deploy/realpc-setup.sh"
grep -q 'T8_BASE + instance' "$ROOT/qemu/smbios-profile.sh"
grep -q 'l1_cache_handle = cpu_to_le16(0x0700)' "$ROOT/qemu/smbios-profile.sh"
# FADT Preferred_PM_Profile is serialized directly by this pinned QEMU version.
grep -q 'build_append_int_noprefix(tbl, 1 .* Desktop .*, 1);' "$ROOT/qemu/anti-detection.sh"
! grep -q 'fadt.preferred_pm_profile' "$ROOT/qemu/anti-detection.sh"

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

# A journal-only exact backup is sufficient; no manual staging in installed/
# or previous-downloads is required on a repeat update.
(
  WORKDIR="$TMP/journal-only"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  journal="$TMP/pve-qemu-kvm_custom.deb"
  st_set "OLD_pve-qemu-kvm_DEB" "$journal"
  st_set SOURCE_COMMIT deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  PRESERVED_ASSET_DIR=""
  selected="$(find_verified_package_backup pve-qemu-kvm 11.1-test)"
  [[ "$selected" == "$journal" ]] || { echo "journal path mismatch: $selected" >&2; exit 1; }
) || { echo "journal-only exact package backup was not reused" >&2; exit 1; }

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

# Prove with real dpkg in an isolated package database that explicit dpkg -i
# reinstalls same-version custom payloads even when both packages are held.
(
  dbroot="$TMP/real-dpkg-root"
  mkdir -p "$dbroot/var/lib/dpkg"
  : > "$dbroot/var/lib/dpkg/status"
  for stage in old new; do
    make_deb pve-qemu-kvm 11.1-test "$stage-qemu" \
      "$TMP/real-dpkg-qemu-$stage.deb" "real-dpkg-q-$stage"
    make_deb pve-edk2-firmware-ovmf 11.1-test "$stage-ovmf" \
      "$TMP/real-dpkg-ovmf-$stage.deb" "real-dpkg-o-$stage"
  done
  real_dpkg=(dpkg --force-not-root --root="$dbroot" --log="$dbroot/dpkg.log")
  "${real_dpkg[@]}" -i "$TMP/real-dpkg-qemu-old.deb" "$TMP/real-dpkg-ovmf-old.deb" >/dev/null
  printf 'pve-qemu-kvm hold\npve-edk2-firmware-ovmf hold\n' \
    | "${real_dpkg[@]}" --set-selections
  "${real_dpkg[@]}" -i "$TMP/real-dpkg-qemu-new.deb" "$TMP/real-dpkg-ovmf-new.deb" >/dev/null
  [[ $(cat "$dbroot/usr/share/pve-qemu-kvm/payload") == new-qemu ]]
  [[ $(cat "$dbroot/usr/share/pve-edk2-firmware-ovmf/payload") == new-ovmf ]]
) || { echo "real same-version held dpkg reinstall failed" >&2; exit 1; }

# Release installation must use only the two exact .deb files. This covers a
# same-version custom QEMU and a held OVMF without APT downgrade/held flags.
(
  WORKDIR="$TMP/exact-install"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  YES=1; TRANSACTION_PKGS=0
  installed_qemu_version=11.1-test
  q="$WORKDIR/pve-qemu-kvm_11.1-test_amd64.deb"
  o="$WORKDIR/pve-edk2-firmware-ovmf_4.0-test_all.deb"
  make_deb pve-qemu-kvm "$installed_qemu_version" release-qemu "$q" exact-install-q
  make_deb pve-edk2-firmware-ovmf 4.0-test release-ovmf "$o" exact-install-o
  backup_packages(){ :; }
  record_installed_packages(){ printf 'record %s %s\n' "$1" "$2" >> "$TMP/exact-install.calls"; }
  dpkg(){
    printf 'dpkg' >> "$TMP/exact-install.calls"; printf ' %s' "$@" >> "$TMP/exact-install.calls"
    printf '\n' >> "$TMP/exact-install.calls"
    [[ "$1" == --audit ]] && return 0
    [[ "$1" == -i && "$# == 3" ]] || return 1
    # The release has the same version as the installed custom QEMU; dpkg -i
    # must nevertheless be invoked rather than APT skipping it as up to date.
    [[ $(dpkg-deb -f "$2" Version) == "$installed_qemu_version" ]] || return 1
  }
  apt-get(){
    printf 'apt-get' >> "$TMP/exact-install.calls"; printf ' %s' "$@" >> "$TMP/exact-install.calls"
    printf '\n' >> "$TMP/exact-install.calls"
    [[ "$1" == check ]]
  }
  apt-mark(){
    printf 'apt-mark' >> "$TMP/exact-install.calls"; printf ' %s' "$@" >> "$TMP/exact-install.calls"
    printf '\n' >> "$TMP/exact-install.calls"
  }
  install_userspace >/dev/null
  expected=$'dpkg --audit\napt-get check\n'
  expected+="dpkg -i $q $o"$'\n'
  expected+=$'dpkg --audit\napt-get check\n'
  expected+=$'apt-mark hold pve-qemu-kvm pve-edk2-firmware-ovmf\n'
  expected+="record $q $o"
  [[ $(cat "$TMP/exact-install.calls") == "$expected" ]]
  [[ "$TRANSACTION_PKGS" == 1 && $(st_get PKGS) == 1 ]]
  ! grep -Eq 'apt-get install|allow-downgrades|allow-change-held-packages|ceph-fuse' \
    "$TMP/exact-install.calls"
) || { echo "exact same-version/held package installation failed" >&2; exit 1; }

# A dpkg failure leaves the rollback scope armed and never falls back to APT.
if (
  WORKDIR="$TMP/exact-install-fail"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  YES=1; TRANSACTION_PKGS=0
  make_deb pve-qemu-kvm 11.1-test release-qemu \
    "$WORKDIR/pve-qemu-kvm_11.1-test_amd64.deb" install-fail-q
  make_deb pve-edk2-firmware-ovmf 4.0-test release-ovmf \
    "$WORKDIR/pve-edk2-firmware-ovmf_4.0-test_all.deb" install-fail-o
  backup_packages(){ :; }
  dpkg(){
    printf 'dpkg %s\n' "$1" >> "$TMP/exact-install-fail.calls"
    [[ "$1" == --audit ]]
  }
  apt-get(){
    printf 'apt-get %s\n' "$1" >> "$TMP/exact-install-fail.calls"
    [[ "$1" == check ]]
  }
  install_userspace >/dev/null 2>&1
); then
  echo "dpkg installation failure was accepted" >&2; exit 1
fi
[[ $(sed -n 's/^PKGS=//p' "$TMP/exact-install-fail/.realpc-state") == 1 ]] \
  || { echo "failed installation did not preserve rollback scope" >&2; exit 1; }
[[ $(grep -c '^dpkg --audit$' "$TMP/exact-install-fail.calls") == 1 \
   && $(grep -c '^apt-get check$' "$TMP/exact-install-fail.calls") == 1 ]] \
  || { echo "failed installation ran a post-change health check incorrectly" >&2; exit 1; }
! grep -q 'apt-get install' "$TMP/exact-install-fail.calls" \
  || { echo "failed installation fell back to APT" >&2; exit 1; }

# Automatic rollback restores only the exact archived packages, including a
# held OVMF, and checks dependency health after both dpkg operations.
(
  WORKDIR="$TMP/exact-rollback"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  q="$TMP/pve-qemu-kvm_custom.deb"; o="$TMP/pve-edk2-firmware-ovmf_custom.deb"
  st_set PKGS 1
  st_set OLD_pve-qemu-kvm_VERSION 11.1-test; st_set OLD_pve-qemu-kvm_HOLD 0
  st_set OLD_pve-qemu-kvm_DEB "$q"
  st_set OLD_pve-edk2-firmware-ovmf_VERSION 4.0-test; st_set OLD_pve-edk2-firmware-ovmf_HOLD 1
  st_set OLD_pve-edk2-firmware-ovmf_DEB "$o"
  TRANSACTION_PKGS=1; TRANSACTION_MODULE=0; TRANSACTION_VMID=""
  dpkg(){
    printf 'dpkg' >> "$TMP/exact-rollback.calls"; printf ' %s' "$@" >> "$TMP/exact-rollback.calls"
    printf '\n' >> "$TMP/exact-rollback.calls"
    [[ "$1" == --audit || "$1" == -i ]]
  }
  apt-get(){
    printf 'apt-get' >> "$TMP/exact-rollback.calls"; printf ' %s' "$@" >> "$TMP/exact-rollback.calls"
    printf '\n' >> "$TMP/exact-rollback.calls"
    [[ "$1" == check ]]
  }
  apt-mark(){
    printf 'apt-mark' >> "$TMP/exact-rollback.calls"; printf ' %s' "$@" >> "$TMP/exact-rollback.calls"
    printf '\n' >> "$TMP/exact-rollback.calls"
  }
  rollback 1 >/dev/null
  expected="dpkg -i $q"$'\n'$'apt-mark unhold pve-qemu-kvm\n'
  expected+="dpkg -i $o"$'\n'$'apt-mark hold pve-edk2-firmware-ovmf\n'
  expected+=$'dpkg --audit\napt-get check'
  [[ $(cat "$TMP/exact-rollback.calls") == "$expected" ]]
  [[ $(st_get PKGS) == 0 ]]
  ! grep -Eq 'apt-get install|allow-downgrades|allow-change-held-packages|ceph-fuse' \
    "$TMP/exact-rollback.calls"
) || { echo "exact backup rollback failed" >&2; exit 1; }

# A rollback error remains visible and keeps PKGS armed for a later retry.
(
  WORKDIR="$TMP/exact-rollback-fail"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  q="$TMP/pve-qemu-kvm_custom.deb"; o="$TMP/pve-edk2-firmware-ovmf_custom.deb"
  st_set PKGS 1
  st_set OLD_pve-qemu-kvm_VERSION 11.1-test; st_set OLD_pve-qemu-kvm_HOLD 0
  st_set OLD_pve-qemu-kvm_DEB "$q"
  st_set OLD_pve-edk2-firmware-ovmf_VERSION 4.0-test; st_set OLD_pve-edk2-firmware-ovmf_HOLD 1
  st_set OLD_pve-edk2-firmware-ovmf_DEB "$o"
  TRANSACTION_PKGS=1; TRANSACTION_MODULE=0; TRANSACTION_VMID=""
  dpkg(){ [[ "$1" == --audit ]] && return 0; [[ "$2" != "$o" ]]; }
  apt-get(){ [[ "$1" == check ]]; }
  apt-mark(){ :; }
  if rollback 1 >/dev/null 2>&1; then
    echo "rollback dpkg failure was masked" >&2; exit 1
  fi
  [[ $(st_get PKGS) == 1 ]]
) || { echo "failed rollback state handling failed" >&2; exit 1; }

# Without an exact archived .deb, rollback must not reinstall a same-version
# stock package through APT or touch unrelated dependencies.
(
  WORKDIR="$TMP/no-backup-rollback"; STATE="$WORKDIR/.realpc-state"; mkdir -p "$WORKDIR"
  st_set OLD_pve-qemu-kvm_VERSION 11.1-test; st_set OLD_pve-qemu-kvm_HOLD 0
  apt-get(){ printf '%s\n' "$*" >> "$TMP/no-backup-rollback.calls"; return 1; }
  apt-mark(){ :; }
  if restore_package pve-qemu-kvm >/dev/null 2>&1; then
    echo "rollback without an exact backup was accepted" >&2; exit 1
  fi
  [[ ! -e "$TMP/no-backup-rollback.calls" ]]
) || { echo "missing-backup rollback used an unsafe fallback" >&2; exit 1; }

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

# WSMT is a standard 36-byte ACPI header plus one 32-bit protection-flags field.
python3 -I "$ROOT/acpi/build-wsmt.py" "$TMP/wsmt.aml"
python3 -I - "$TMP/wsmt.aml" <<'PY'
from pathlib import Path
import struct
import sys
p = Path(sys.argv[1]).read_bytes()
assert len(p) == 40 and p[:4] == b"WSMT"
assert struct.unpack_from("<I", p, 4)[0] == 40
assert struct.unpack_from("<I", p, 36)[0] == 0
assert sum(p) & 0xff == 0
PY

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

# Kernel build fixes: exact dependency/artifact names and idempotent source edits.
grep -q 'libdw-dev' "$ROOT/kernel/build-kvm.sh"
grep -q 'out/kvm.ko"' "$ROOT/kernel/build-kvm.sh"
! grep -q 'kvm.ko-\$KREL' "$ROOT/kernel/build-kvm.sh"
! grep -q 'kvm.ko-\$rel' "$ROOT/deploy/realpc-setup.sh"
kdir="$TMP/kernel-fixture/arch/x86/kvm"
mkdir -p "$kdir"
cat > "$kdir/x86.c" <<'C'
static int complete_hypercall_exit(struct kvm_vcpu *vcpu) { return 0; }
int kvm_emulate_hypercall(struct kvm_vcpu *vcpu) { return 0; }
static int emulator_fix_hypercall(struct x86_emulate_ctxt *ctxt) { return 0; }
C
cat > "$kdir/cpuid.c" <<'C'
void kvm_vcpu_after_set_cpuid(struct kvm_vcpu *vcpu)
{
	struct kvm_cpuid_entry2 *best;
	memset(vcpu->arch.cpu_caps, 0, sizeof(vcpu->arch.cpu_caps));
	kvm_update_cpuid_runtime(vcpu);
}
C
python3 "$ROOT/kernel/kvm-antidetect.py" "$kdir/x86.c" >/dev/null
python3 "$ROOT/kernel/kvm-antidetect.py" "$kdir/x86.c" >/dev/null
grep -q '__maybe_unused complete_hypercall_exit' "$kdir/x86.c"
grep -q 'realpc_clear_hypervisor_bit' "$kdir/cpuid.c"
grep -q 'best = kvm_find_cpuid_entry(vcpu, 1)' "$kdir/cpuid.c"
grep -q 'ecx &= ~BIT(31)' "$kdir/cpuid.c"
[[ $(grep -c 'realpc_clear_hypervisor_bit' "$kdir/cpuid.c") == 1 ]]
echo "kernel build/injector tests: PASS"

# host-tools contract v1: locking, ordered fragments, vGPU preservation,
# idempotence, snapshot safety, normal VGA, and hash-aware rollback.
contract="$TMP/contract"
mkdir -p "$contract/pve" "$contract/args.d/100" "$contract/assets/.bak"
(
  WORKDIR="$contract/assets"; STATE="$WORKDIR/.realpc-state"
  PVE_QEMU_DIR="$contract/pve"; HOST_TOOLS_ARGS_D="$contract/args.d"
  HOST_TOOLS_LOCK="$contract/host-tools.lock"; HOST_TOOLS_LOCK_TIMEOUT=60
  need_root(){ :; }; cpu_model(){ printf 'Test CPU'; }; cpu_vendor(){ printf intel; }
  YES=1; VMID=100
  for name in "${CFG_AML[@]}"; do printf '%s' "$name" > "$WORKDIR/$name"; done
  (cd "$WORKDIR" && sha256sum ./*.aml > SHA256SUMS)
  cat > "$PVE_QEMU_DIR/100.conf" <<'CFG'
name: contract
vga: none
hostpci0: 0000:00:02.0,pcie=1
args: -set device.hostpci0.bus=pcie.0 -global old.setting=1
[snapshot "before"]
args: snapshot-unchanged
vga: std
hostpci0: 0000:00:02.0,snapshot=1
CFG
  printf '%s\n' '-object early=1' > "$HOST_TOOLS_ARGS_D/100/10-early.args"
  printf '%s\n' '-set device.hostpci0.addr=0x02 -object vgpu=1' > "$HOST_TOOLS_ARGS_D/100/50-pve-intel-gpu.args"
  qm(){
    [[ "$1" == set ]] || return 1
    local id=$2; shift 2
    python3 - "$PVE_QEMU_DIR/$id.conf" "$@" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
pairs = dict(zip(sys.argv[2::2], sys.argv[3::2]))
lines = path.read_text().splitlines(keepends=True)
end = next((i for i, line in enumerate(lines) if line.startswith("[")), len(lines))
main, snapshots = lines[:end], lines[end:]
for option, value in pairs.items():
    key = option.removeprefix("--")
    main = [line for line in main if not line.startswith(key + ":")]
    main.append(f"{key}: {value}\n")
path.write_text("".join(main + snapshots))
PY
  }
  configvm >/dev/null
  conf="$PVE_QEMU_DIR/100.conf"
  grep -q '^vga: none$' "$conf"
  grep -q '^hostpci0: 0000:00:02.0,pcie=1$' "$conf"
  grep -q '^CONTRACT_VERSION=1$' "$STATE"
  [[ $(grep -c -- '-object early=1' "$conf") == 1 ]]
  [[ $(grep -c -- '-object vgpu=1' "$conf") == 1 ]]
  python3 - "$conf" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
main, snapshot = text.split("[snapshot", 1)
assert main.index("-object early=1") < main.index("-object vgpu=1")
assert "args: snapshot-unchanged" in snapshot
assert "vga: std" in snapshot
assert "hostpci0: 0000:00:02.0,snapshot=1" in snapshot
assert "-global old.setting=1" not in main
PY
  cp "$conf" "$contract/after-first.conf"
  configvm >/dev/null
  cmp "$conf" "$contract/after-first.conf" >/dev/null

  # Another tool changes memory and its fragment after our recorded hash.
  printf '\nmemory: 8192\n' >> "$conf"
  printf '%s\n' '-set device.hostpci0.addr=0x03 -object vgpu=2' > "$HOST_TOOLS_ARGS_D/100/50-pve-intel-gpu.args"
  rollback 0 >/dev/null
  grep -q '^memory: 8192$' "$conf"
  grep -q '^vga: none$' "$conf"
  grep -q '^hostpci0: 0000:00:02.0,pcie=1$' "$conf"
  [[ $(grep -c -- '-object vgpu=2' "$conf") == 1 ]]
  ! grep -q -- '-object vgpu=1' "$conf"
  grep -q 'args: snapshot-unchanged' "$conf"

  # Ordinary VMs use std VGA, not the VMware adapter/driver path.
  VMID=101
  cat > "$PVE_QEMU_DIR/101.conf" <<'CFG'
name: ordinary
vga: vmware
CFG
  configvm >/dev/null
  grep -q '^vga: std$' "$PVE_QEMU_DIR/101.conf"
  ! grep -q '^vga: vmware$' "$PVE_QEMU_DIR/101.conf"
) || { echo "host-tools contract test failed" >&2; exit 1; }

# Lock contention fails closed without waiting forever.
(
  HOST_TOOLS_LOCK="$contract/contended.lock"; HOST_TOOLS_LOCK_TIMEOUT=1
  exec 9>"$HOST_TOOLS_LOCK"
  flock 9
  if (acquire_host_tools_lock >/dev/null 2>&1); then exit 1; fi
) || { echo "host-tools lock contention was ignored" >&2; exit 1; }
echo "host-tools contract tests: PASS"
