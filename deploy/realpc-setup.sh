#!/usr/bin/env bash
###############################################################################
# realpc-setup.sh - install and update the open realpc build on Proxmox VE 9.
# Repository: DrLingvo/realpc-clean-build
#
# Modes: check | normal | strong | update | configvm | rollback
#   normal   Install QEMU with host-sensors, OVMF and ACPI files.
#   strong   Install userspace and the open kvm.ko. Use a verified prebuilt module
#            by default, or --kvm-build to build for the exact running kernel.
#   update   Download a release and update the mode recorded by a previous
#            successful normal/strong installation. VM configs are untouched.
#   configvm Install ACPI files and replace the VM args line.
#   rollback Restore packages, module and VM configs from the state journal.
#
# Strong is the recommended mode. It is experimental and host-wide. Stop all
# VMs, disable Secure Boot and keep a way to boot a previous kernel.
#
# Release files are downloaded (--download 1) or read from --dir
# (--download 0). Every required file must match that release's SHA256SUMS.
# Use the CONFIG section below or command-line options. Options take priority.
###############################################################################

############################### CONFIG ########################################
CFG_REPO="DrLingvo/realpc-clean-build"
CFG_MODE="check"                          # check|normal|strong|update|configvm|rollback
CFG_RELEASE="latest"                      # latest or an exact release tag
CFG_WORKDIR="/root/realpc"                # Downloads, state and rollback backups
CFG_DOWNLOAD=1                            # 1: GitHub; 0: existing files in WORKDIR
CFG_LOG="none"                            # none|normal|debug (file logging only)
CFG_LOGFILE=""                            # Empty: <script directory>/<script name>.log
CFG_VMID=""                               # VM ID for configvm
CFG_YES=0                                 # 1: do not ask for confirmation
CFG_KSRC=""                               # strong build: matching kernel source tree
CFG_KVM_BUILD=0                           # strong: 0: prebuilt; 1: build on this host
CFG_MIN_FREE_MB=8192                      # strong build: minimum free space in WORKDIR

CFG_AML=(ssdt.aml wsmt.aml)
CFG_KERNEL_ASSET="realpc-kernel-tools.tar.gz"
CFG_VM_TOOLS_ASSET="realpc-vm-tools.tar.gz"
CFG_SOURCE_ASSET="SOURCE-COMMIT"

# VM identity is generated from the real host by tools/gen-profile.py.
# No arbitrary CPU SKU or shared hard-coded SMBIOS serial is allowed here.
############################# /CONFIG #########################################

set -uo pipefail

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SELF_DIR="$(dirname "$SELF")"; SELF_NAME="$(basename "$SELF")"; SELF_NAME="${SELF_NAME%.*}"

REPO="$CFG_REPO"; MODE="$CFG_MODE"; RELEASE="$CFG_RELEASE"; WORKDIR="$CFG_WORKDIR"
DOWNLOAD="$CFG_DOWNLOAD"; LOG="$CFG_LOG"; LOGFILE="$CFG_LOGFILE"; VMID="$CFG_VMID"
YES="$CFG_YES"; CPU_MODEL=""; HOST_SOCKET=""; KSRC="$CFG_KSRC"; KVM_BUILD="$CFG_KVM_BUILD"

usage(){
  cat <<'EOF'
Usage: bash realpc-setup.sh [options]

Options:
  --mode M          check|normal|strong|update|configvm|rollback
  --release R       latest or an exact release tag (default: latest)
  --dir D           Work directory (default: /root/realpc)
  --download 0|1    Download release assets or use existing files
  --log LEVEL       none|normal|debug
  --logfile PATH    Log file path
  --vmid N          VM ID for configvm
  --socket NAME     Physical host socket override for configvm (for OEM DMI strings)
  --cpu-model NAME  Override the CPU model written by configvm
  --kvm-prebuilt    Use the release kvm.ko for the exact running kernel (default)
  --kvm-build       Build kvm.ko on this host instead of using a prebuilt module
  --ksrc PATH       Kernel source tree matching the running kernel; implies --kvm-build
  --yes, -y         Skip confirmation prompts
  -h, --help        Show this help

Recommended first installation:
  bash realpc-setup.sh --mode strong --yes
  bash realpc-setup.sh --mode configvm --vmid 100 --yes

Later updates (the recorded normal/strong mode is preserved):
  bash realpc-setup.sh --mode update --yes

Update never runs configvm and never rewrites a VM args line. A strong update
installs kvm.ko when the release or running kernel changes. It uses a prebuilt
module unless --kvm-build is explicit. An existing state file with
INSTALL_MODE=normal or INSTALL_MODE=strong is required.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:?missing value for --mode}"; shift 2 ;;
    --release) RELEASE="${2:?missing value for --release}"; shift 2 ;;
    --dir) WORKDIR="${2:?missing value for --dir}"; shift 2 ;;
    --download) DOWNLOAD="${2:?missing value for --download}"; shift 2 ;;
    --log) LOG="${2:?missing value for --log}"; shift 2 ;;
    --logfile) LOGFILE="${2:?missing value for --logfile}"; shift 2 ;;
    --vmid) VMID="${2:?missing value for --vmid}"; shift 2 ;;
    --socket) HOST_SOCKET="${2:?missing value for --socket}"; shift 2 ;;
    --cpu-model) CPU_MODEL="${2:?missing value for --cpu-model}"; shift 2 ;;
    --kvm-prebuilt) KVM_BUILD=0; shift ;;
    --kvm-build) KVM_BUILD=1; shift ;;
    --ksrc) KSRC="${2:?missing value for --ksrc}"; KVM_BUILD=1; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORKDIR="$(readlink -m "$WORKDIR")"
[[ "$VMID" =~ ^[0-9]*$ ]] || { echo "--vmid must be a number" >&2; exit 2; }
[[ "$DOWNLOAD" == 0 || "$DOWNLOAD" == 1 ]] || { echo "--download must be 0 or 1" >&2; exit 2; }
[[ "$LOG" == none || "$LOG" == normal || "$LOG" == debug ]] || { echo "--log must be none, normal or debug" >&2; exit 2; }
[[ -z "$LOGFILE" ]] && LOGFILE="$SELF_DIR/$SELF_NAME.log"
TRANSACTION=0
COMPLETED=0
TRANSACTION_PKGS=0
TRANSACTION_MODULE=0
TRANSACTION_VMID=""
RESOLVED_TAG=""
RESOLVED_COMMIT=""
PRESERVED_ASSET_DIR=""
DPKG_INFO_DIR="${DPKG_INFO_DIR:-/var/lib/dpkg/info}"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_rst=$'\e[0m'
_logw(){ [[ "$LOG" == none ]] && return 0
  [[ "$1" == DEBUG && "$LOG" != debug ]] && return 0
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >>"$LOGFILE" 2>/dev/null || true; }
ok(){   echo "${c_grn}[ok]${c_rst}   $*"; _logw INFO "$*"; }
info(){ echo "         $*";                _logw INFO "$*"; }
warn(){ echo "${c_yel}[!]${c_rst}    $*";  _logw WARN "$*"; }
err(){  echo "${c_red}[err]${c_rst}  $*" >&2; _logw ERROR "$*"; }
dbg(){  _logw DEBUG "$*"; }
die(){  err "$*"; exit 1; }
confirm(){ [[ "$YES" == 1 ]] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

if [[ "$LOG" != none ]]; then
  : >>"$LOGFILE" 2>/dev/null || { echo "Cannot write log file $LOGFILE"; LOG=none; }
  _logw INFO "=== start: mode=$MODE release=$RELEASE dir=$WORKDIR download=$DOWNLOAD ==="
  echo "Log: $LOG -> $LOGFILE"
fi
[[ "$LOG" == debug ]] && { exec {XFD}>>"$LOGFILE"; export BASH_XTRACEFD=$XFD; set -x; }

need_root(){ [[ $EUID -eq 0 ]] || die "Run this script as root."; }
cpu_vendor(){ case "$(grep -m1 '^vendor_id' /proc/cpuinfo|awk '{print $3}')" in
  GenuineIntel) echo intel;; AuthenticAMD) echo amd;; *) echo unknown;; esac; }
