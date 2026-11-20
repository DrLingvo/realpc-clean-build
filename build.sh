#!/bin/bash
# Clean, source-only rebuild of the pve-emu-realpc packages.
#
# Runs inside a throwaway Debian 13 (trixie) environment that has the official Proxmox
# VE 9 repository configured (see README.md: LXC container on your PVE host, or Docker).
# Inputs: only official sources (git.proxmox.com, pinned by commit; QEMU/edk2 submodules
# and meson subprojects pinned by hash inside those), plus the reviewed text files in
# this kit. No binary from the original author is used.
#
# Output in ./out:
#   pve-qemu-kvm_*.deb, pve-edk2-firmware-ovmf_*.deb (+ aarch64/riscv/legacy debs),
#   ssdt.aml ssdt-battery.aml ssdt-ec.aml hpet.aml,
#   qemu-applied.diff edk2-applied.diff seabios-applied.diff (exactly what was changed),
#   SHA256SUMS
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
set -a; . "$KIT/config.env"; set +a
WORK=${WORK:-$KIT/work}
OUT=$KIT/out
mkdir -p "$WORK" "$OUT"
log() { printf '\n=== %s\n' "$*"; }
# STAGES: any of "qemu edk2 acpi" (default: all)
STAGES=${STAGES:-qemu edk2 acpi}
want() { [[ " $STAGES " == *" $1 "* ]]; }

# ---------------------------------------------------------------- environment checks
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || { echo "Run this in Debian 13 (trixie); found ${PRETTY_NAME:-?}" >&2; exit 1; }
if ! apt-cache policy pve-qemu-kvm 2>/dev/null | grep 'download.proxmox.com' >/dev/null; then
  echo "The Proxmox VE 9 apt repository is not configured (needed for build-deps such as" >&2
  echo "libproxmox-backup-qemu0-dev). See README.md, step 2." >&2; exit 1
fi
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo

log "Installing base tools"
$SUDO apt-get update
$SUDO apt-get install -y --no-install-recommends git ca-certificates devscripts equivs \
  build-essential quilt acpica-tools python3 python-is-python3 meson ninja-build lintian

# clone_pinned <name> <commit>: clone from git.proxmox.com and verify the commit
clone_pinned() {
  local name=$1 commit=$2
  if [ ! -d "$WORK/$name/.git" ]; then git clone "$PVE_GIT/$name.git" "$WORK/$name"; fi
  git -C "$WORK/$name" fetch -q origin
  git -C "$WORK/$name" checkout -q --detach "$commit"
  git -C "$WORK/$name" reset -q --hard "$commit"
  git -C "$WORK/$name" clean -qfdx
  [ "$(git -C "$WORK/$name" rev-parse HEAD)" = "$commit" ] || { echo "commit mismatch for $name" >&2; exit 1; }
  git -C "$WORK/$name" submodule sync -q --recursive
  git -C "$WORK/$name" submodule update -q --init --recursive --force
  git -C "$WORK/$name" submodule foreach -q --recursive 'git reset -q --hard && git clean -qfdx'
}

install_build_deps() {
  ( cd "$1" && $SUDO mk-build-deps --install --remove \
      --tool 'apt-get -y --no-install-recommends' debian/control )
}

if want qemu; then
# ======================================================================== QEMU
log "pve-qemu @ $PVE_QEMU_COMMIT"
clone_pinned pve-qemu "$PVE_QEMU_COMMIT"
install_build_deps "$WORK/pve-qemu"
Q=$WORK/pve-qemu/qemu
( cd "$Q" && meson subprojects download )