cpu_model(){ grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//'; }
# kernel/kvm-antidetect.py adds this module marker.
mod_is_ours(){ modinfo kvm 2>/dev/null | grep -q '^realpc:'; }

STATE="$WORKDIR/.realpc-state"
PVE_QEMU_DIR="${REALPC_PVE_QEMU_DIR:-/etc/pve/qemu-server}"
HOST_TOOLS_ARGS_D="${REALPC_HOST_TOOLS_ARGS_D:-/etc/pve-host-tools/args.d}"
HOST_TOOLS_LOCK="${REALPC_HOST_TOOLS_LOCK:-/run/lock/pve-host-tools.lock}"
HOST_TOOLS_LOCK_TIMEOUT="${REALPC_HOST_TOOLS_LOCK_TIMEOUT:-60}"
HOST_TOOLS_LOCK_FD=""
st_set(){ mkdir -p "$WORKDIR" || die "Cannot create $WORKDIR"
          grep -v "^$1=" "$STATE" 2>/dev/null >"$STATE.tmp" || true
          echo "$1=$2" >>"$STATE.tmp" || die "Cannot write $STATE.tmp"
          mv "$STATE.tmp" "$STATE" || die "Cannot update $STATE"; dbg "state $1=$2"; }
st_get(){ [[ -f "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | tail -1; }

acquire_host_tools_lock(){
  command -v flock >/dev/null || die "flock is required for host-tools coordination"
  mkdir -p "$(dirname "$HOST_TOOLS_LOCK")" || die "Cannot create the host-tools lock directory"
  exec {HOST_TOOLS_LOCK_FD}>"$HOST_TOOLS_LOCK" \
    || die "Cannot open host-tools lock: $HOST_TOOLS_LOCK"
  flock -w "$HOST_TOOLS_LOCK_TIMEOUT" "$HOST_TOOLS_LOCK_FD" \
    || die "Timed out after ${HOST_TOOLS_LOCK_TIMEOUT}s waiting for $HOST_TOOLS_LOCK"
}

args_fragments(){
  local id=$1 dir="$HOST_TOOLS_ARGS_D/$1" f fragment
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' f; do
    fragment="$(cat "$f")" || die "Cannot read host-tools fragment $f"
    [[ "$fragment" != *$'\n'* && "$fragment" != *$'\r'* ]] \
      || die "Host-tools fragment must contain exactly one args line: $f"
    [[ -n "${fragment// }" ]] && printf ' %s' "$fragment"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.args' -print0 | sort -z)
}

restore_vm_owned_keys(){
  local backup=$1 current=$2 id=$3
  python3 - "$backup" "$current" "$HOST_TOOLS_ARGS_D/$id" <<'PY'
import os
import pathlib
import re
import sys

backup_path, current_path, fragment_dir = map(pathlib.Path, sys.argv[1:])
backup = backup_path.read_text()
current = current_path.read_text()

def main_lines(text):
    lines = text.splitlines(keepends=True)
    end = next((i for i, line in enumerate(lines) if line.startswith("[")), len(lines))
    return lines[:end], lines[end:]

def get(main, key):
    prefix = key + ":"
    return next((line.rstrip("\r\n")[len(prefix):].strip()
                 for line in main if line.startswith(prefix)), None)

def put(main, key, value):
    prefix = key + ":"
    main[:] = [line for line in main if not line.startswith(prefix)]
    if value is not None:
        main.append(f"{key}: {value}\n")

backup_main, _ = main_lines(backup)
current_main, snapshots = main_lines(current)
igd = any(re.match(r"hostpci\d+:", line) and "00:02.0" in line
          for line in current_main)
base = get(backup_main, "args") or ""
base = re.sub(r"(?:^|\s)-set\s+device\.hostpci\d+\."
              r"(?:addr|bus|x-igd-[^\s]+)", "", base).strip()
fragments = []
if fragment_dir.is_dir():
    for path in sorted(fragment_dir.glob("*.args"), key=lambda p: p.name):
        value = path.read_text().strip()
        if value:
            fragments.append(value)
args = " ".join([part for part in [base, *fragments] if part])
put(current_main, "args", args or None)
for key in ("machine", "bios", "localtime", "tablet"):
    put(current_main, key, get(backup_main, key))
if not igd:
    put(current_main, "vga", get(backup_main, "vga"))
result = "".join(current_main + snapshots)
tmp = current_path.with_name(current_path.name + ".realpc-tmp")
tmp.write_text(result)
os.chmod(tmp, current_path.stat().st_mode)
os.replace(tmp, current_path)
PY
}


package_database_healthy(){
  local output
  if ! output="$(dpkg --audit 2>&1)"; then
    printf '%s\n' "$output" >&2
    err "dpkg --audit failed"
    return 1
  fi
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" >&2
    err "dpkg reports an unfinished or unhealthy package state"
    return 1
  fi
  if ! output="$(apt-get check 2>&1)"; then
    printf '%s\n' "$output" >&2
    err "apt-get check reports broken dependencies"
    return 1
  fi
  return 0
}

restore_package(){
  local pkg=$1 version hold backup actual failed=0
  version="$(st_get "OLD_${pkg}_VERSION")"; hold="$(st_get "OLD_${pkg}_HOLD")"
  backup="$(st_get "OLD_${pkg}_DEB")"
  # Only the exact archived package is eligible. A stock package with the same
  # version is not a safe substitute for a previously installed custom build.
  if [[ -n "$backup" && ! -f "$backup" ]]; then
    err "Package backup is missing: $backup"; backup=""
  fi
  if [[ -n "$backup" && -n "$version" ]]; then
    actual="$(dpkg-deb -f "$backup" Package 2>/dev/null)" || actual=""
    if [[ "$actual" != "$pkg" ]]; then
      err "Package backup has the wrong package name: $backup"; failed=1
    else
      actual="$(dpkg-deb -f "$backup" Version 2>/dev/null)" || actual=""
      if [[ "$actual" != "$version" ]]; then
        err "Package backup has the wrong version: $backup"; failed=1
      else
        # dpkg reinstalls same-version custom packages and ignores APT holds.
        # It never resolves dependencies by upgrading unrelated packages.
        dpkg -i "$backup" || failed=1
      fi
    fi
  else
    err "No exact backup of $pkg=$version; leaving the current package unchanged."
    failed=1
  fi
  if [[ "$hold" == 1 ]]; then apt-mark hold "$pkg" >/dev/null || failed=1
  else apt-mark unhold "$pkg" >/dev/null 2>&1 || failed=1; fi
  return "$failed"
}

rollback(){
  local auto=${1:-0} failed=0
  warn "Rolling back changes..."
  # Automatic rollback only touches changes started by this operation.
  # State from an earlier successful installation is not replayed.
  if [[ "$auto" != 1 || "$TRANSACTION_MODULE" == 1 ]]; then
    local mb mp; mb="$(st_get MODULE_BACKUP)"; mp="$(st_get MODULE_PATH)"
    if [[ -n "$mb" && -f "$mb" && -n "$mp" ]]; then
      local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}')"
      if [[ -z "$run" ]]; then
        rmmod kvm_intel 2>/dev/null||true; rmmod kvm_amd 2>/dev/null||true; rmmod kvm 2>/dev/null||true
        if cp -f "$mb" "$mp" && depmod "$(uname -r)" \
          && update-initramfs -u -k "$(uname -r)" && modprobe "kvm_$(cpu_vendor)"; then
          ok "Restored kvm.ko and initramfs from $mb"
        else err "Could not restore kvm.ko. Restore $mb to $mp manually."; failed=1; fi
      else err "VMs are running; module not restored. Stop them and rerun rollback."; failed=1; fi
    fi
  fi
  local restore_pkgs=0
  if [[ "$auto" == 1 ]]; then
    [[ "$TRANSACTION_PKGS" == 1 ]] && restore_pkgs=1
  elif [[ "$(st_get PKGS)" == "1" ]]; then
    restore_pkgs=1
  fi
  if [[ "$restore_pkgs" == 1 ]]; then
    if [[ "$auto" == 1 ]] || confirm "Restore the original QEMU/OVMF packages from backups?"; then
      restore_package pve-qemu-kvm || failed=1
      restore_package pve-edk2-firmware-ovmf || failed=1
      package_database_healthy || { err "Package database remains unhealthy after rollback"; failed=1; }
      [[ "$failed" == 0 ]] && st_set PKGS 0
    fi
  fi
  local ids id cb cf
  if [[ "$auto" == 1 ]]; then ids="$TRANSACTION_VMID"; else ids="$(st_get CONF_VMS)"; fi
  for id in $ids; do
    cb="$(st_get "CONF_BAK_$id")"; cf="$(st_get "CONF_PATH_$id")"
    if [[ -n "$cb" && -f "$cb" && -n "$cf" ]]; then
      local recorded_sha current_sha
      recorded_sha="$(st_get "CONF_SHA_$id")"
      current_sha="$(sha256sum "$cf" 2>/dev/null | awk '{print $1}')"
      if [[ "$auto" == 1 || -z "$recorded_sha" || "$recorded_sha" == "$current_sha" ]]; then
        cp -f "$cb" "$cf" && ok "Restored VM $id config"           || { err "Could not restore $cf"; failed=1; }
      else
        restore_vm_owned_keys "$cb" "$cf" "$id"           && ok "Restored only realpc-owned keys for VM $id; other tool changes preserved"           || { err "Could not restore realpc-owned keys in $cf"; failed=1; }
      fi
      [[ "$failed" == 0 ]] && st_set "CONF_SHA_$id" ""
    fi
  done
  # Compatibility with old installer state, for explicit manual rollback only.
  if [[ "$auto" != 1 ]]; then
    cb="$(st_get CONF_BAK)"; cf="$(st_get CONF_PATH)"
    if [[ -n "$cb" && -f "$cb" && -n "$cf" ]]; then cp -f "$cb" "$cf" || failed=1; fi
    if [[ "$failed" == 0 ]]; then
      # The previous installed release/mode cannot be reconstructed safely.
      st_set INSTALL_MODE unknown; st_set RELEASE_TAG ""; st_set SOURCE_COMMIT ""; st_set KERNEL_RELEASE ""
    fi
  fi
  if [[ "$failed" == 0 ]]; then ok "Rollback completed successfully."; else err "Rollback completed WITH ERRORS."; fi
  return "$failed"
}

transaction_begin(){
  TRANSACTION=1; COMPLETED=0; TRANSACTION_PKGS=0; TRANSACTION_MODULE=0; TRANSACTION_VMID=""
  trap on_exit EXIT
}
transaction_end(){ COMPLETED=1; TRANSACTION=0; trap - EXIT; }
on_exit(){
  local rc=$?; trap - EXIT
  if [[ "$TRANSACTION" == 1 && "$COMPLETED" == 0 ]]; then
    err "Operation incomplete (exit $rc); starting automatic rollback."
    rollback 1 || true
  fi
  exit "$rc"
}

# Download and verify required files from exactly one release.
dl(){
  local tmp="$2.part"; rm -f "$tmp"; info "Downloading $(basename "$2")"
  if curl -fSL --retry 3 -o "$tmp" "$1" || wget -O "$tmp" "$1"; then
    mv "$tmp" "$2"
  else rm -f "$tmp"; die "Download failed: $1"; fi
}
pick(){ echo "$1" | grep -E "$2" | head -1; }

verify_assets(){
  local dir=$1; shift
  python3 - "$dir" "$@" <<'PY'
import hashlib, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
required = sys.argv[2:]
manifest = {}
try:
    lines = (root / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
except OSError as exc:
    raise SystemExit(f"SHA256SUMS is required: {exc}")
for line in lines:
    match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
    if match:
        manifest[pathlib.PurePath(match[2]).name] = match[1].lower()
for name in required:
    expected = manifest.get(name)
    if not expected:
        raise SystemExit(f"SHA256SUMS does not contain required file: {name}")
    path = root / name
    try:
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as exc:
        raise SystemExit(str(exc))
    if actual != expected:
        raise SystemExit(f"SHA256 MISMATCH: {name}")
print(f"SHA-256 verified for {len(required)} required files")
PY
}

preserve_existing_packages(){
  local root="$WORKDIR/.backup/previous-downloads" f
  mkdir -p "$root" || die "Cannot create $root"
  PRESERVED_ASSET_DIR=$(mktemp -d "$root/assets.XXXXXX") \
    || die "Cannot preserve the previous package downloads"
  for f in "$WORKDIR"/pve-qemu-kvm_*_amd64.deb \
           "$WORKDIR"/pve-edk2-firmware-ovmf_*_all.deb; do
    [[ -f "$f" ]] || continue
    cp -a "$f" "$PRESERVED_ASSET_DIR/" || die "Could not preserve $f for rollback"
  done
}

prebuilt_kvm_asset(){ printf 'kvm-%s.ko' "$1"; }
prebuilt_kvm_info_asset(){ printf 'kvm-%s.modinfo' "$1"; }

fetch_assets(){
  local asset_mode=${1:-$MODE}
  mkdir -p "$WORKDIR" || die "Cannot create $WORKDIR"
  command -v python3 >/dev/null || die "python3 is required"
  if [[ "$DOWNLOAD" == 1 ]]; then
    command -v curl >/dev/null || die "curl is required for the GitHub API"
    [[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid release tag: $RELEASE"
    local api="https://api.github.com/repos/$REPO/releases/latest"
    [[ "$RELEASE" != latest ]] && api="https://api.github.com/repos/$REPO/releases/tags/$RELEASE"
    local json; json=$(mktemp)
    curl -fsSL --retry 3 -o "$json" "$api" || die "Could not fetch release metadata for $RELEASE"
    RESOLVED_TAG=$(python3 - "$json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    obj = json.load(handle)
print(obj["tag_name"])
PY
) || { rm -f "$json"; die "Could not parse the release tag"; }
    local urls; urls=$(python3 - "$json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    obj = json.load(handle)
for asset in obj.get("assets", []):
    print(asset["browser_download_url"])
PY
) || { rm -f "$json"; die "Could not parse the release asset list"; }
    rm -f "$json"; [[ -n "$urls" ]] || die "Release $RESOLVED_TAG has no assets"
    info "Release: $RESOLVED_TAG (all assets come from this release)"
    local deb ov sums source_url a u
    deb="$(pick "$urls" '/pve-qemu-kvm_[^/]*_amd64\.deb$')"
    ov="$(pick "$urls" '/pve-edk2-firmware-ovmf_[^/]*_all\.deb$')"
    sums="$(pick "$urls" '/SHA256SUMS$')"
    source_url="$(pick "$urls" "/$CFG_SOURCE_ASSET\$")"
    [[ -n "$deb" && -n "$ov" && -n "$sums" && -n "$source_url" ]] \
      || die "Release is missing QEMU, OVMF, SOURCE-COMMIT or SHA256SUMS"
    preserve_existing_packages
    rm -f "$WORKDIR"/pve-qemu-kvm_*_amd64.deb "$WORKDIR"/pve-edk2-firmware-ovmf_*_all.deb \
      "$WORKDIR/SHA256SUMS" "$WORKDIR/$CFG_KERNEL_ASSET" "$WORKDIR/$CFG_VM_TOOLS_ASSET" "$WORKDIR/$CFG_SOURCE_ASSET" \
      "${CFG_AML[@]/#/$WORKDIR/}"
    dl "$sums" "$WORKDIR/SHA256SUMS"
    dl "$deb" "$WORKDIR/$(basename "$deb")"; dl "$ov" "$WORKDIR/$(basename "$ov")"
    dl "$source_url" "$WORKDIR/$CFG_SOURCE_ASSET"
    u="$(pick "$urls" "/$CFG_VM_TOOLS_ASSET\$")"
    [[ -n "$u" ]] || die "Release is missing $CFG_VM_TOOLS_ASSET"
    dl "$u" "$WORKDIR/$CFG_VM_TOOLS_ASSET"
    for a in "${CFG_AML[@]}"; do
      u="$(pick "$urls" "/$a\$")"; [[ -n "$u" ]] || die "Release is missing $a"
      dl "$u" "$WORKDIR/$a"
    done
    if [[ "$asset_mode" == strong ]]; then
      u="$(pick "$urls" "/$CFG_KERNEL_ASSET\$")"
      [[ -n "$u" ]] || die "Release is missing $CFG_KERNEL_ASSET"
      dl "$u" "$WORKDIR/$CFG_KERNEL_ASSET"
      if [[ "$KVM_BUILD" == 0 ]]; then
        local rel kvm_asset kvm_info info_url
        rel="$(uname -r)"; kvm_asset="$(prebuilt_kvm_asset "$rel")"
        kvm_info="$(prebuilt_kvm_info_asset "$rel")"
        rm -f "$WORKDIR/$kvm_asset" "$WORKDIR/$kvm_info"
        u="$(pick "$urls" "/${kvm_asset//./\\.}\$")"
        info_url="$(pick "$urls" "/${kvm_info//./\\.}\$")"
        if [[ -n "$u" && -n "$info_url" ]]; then
          dl "$u" "$WORKDIR/$kvm_asset"; dl "$info_url" "$WORKDIR/$kvm_info"
        elif [[ -n "$u" || -n "$info_url" ]]; then
          die "Release has an incomplete prebuilt KVM asset pair for $rel"
        fi
      fi
    fi
  else
    info "download=0: verifying existing files in $WORKDIR"
    if [[ "$RELEASE" == latest ]]; then RESOLVED_TAG="local"; else RESOLVED_TAG="$RELEASE"; fi
  fi

  local q o required
  q="$(find_one 'pve-qemu-kvm_*_amd64.deb')"; o="$(find_one 'pve-edk2-firmware-ovmf_*_all.deb')"
  required=("$(basename "$q")" "$(basename "$o")" "$CFG_SOURCE_ASSET" "$CFG_VM_TOOLS_ASSET" "${CFG_AML[@]}")
  [[ "$asset_mode" == strong ]] && required+=("$CFG_KERNEL_ASSET")
  verify_assets "$WORKDIR" "${required[@]}" || die "Asset verification failed; no installation performed"
  if [[ "$asset_mode" == strong && "$KVM_BUILD" == 0 ]]; then
    local rel kvm_asset kvm_info
    rel="$(uname -r)"; kvm_asset="$(prebuilt_kvm_asset "$rel")"
    kvm_info="$(prebuilt_kvm_info_asset "$rel")"
    if [[ -f "$WORKDIR/$kvm_asset" || -f "$WORKDIR/$kvm_info" ]]; then
      verify_assets "$WORKDIR" "$kvm_asset" "$kvm_info" \
        || die "Prebuilt KVM assets failed SHA-256 verification"
    fi
  fi
  RESOLVED_COMMIT="$(tr -d '[:space:]' < "$WORKDIR/$CFG_SOURCE_ASSET")"
  [[ "$RESOLVED_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || die "$CFG_SOURCE_ASSET does not contain a full commit SHA"
  ok "All required files passed SHA-256 verification"
}

find_one(){ local m=( "$WORKDIR"/$1 ); [[ -e "${m[0]}" ]] || die "No file matching $1 in $WORKDIR"
  [[ ${#m[@]} -eq 1 ]] || die "Multiple files match $1; keep only one: ${m[*]}"; echo "${m[0]}"; }
# Accept a rollback package only when its payload matches the md5sums recorded
# by dpkg for the installed package. The same version can also be a stock build,
# so a version-only check is not sufficient after a custom realpc installation.
package_backup_matches(){
  local pkg=$1 deb=$2 version=$3 actual root expected rel path entries=0
  [[ -f "$deb" && -f "$DPKG_INFO_DIR/$pkg.md5sums" ]] || return 1
  actual=$(dpkg-deb -f "$deb" Package 2>/dev/null) || return 1
  [[ "$actual" == "$pkg" ]] || return 1
  actual=$(dpkg-deb -f "$deb" Version 2>/dev/null) || return 1
  [[ "$actual" == "$version" ]] || return 1
  mkdir -p "$WORKDIR/.backup/verify" || return 2
  root=$(mktemp -d "$WORKDIR/.backup/verify/${pkg}.XXXXXX") || return 2
  if ! dpkg-deb -x "$deb" "$root" >/dev/null 2>&1; then
    rm -rf "$root"; return 1
  fi
  while read -r expected rel; do
    [[ -z "$expected" && -z "$rel" ]] && continue
    entries=$((entries + 1)); rel=${rel#./}; path="$root/$rel"
    if [[ ! "$expected" =~ ^[0-9a-fA-F]{32}$ || -z "$rel" || "$rel" == /* \
          || "$rel" == .. || "$rel" == ../* || "$rel" == */../* || "$rel" == */.. \
          || ! -f "$path" || -L "$path" ]]; then
      rm -rf "$root"; return 1
    fi
    actual=$(md5sum "$path" | awk '{print $1}')
    if [[ "$actual" != "${expected,,}" ]]; then
      rm -rf "$root"; return 1
    fi
  done < "$DPKG_INFO_DIR/$pkg.md5sums"
  rm -rf "$root"
  (( entries > 0 )) || return 1
  return 0
}

find_verified_package_backup(){
  local pkg=$1 version=$2 old_commit journal_backup candidate rc
  local candidates=()
  journal_backup="$(st_get "OLD_${pkg}_DEB")"
  [[ -n "$journal_backup" ]] && candidates+=("$journal_backup")
  old_commit="$(st_get SOURCE_COMMIT)"
  [[ -n "$old_commit" ]] \
    && candidates+=("$WORKDIR/.backup/installed/$old_commit/${pkg}_"*.deb)
  [[ -n "$PRESERVED_ASSET_DIR" ]] \
    && candidates+=("$PRESERVED_ASSET_DIR/${pkg}_"*.deb)
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    if package_backup_matches "$pkg" "$candidate" "$version"; then
      printf '%s\n' "$candidate"; return 0
    else
      rc=$?; [[ "$rc" == 1 ]] || return "$rc"
    fi
  done
  return 1
}

backup_packages(){
  local dir="$WORKDIR/.backup/packages" pkg version deb pkgdir candidate rc
  local -A versions holds backups
  mkdir -p "$dir" || die "Cannot create $dir"
  # Prepare and verify both packages before replacing any rollback journal fields.
  for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
    version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)" \
      || die "$pkg is not installed; its original version is unknown"
    versions[$pkg]="$version"
    if apt-mark showhold | grep -qx "$pkg"; then holds[$pkg]=1; else holds[$pkg]=0; fi
    pkgdir=$(mktemp -d "$dir/${pkg}.XXXXXX") || die "Cannot create a package backup directory"
    info "Backing up original $pkg=$version"
    if candidate="$(find_verified_package_backup "$pkg" "$version")"; then
      :
    else
      rc=$?; [[ "$rc" == 1 ]] || die "Could not verify a saved package backup for $pkg"
      candidate=""
    fi
    if [[ -n "$candidate" ]]; then
      cp -a "$candidate" "$pkgdir/" || die "Could not copy the verified backup for $pkg"
    else
      (cd "$pkgdir" && apt-get download "$pkg=$version") \
        || die "Could not download backup $pkg=$version; no package changes were made"
    fi
    deb=$(find "$pkgdir" -maxdepth 1 -type f -name "${pkg}_*.deb" | head -1)
    [[ -n "$deb" ]] || die "No .deb backup was created for $pkg"
    package_backup_matches "$pkg" "$deb" "$version" \
      || die "Backup $pkg=$version does not match the installed custom package; no package changes were made"
    backups[$pkg]="$deb"
  done
  for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
    st_set "OLD_${pkg}_VERSION" "${versions[$pkg]}"
    st_set "OLD_${pkg}_HOLD" "${holds[$pkg]}"
    st_set "OLD_${pkg}_DEB" "${backups[$pkg]}"
  done
}

record_installed_packages(){
  local q=$1 o=$2 pkg deb version dir
  [[ "$RESOLVED_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] \
    || die "Cannot archive installed packages without a source commit"
  dir="$WORKDIR/.backup/installed/$RESOLVED_COMMIT"
  mkdir -p "$dir" || die "Cannot create the installed package archive"
  for pkg in pve-qemu-kvm pve-edk2-firmware-ovmf; do
    [[ "$pkg" == pve-qemu-kvm ]] && deb="$q" || deb="$o"
    version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)" \
      || die "Cannot verify the installed $pkg package"
    package_backup_matches "$pkg" "$deb" "$version" \
      || die "Installed $pkg does not match the verified release package; changes will be rolled back"
    cp -a "$deb" "$dir/" || die "Could not archive the installed $deb"
  done
}

install_userspace(){
  local q o; q="$(find_one 'pve-qemu-kvm_*_amd64.deb')"; o="$(find_one 'pve-edk2-firmware-ovmf_*_all.deb')"
  echo "QEMU: $(basename "$q")"; echo "OVMF: $(basename "$o")"
  if ! confirm "Install these packages?"; then info "Canceled by user"; return 2; fi
  info "Checking package database before installation"
  package_database_healthy \
    || die "Package database is unhealthy; no package changes were made"
  backup_packages
  # Record rollback scope before the first package database change.
  st_set PKGS 1; TRANSACTION_PKGS=1
  info "Installing only the two verified release packages with dpkg"
  # APT may skip a same-version custom QEMU, reject a held/downgraded OVMF,
  # or upgrade unrelated dependencies. dpkg installs exactly these two files.
  dpkg -i "$q" "$o" \
    || die "Package installation failed; changes will be rolled back"
  package_database_healthy \
    || die "Package database is unhealthy after installation; changes will be rolled back"
  apt-mark hold pve-qemu-kvm pve-edk2-firmware-ovmf || die "Could not set apt hold"
  record_installed_packages "$q" "$o"
  ok "Packages installed and held; exact release packages archived for future rollback"
}

record_install_state(){
  local mode=$1 kernel=""
  [[ "$mode" == normal || "$mode" == strong ]] || die "Internal error: invalid install state mode $mode"
  [[ -n "$RESOLVED_TAG" && -n "$RESOLVED_COMMIT" ]] || die "Internal error: unresolved release provenance"
  [[ "$mode" == strong ]] && kernel="$(uname -r)"
  mkdir -p "$WORKDIR" || die "Cannot create $WORKDIR"
  # Commit the four related fields with one rename. A write failure cannot leave
  # a new release tag next to an old mode/kernel record after rollback.
  {
    grep -v -E '^(INSTALL_MODE|RELEASE_TAG|SOURCE_COMMIT|KERNEL_RELEASE|CONTRACT_VERSION)=' "$STATE" 2>/dev/null || true
    printf 'INSTALL_MODE=%s\nRELEASE_TAG=%s\nSOURCE_COMMIT=%s\nKERNEL_RELEASE=%s\nCONTRACT_VERSION=1\n' \
      "$mode" "$RESOLVED_TAG" "$RESOLVED_COMMIT" "$kernel"
  } >"$STATE.tmp" || die "Cannot write $STATE.tmp"
  mv "$STATE.tmp" "$STATE" || die "Cannot update $STATE"
  dbg "state INSTALL_MODE=$mode RELEASE_TAG=$RESOLVED_TAG SOURCE_COMMIT=$RESOLVED_COMMIT KERNEL_RELEASE=$kernel"
}

strong_preflight(){
  need_root
  local vend; vend="$(cpu_vendor)"; [[ "$vend" == unknown ]] && die "Unknown CPU vendor"
  ok "CPU: $vend"
  [[ "$vend" == amd ]] && warn "host-sensors is Intel-only; KVM hypercall changes also apply on AMD"
  command -v mokutil >/dev/null || die "mokutil is required to verify that Secure Boot is disabled"
  local sb; sb="$(mokutil --sb-state 2>/dev/null)" \
    || die "Cannot determine Secure Boot state; disable it in firmware before continuing"
  grep -qi disabled <<<"$sb" || die "Secure Boot is not disabled ($sb); an unsigned module cannot load"
  command -v qm >/dev/null || die "qm was not found; run strong mode on a Proxmox VE host"
  local qm_list run
  qm_list="$(qm list 2>/dev/null)" || die "qm list failed; cannot verify that all VMs are stopped"
  run="$(awk '$3=="running"{print $1}' <<<"$qm_list" | tr '\n' ' ')"
  [[ -n "$run" ]] && die "Stop VMs ($run) and retry; kvm.ko is shared by the whole host"
  mkdir -p "$WORKDIR" || die "Cannot create $WORKDIR"
  if [[ "$KVM_BUILD" == 1 ]]; then
    local free; free="$(df -Pk "$WORKDIR" | awk 'NR==2 {print $4}')"
    [[ "$free" =~ ^[0-9]+$ ]] || die "Cannot determine free space in $WORKDIR"
    (( free >= CFG_MIN_FREE_MB * 1024 )) \
      || die "Strong build needs at least ${CFG_MIN_FREE_MB} MiB free in $WORKDIR"
  fi
}

backup_current_module(){
  local rel=${1:-$(uname -r)} cur backup_dir backup
  cur="$(modinfo -n kvm 2>/dev/null)" || die "Cannot resolve the active kvm.ko with modinfo"
  [[ -f "$cur" ]] || die "Active kvm.ko does not exist: $cur"
  backup_dir="$WORKDIR/.backup/modules"; mkdir -p "$backup_dir" || die "Cannot create $backup_dir"
  backup=$(mktemp "$backup_dir/kvm.ko-$rel.XXXXXX") || die "Cannot create a module backup"
  cp -a "$cur" "$backup" || die "Could not back up $cur"
  st_set MODULE_PATH "$cur"; st_set MODULE_BACKUP "$backup"; TRANSACTION_MODULE=1
}

prepare_kernel_tools(){
  mkdir -p "$WORKDIR/kernel" || die "Cannot create $WORKDIR/kernel"
  # This archive is covered by SHA256SUMS. No root code is fetched from main.
  tar --no-same-owner -xzf "$WORKDIR/$CFG_KERNEL_ASSET" -C "$WORKDIR/kernel" \
    || die "Could not unpack verified $CFG_KERNEL_ASSET"
  local f
  for f in kvm-antidetect.py build-kvm.sh install-kvm.sh; do
    [[ -f "$WORKDIR/kernel/$f" ]] || die "Kernel archive is missing $f"
  done
}

module_metadata_value(){ sed -n "s/^$1=//p" "$2" | tail -1; }

verify_prebuilt_module(){
  local mod=$1 metadata=$2 rel current current_vm new_vm config symvers
  local expected actual metadata_vm
  rel="$(uname -r)"
  [[ -s "$mod" && -s "$metadata" ]] || die "Prebuilt KVM module or metadata is missing for $rel"
  new_vm="$(modinfo -F vermagic "$mod" 2>/dev/null)" \
    || die "Cannot read prebuilt module vermagic"
  [[ "$new_vm" == "$rel "* ]] \
    || die "Prebuilt KVM vermagic '$new_vm' does not match running kernel $rel"
  current="$(modinfo -n kvm 2>/dev/null)" || die "Cannot resolve the active kvm.ko with modinfo"
  current_vm="$(modinfo -F vermagic "$current" 2>/dev/null)" \
    || die "Cannot read the active kvm.ko vermagic"
  [[ "$new_vm" == "$current_vm" ]] \
    || die "Prebuilt KVM vermagic differs from the installed kvm.ko"
  modinfo "$mod" 2>/dev/null | grep -q '^realpc:' \
    || die "Prebuilt module has no realpc marker; refusing installation"

  config="${REALPC_KERNEL_CONFIG:-/boot/config-$rel}"
  symvers="${REALPC_MODULE_SYMVERS:-/lib/modules/$rel/build/Module.symvers}"
  [[ -s "$config" ]] || die "Running-kernel config is missing: $config"
  [[ -s "$symvers" ]] || die "Running-kernel Module.symvers is missing: $symvers"
  for pair in "REALPC_CONFIG_SHA256:$config" "REALPC_MODULE_SYMVERS_SHA256:$symvers"; do
    local field=${pair%%:*} path=${pair#*:}
    expected="$(module_metadata_value "$field" "$metadata")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "Prebuilt metadata lacks a valid $field"
    actual="$(sha256sum "$path" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] \
      || die "Prebuilt KVM $field does not match the running kernel; use --kvm-build"
  done
  metadata_vm="$(module_metadata_value REALPC_VERMAGIC "$metadata")"
  [[ "$metadata_vm" == "$new_vm" ]] || die "Prebuilt KVM metadata vermagic mismatch"
  expected="$(module_metadata_value REALPC_MODULE_SHA256 "$metadata")"
  actual="$(sha256sum "$mod" | awk '{print $1}')"
  [[ -n "$expected" && "$actual" == "$expected" ]] || die "Prebuilt KVM metadata module hash mismatch"
  ok "Prebuilt KVM matches kernel $rel, vermagic, config and Module.symvers"
}

verify_prebuilt_assets(){
  local rel kvm_asset kvm_info
  rel="$(uname -r)"; kvm_asset="$(prebuilt_kvm_asset "$rel")"
  kvm_info="$(prebuilt_kvm_info_asset "$rel")"
  [[ -f "$WORKDIR/$kvm_asset" && -f "$WORKDIR/$kvm_info" ]] \
    || die "Release $RESOLVED_TAG has no prebuilt KVM for $rel; rerun with --kvm-build"
  verify_assets "$WORKDIR" "$kvm_asset" "$kvm_info" \
    || die "Prebuilt KVM assets failed SHA-256 verification"
  verify_prebuilt_module "$WORKDIR/$kvm_asset" "$WORKDIR/$kvm_info"
}

install_module_file(){
  local rel=$1 built=$2
  [[ -f "$built" ]] || die "Module not found: $built"
  modinfo "$built" 2>/dev/null | grep -q '^realpc:' \
    || die "Module has no realpc marker; refusing installation"
  # Save the exact module active before this operation. On repeat strong updates
  # this is the previous custom module, not an older stock-only backup.
  backup_current_module "$rel"
  bash "$WORKDIR/kernel/install-kvm.sh" --yes || die "kvm.ko installation failed; changes will be rolled back"
  [[ -d /sys/module/kvm ]] || die "KVM is not loaded after installation; changes will be rolled back"
}

build_install_module(){
  warn "Building the open kvm.ko from kernel sources on this host is EXPERIMENTAL."
  warn "It replaces a host-wide kernel module. Keep a way to boot a previous kernel."
  prepare_kernel_tools
  info "Building the module; this can take several minutes and requires matching kernel sources..."
  KSRC="${KSRC:-}" bash "$WORKDIR/kernel/build-kvm.sh" \
    || die "kvm.ko build failed (see above; deb-src or --ksrc PATH may be required)"
  local rel built; rel="$(uname -r)"; built="$WORKDIR/kernel/out/kvm.ko"
  ok "Built: $built (vermagic $(modinfo -F vermagic "$built"))"
  install_module_file "$rel" "$built"
}

prebuilt_install_module(){
  local rel kvm_asset kvm_info built
  rel="$(uname -r)"; kvm_asset="$(prebuilt_kvm_asset "$rel")"
  kvm_info="$(prebuilt_kvm_info_asset "$rel")"
  verify_prebuilt_assets
  warn "Installing the verified prebuilt kvm.ko is EXPERIMENTAL and affects the whole host."
  prepare_kernel_tools
  mkdir -p "$WORKDIR/kernel/out" || die "Cannot create $WORKDIR/kernel/out"
  built="$WORKDIR/kernel/out/kvm.ko"
  cp "$WORKDIR/$kvm_asset" "$built" || die "Could not stage the prebuilt kvm.ko"
  ok "Using prebuilt: $kvm_asset (vermagic $(modinfo -F vermagic "$built"))"
  install_module_file "$rel" "$built"
}

install_selected_module(){
  if [[ "$KVM_BUILD" == 1 ]]; then build_install_module; else prebuilt_install_module; fi
}

# CHECK
do_check(){
  echo "--- Status ------------------------------------------------"
  command -v pveversion >/dev/null && echo "PVE:          $(pveversion|head -1)" || warn "pveversion not found; is this a Proxmox node?"
  echo "Kernel:       $(uname -r)"
  echo "CPU:          $(cpu_vendor) / $(cpu_model)"
  echo "QEMU:         $(dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pve-qemu-kvm 2>/dev/null||echo missing)"
  echo "OVMF:         $(dpkg-query -W -f='${Version} ${db:Status-Abbrev}' pve-edk2-firmware-ovmf 2>/dev/null||echo missing)   (hi = held)"
  echo "Install mode: $(st_get INSTALL_MODE || true)"
  echo "Release tag:  $(st_get RELEASE_TAG || true)"
  echo "Built kernel: $(st_get KERNEL_RELEASE || true)"
  if dpkg-query -W pve-qemu-kvm >/dev/null 2>&1; then
    qemu-system-x86_64 -machine none -accel kvm -display none -cpu host,help 2>&1 \
      | grep -qiw host-sensors \
      && echo "host-sensors: available in QEMU" \
      || echo "host-sensors: not confirmed (CPU property query failed or stock QEMU)"
  fi
  mokutil --sb-state >/dev/null 2>&1 && echo "Secure Boot:  $(mokutil --sb-state 2>/dev/null)" || echo "Secure Boot:  unknown"
  if mod_is_ours; then ok "The on-disk kvm.ko has the realpc marker"
  else echo "kvm.ko:       stock or no realpc marker on disk"; fi
  [[ -d /sys/module/kvm ]] && echo "KVM:          module loaded" || echo "KVM:          module not loaded"
  local run; run="$(qm list 2>/dev/null|awk '$3=="running"{print $1}'|tr '\n' ' ')"
  [[ -n "$run" ]] && warn "Running VMs: $run"
  echo "-----------------------------------------------------------"
}

# NORMAL: userspace fallback/recovery mode.
install_normal(){ need_root; transaction_begin
  echo "=== NORMAL (QEMU + host-sensors / OVMF / ACPI) ==="; fetch_assets normal
  install_userspace || { local rc=$?; [[ "$rc" == 2 ]] && { transaction_end; return 0; }; exit "$rc"; }
  record_install_state normal
  ok "Normal installation complete. Strong is the recommended primary mode."
  transaction_end
}

# STRONG: userspace plus an open kvm.ko for the exact running kernel.
install_strong(){ need_root
  if [[ "$KVM_BUILD" == 1 ]]; then
    echo "=== STRONG (open kvm.ko built on this host) ==="
  else
    echo "=== STRONG (verified prebuilt kvm.ko) ==="
  fi
  strong_preflight; transaction_begin
  fetch_assets strong
  [[ "$KVM_BUILD" == 1 ]] || verify_prebuilt_assets
  install_userspace || { local rc=$?; [[ "$rc" == 2 ]] && { transaction_end; return 0; }; exit "$rc"; }
  if ! confirm "Install the open kvm.ko?"; then
    record_install_state normal
    ok "Module skipped. The installation is recorded as normal for future updates."
    transaction_end; return 0
  fi
  install_selected_module
  record_install_state strong
  ok "STRONG installation complete. Next: --mode configvm --vmid N"
  transaction_end
}

# UPDATE: preserve the recorded mode and never change VM configurations.
update_install(){ need_root
  echo "=== UPDATE (preserve normal/strong mode and VM configs) ==="
  [[ -f "$STATE" ]] || die "No installation state at $STATE. Run normal or strong once before update."
  local mode old_tag old_kernel current_kernel kernel_only=0
  mode="$(st_get INSTALL_MODE)"
  case "$mode" in
    normal|strong) ;;
    *) die "INSTALL_MODE is missing or ambiguous in $STATE. Run normal or strong explicitly; update will not guess." ;;
  esac
  old_tag="$(st_get RELEASE_TAG)"; old_kernel="$(st_get KERNEL_RELEASE)"; current_kernel="$(uname -r)"
  info "Recorded mode: $mode; release: ${old_tag:-unknown}; kernel: ${old_kernel:-unknown}"
  fetch_assets "$mode"
  if [[ "$old_tag" == "$RESOLVED_TAG" ]]; then
    if [[ "$mode" == normal ]]; then
      ok "Normal mode is already at $RESOLVED_TAG; no changes needed."
      return 0
    fi
    if [[ "$old_kernel" == "$current_kernel" ]]; then
      ok "Strong mode is already at $RESOLVED_TAG on kernel $current_kernel; no changes needed."
      return 0
    fi
    kernel_only=1
    info "Release is unchanged, but the running kernel changed; installing the strong module only."
  fi

  if [[ "$mode" == strong ]]; then
    [[ "$KVM_BUILD" == 1 ]] || verify_prebuilt_assets
    strong_preflight
    confirm "Update strong mode and install kvm.ko for $current_kernel?" \
      || { info "Update canceled; no system changes made."; return 0; }
  fi
  transaction_begin
  if [[ "$kernel_only" == 0 ]]; then
    install_userspace || { local rc=$?; [[ "$rc" == 2 ]] && { transaction_end; return 0; }; exit "$rc"; }
  fi
  [[ "$mode" == strong ]] && install_selected_module
  record_install_state "$mode"
  transaction_end
  ok "Update complete: mode=$mode release=$RESOLVED_TAG kernel=${current_kernel}. VM configs were not changed."
}

generate_host_profile(){
  local tools_dir=$1 profile_dir=$2 id=$3
  local socket_opts=()
  [[ -n "$HOST_SOCKET" ]] && socket_opts=(--socket "$HOST_SOCKET")
  python3 "$tools_dir/gen-profile.py" --cpu-source host --host-vendor "$(cpu_vendor)" \
    --vmid "$id" --seed "$id" --out "$profile_dir" "${socket_opts[@]}" >/dev/null
}

# CONFIGVM: a separate explicit operation; update never calls this function.
configvm(){ need_root
  [[ -n "$VMID" ]] || die "Specify --vmid N"
  local conf="$PVE_QEMU_DIR/${VMID}.conf"; [[ -f "$conf" ]] || die "Missing $conf (create the VM first)"
  local a
  for a in "${CFG_AML[@]}"; do [[ -f "$WORKDIR/$a" ]] || die "Missing $WORKDIR/$a; run normal/strong/update first"; done
  verify_assets "$WORKDIR" "$CFG_VM_TOOLS_ASSET" "${CFG_AML[@]}" || die "VM tools or ACPI files failed SHA-256 verification"
  [[ "$(qm status "$VMID" 2>/dev/null)" == *stopped* ]] || die "Stop VM $VMID before configvm"
  if grep -q '^args:' "$conf" && [[ "$YES" != 1 ]]; then
    confirm "Rebuild the main args line and preserve host-tools fragments?" || { info "Canceled"; return 0; }
  fi
  transaction_begin; TRANSACTION_VMID="$VMID"
  mkdir -p "$WORKDIR/.bak" || die "Cannot create the backup directory"
  local bak; bak=$(mktemp "$WORKDIR/.bak/${VMID}.conf.XXXXXX") || die "Cannot create a config backup"
  cp -a "$conf" "$bak" || die "Could not back up $conf"
  local ids; ids="$(st_get CONF_VMS)"
  [[ " $ids " == *" $VMID "* ]] || st_set CONF_VMS "$ids $VMID"
  st_set "CONF_PATH_$VMID" "$conf"; st_set "CONF_BAK_$VMID" "$bak"; ok "VM config backup: $bak"
  local tools_dir="$WORKDIR/vm-tools" profile_dir="$WORKDIR/profiles/$VMID"
  rm -rf "$tools_dir"; mkdir -p "$tools_dir" "$profile_dir"
  tar --no-same-owner -xzf "$WORKDIR/$CFG_VM_TOOLS_ASSET" -C "$tools_dir" \
    || die "Could not unpack verified VM tools"
  if [[ ! -f "$profile_dir/profile.json" ]]; then
    generate_host_profile "$tools_dir" "$profile_dir" "$VMID" \
      || die "Could not generate a host-truth profile; verify the host socket or pass --socket explicitly"
  fi
  python3 - "$profile_dir/profile.json" "$(cpu_model)" <<'PY' \
    || die "Saved profile CPU differs from the current host; remove the VM profile and regenerate it"
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    profile = json.load(f)
assert profile["summary"]["cpu_source"] == "host"
assert profile["summary"]["cpu"] == sys.argv[2]
PY
  info "Rounding file-based disks up to the nearest real SSD size (grow-only, thin-safe)..."
  python3 "$tools_dir/vm-config.py" --config "$conf" --vmid "$VMID" --resize-up \
    || die "Disk resize to a real SKU size failed; no configuration was written"
  info "Disk growth is not undone by rollback (growing a thin disk is safe and reversible only by you)"
  local rendered; rendered=$(mktemp "$WORKDIR/.bak/${VMID}.rendered.XXXXXX")
  python3 "$tools_dir/vm-config.py" --config "$conf" --profile "$profile_dir/profile.json" \
    --acpi-dir "$WORKDIR" --fragment-args "$(args_fragments "$VMID")" --out "$rendered" \
    || die "VM profile validation failed; no configuration was written"
  python3 "$tools_dir/consistency_lint.py" --config "$rendered" --profile "$profile_dir/profile.json" \
    || die "Cross-layer consistency lint failed; no configuration was written"
  cat "$rendered" > "$conf.realpc-tmp" || die "Could not write the temporary VM configuration"
  chmod --reference="$conf" "$conf.realpc-tmp"; mv "$conf.realpc-tmp" "$conf" \
    || die "Could not activate the VM configuration; rollback will be used"
  ok "Applied host-truth profile, per-disk SATA identities and profile MAC to VM $VMID"
  st_set CONTRACT_VERSION 1
  st_set "CONF_SHA_$VMID" "$(sha256sum "$conf" | awk '{print $1}')"
  info "The gateway and bridge can still observe the generated MAC; this is expected network exposure."
  ok "Done. Start the VM and check sensors with HWiNFO/AIDA64."
  transaction_end
}

# Tests source these functions without running host checks or modifications.
[[ "${REALPC_SETUP_SOURCE_ONLY:-0}" == 1 ]] && return 0

do_check; echo
case "$MODE" in
  check) : ;;
  normal|strong|update|configvm|rollback)
    need_root
    acquire_host_tools_lock
    case "$MODE" in
      normal) install_normal ;;
      strong) install_strong ;;
      update) update_install ;;
      configvm) configvm ;;
      rollback) rollback ;;
    esac
    ;;
  *) die "Mode must be check, normal, strong, update, configvm or rollback" ;;
esac