log "Applying anti-detection edits to QEMU"
( cd "$Q"
  bash "$KIT/qemu/anti-detection.sh"
  sed -e "s/@SMBIOS_PSU_NAME@/$SMBIOS_PSU_NAME/" \
      -e "s/@SMBIOS_BATTERY_VENDOR@/$SMBIOS_BATTERY_VENDOR/" \
      -e "s/@SMBIOS_BATTERY_SERIAL@/$SMBIOS_BATTERY_SERIAL/" "$KIT/qemu/smbios.patch" | patch -p1 --forward
  [ "$STRONG_PCI_IDS" = 1 ] && bash "$KIT/qemu/strong-pci-ids.sh"
  if [ "$IGD_LPC_HACK" = 1 ]; then
    grep -q '!object_dynamic_cast(OBJECT(lpc_bridge)' hw/vfio/igd.c
    sed -i 's/!object_dynamic_cast(OBJECT(lpc_bridge)/object_dynamic_cast(OBJECT(lpc_bridge)/' hw/vfio/igd.c
  fi
  if [ -n "$BOOTSPLASH_JPG" ]; then
    cp "$BOOTSPLASH_JPG" pc-bios/bootsplash.jpg
    sed -i "s/  'vgabios.bin',/  'vgabios.bin',\n  'bootsplash.jpg',/" pc-bios/meson.build
    sed -i 's|current_machine->boot_config.splash;|"/usr/share/kvm/bootsplash.jpg";|' hw/nvram/fw_cfg.c
  fi
)

if [ "$BUILD_SEABIOS" = 1 ]; then
  log "Building SeaBIOS from source (replaces the prebuilt pc-bios/bios*.bin from upstream QEMU)"
  ( cd "$Q/roms/seabios" && git apply "$KIT/seabios/seabios.patch"
    # fixed version string instead of "<git>-dirty-<date>-<hostname>-prebuilt.qemu.org"
    sed -i "s/    write_version(outfile, ver + options.extra, toolstr)/    write_version(outfile, '$SEABIOS_VERSION', toolstr)/" scripts/buildversion.py
    grep -q "'$SEABIOS_VERSION'" scripts/buildversion.py )
  ( cd "$Q/roms/seabios" && git diff ) > "$OUT/seabios-applied.diff"
  make -C "$Q/roms" bios FIRMWARE_EXTRAVERSION=
  make -C "$Q/roms" clean >/dev/null 2>&1 || true
fi
( cd "$Q" && git diff ) > "$OUT/qemu-applied.diff"

log "Building pve-qemu-kvm"
make -C "$WORK/pve-qemu" deb
cp "$WORK"/pve-qemu/pve-qemu-kvm_*.deb "$OUT/"
rm -f "$OUT"/pve-qemu-kvm-dbgsym_*.deb

fi

if want edk2; then
# ======================================================================== OVMF
log "pve-edk2-firmware @ $PVE_EDK2_COMMIT"
clone_pinned pve-edk2-firmware "$PVE_EDK2_COMMIT"
install_build_deps "$WORK/pve-edk2-firmware"
E=$WORK/pve-edk2-firmware
if [ -n "$LOGO_BMP" ]; then cp "$LOGO_BMP" "$E/debian/Logo.bmp"
else python3 -I "$KIT/tools/make-logo.py" "$E/debian/Logo.bmp"; fi
if [ -n "$OVMF_FW_VENDOR" ]; then
  # Proxmox sets the UEFI firmware vendor to "Proxmox distribution of EDK II" (the author's
  # builds keep it). Replace vendor/version so the guest does not see it.
  grep -q 'PcdFirmwareVendor=L"Proxmox distribution of EDK II' "$E/debian/rules"
  sed -i "s|PcdFirmwareVendor=L\"Proxmox distribution of EDK II|PcdFirmwareVendor=L\"$OVMF_FW_VENDOR|" "$E/debian/rules"
  sed -i "s|PcdFirmwareVersionString=L\"\$(DEB_VERSION)|PcdFirmwareVersionString=L\"$OVMF_FW_VERSION|" "$E/debian/rules"
  grep -q "PcdFirmwareVersionString=L\"$OVMF_FW_VERSION" "$E/debian/rules"
fi
log "Applying anti-detection edits to edk2"
( cd "$E/edk2" && bash "$KIT/edk2/anti-detection.sh" && git diff ) > "$OUT/edk2-applied.diff"
log "Building pve-edk2-firmware"
make -C "$E" deb
cp "$E"/pve-edk2-firmware-*.deb "$OUT/"

fi

if want acpi; then
# ======================================================================== ACPI
log "Compiling ACPI tables"
bash "$KIT/acpi/build-acpi.sh" "$OUT"

fi

( cd "$OUT" && sha256sum $(ls ./*.deb ./*.aml ./*.diff 2>/dev/null) > SHA256SUMS )
log "Done. Results in $OUT"
ls -la "$OUT"
