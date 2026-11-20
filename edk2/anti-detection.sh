#!/bin/bash
# Anti-detection source edits for edk2 (OVMF) as packaged by pve-edk2-firmware 4.2026.08-1.
# Derived from AICodo/pve-emu-realpc_edk2-firmware-ovmf sedPatch-pve-edk2-firmware-anti-dection.sh.
# Each substitution must match or the build stops. Run from the top of the edk2 tree.
set -euo pipefail
: "${brand_edk2:?}" "${STRONG_PCI_IDS:?}"
brand="$brand_edk2"
FAILED=0
S() {
  local expr=$1; shift; local f
  for f in "$@"; do
    if [ ! -f "$f" ]; then echo "ERROR: missing file $f" >&2; FAILED=1; continue; fi
    local before; before=$(md5sum < "$f"); sed -i "$expr" "$f"
    [ "$before" != "$(md5sum < "$f")" ] || { echo "ERROR: no match in $f: $expr" >&2; FAILED=1; }
  done
}

S 's/0x20202020324B4445/0x20202020204c5450/g' MdeModulePkg/MdeModulePkg.dec
S 's/QemuFwCfgAcpiPlatform/'${brand}'FwCfgAcpiPlatform/g' OvmfPkg/AcpiPlatformDxe/AcpiPlatformDxe.inf
S 's/= VirtioFdtDxe/= '${brand}'ioFdtDxe/g' OvmfPkg/Fdt/VirtioFdtDxe/VirtioFdtDxe.inf
S 's/BASE_NAME                      = QemuKernelLoaderFsDxe/BASE_NAME                      = '${brand}'KernelLoaderFsDxe/g' OvmfPkg/QemuKernelLoaderFsDxe/QemuKernelLoaderFsDxe.inf
S 's/= QemuRamfbDxe/= '${brand}'RamfbDxe/g' OvmfPkg/QemuRamfbDxe/QemuRamfbDxe.inf
S 's/= QemuVideoDxe/= '${brand}'VideoDxe/g' OvmfPkg/QemuVideoDxe/QemuVideoDxe.inf
S 's/BASE_NAME                      = VirtHstiDxe/BASE_NAME                      = '${brand}'HstiDxe/g' OvmfPkg/VirtHstiDxe/VirtHstiDxe.inf
S 's/BASE_NAME                      = Virtio10/BASE_NAME                      = '${brand}'io10/g' OvmfPkg/Virtio10Dxe/Virtio10.inf
S 's/= VirtioBlkDxe/= '${brand}'ioBlkDxe/g' OvmfPkg/VirtioBlkDxe/VirtioBlk.inf
S 's/= VirtioFsDxe/= '${brand}'ioFsDxe/g' OvmfPkg/VirtioFsDxe/VirtioFsDxe.inf
S 's/= VirtioGpuDxe/= '${brand}'ioGpuDxe/g' OvmfPkg/VirtioGpuDxe/VirtioGpu.inf
S 's/= VirtioNetDxe/= '${brand}'ioNetDxe/g' OvmfPkg/VirtioNetDxe/VirtioNet.inf
S 's/= VirtioPciDeviceDxe/= '${brand}'ioPciDeviceDxe/g' OvmfPkg/VirtioPciDeviceDxe/VirtioPciDeviceDxe.inf
S 's/= VirtioRngDxe/= '${brand}'ioRngDxe/g' OvmfPkg/VirtioRngDxe/VirtioRng.inf
S 's/= VirtioScsiDxe/= '${brand}'ioScsiDxe/g' OvmfPkg/VirtioScsiDxe/VirtioScsi.inf
S 's/= VirtioSerialDxe/= '${brand}'ioSerialDxe/g' OvmfPkg/VirtioSerialDxe/VirtioSerial.inf
S 's/= VirtNorFlashDxe/= '${brand}'NorFlashDxe/g' OvmfPkg/VirtNorFlashDxe/VirtNorFlashDxe.inf
S 's/= XenAcpiPlatform/= '${brand}'AcpiPlatform/g' OvmfPkg/XenAcpiPlatformDxe/XenAcpiPlatformDxe.inf
S 's/BASE_NAME                 = XenBusDxe/BASE_NAME                 = '${brand}'BusDxe/g' OvmfPkg/XenBusDxe/XenBusDxe.inf
S 's/= XenIoPciDxe/= '${brand}'IoPciDxe/g' OvmfPkg/XenIoPciDxe/XenIoPciDxe.inf
S 's/= XenIoPvhDxe/= '${brand}'IoPvhDxe/g' OvmfPkg/XenIoPvhDxe/XenIoPvhDxe.inf
S 's/= XenPlatformPei/= '${brand}'PlatformPei/g' OvmfPkg/XenPlatformPei/XenPlatformPei.inf
S 's/BASE_NAME                 = XenPvBlkDxe/BASE_NAME                 = '${brand}'PvBlkDxe/g' OvmfPkg/XenPvBlkDxe/XenPvBlkDxe.inf
S 's/= XenResetVector/= '${brand}'ResetVector/g' OvmfPkg/XenResetVector/XenResetVector.inf
S 's/BASE_NAME                      = XenSmbiosPlatformDxe/BASE_NAME                      = '${brand}'SmbiosPlatformDxe/g' OvmfPkg/SmbiosPlatformDxe/XenSmbiosPlatformDxe.inf
S 's/BASE_NAME                      = XenIoMmioLib/BASE_NAME                      = '${brand}'IoMmioLib/g' OvmfPkg/Library/XenIoMmioLib/XenIoMmioLib.inf
S 's/BASE_NAME                      = XenPlatformLib/BASE_NAME                      = '${brand}'PlatformLib/g' OvmfPkg/Library/XenPlatformLib/XenPlatformLib.inf
S 's/BASE_NAME                      = QemuFwCfgDxeLib/BASE_NAME                      = '${brand}'FwCfgDxeLib/g' OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgDxeLib.inf
S 's/BASE_NAME                      = QemuFwCfgLibNull/BASE_NAME                      = '${brand}'FwCfgLibNull/g' OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgLibNull.inf
S 's/BASE_NAME                      = QemuFwCfgLib/BASE_NAME                      = '${brand}'FwCfgLib/g' OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgMmioDxeLib.inf
S 's/BASE_NAME                      = QemuFwCfgPeiLib/BASE_NAME                      = '${brand}'FwCfgPeiLib/g' OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgMmioPeiLib.inf
S 's/BASE_NAME                      = QemuFwCfgPeiLib/BASE_NAME                      = '${brand}'FwCfgPeiLib/g' OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgPeiLib.inf
S 's/BASE_NAME                      = QemuFwCfgSecLib/BASE_NAME                      = '${brand}'FwCfgSecLib/g' OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgSecLib.inf
S 's/BASE_NAME                      = XenHypercallLib/BASE_NAME                      = '${brand}'HypercallLib/g' OvmfPkg/Library/XenHypercallLib/XenHypercallLib.inf
S 's/BASE_NAME                      = QemuBootOrderLib/BASE_NAME                      = '${brand}'BootOrderLib/g' OvmfPkg/Library/QemuBootOrderLib/QemuBootOrderLib.inf
S 's/BASE_NAME                      = VirtioMmioDeviceLib/BASE_NAME                      = '${brand}'ioMmioDeviceLib/g' OvmfPkg/Library/VirtioMmioDeviceLib/VirtioMmioDeviceLib.inf
S 's/BASE_NAME                      = X86QemuLoadImageLib/BASE_NAME                      = X86'${brand}'LoadImageLib/g' OvmfPkg/Library/X86QemuLoadImageLib/X86QemuLoadImageLib.inf
S 's/BASE_NAME                      = XenRealTimeClockLib/BASE_NAME                      = '${brand}'RealTimeClockLib/g' OvmfPkg/Library/XenRealTimeClockLib/XenRealTimeClockLib.inf
S 's/BASE_NAME                      = XenConsoleSerialPortLib/BASE_NAME                      = '${brand}'ConsoleSerialPortLib/g' OvmfPkg/Library/XenConsoleSerialPortLib/XenConsoleSerialPortLib.inf
S 's/BASE_NAME                      = QemuFwCfgSimpleParserLib/BASE_NAME                      = '${brand}'FwCfgSimpleParserLib/g' OvmfPkg/Library/QemuFwCfgSimpleParserLib/QemuFwCfgSimpleParserLib.inf
S 's/BASE_NAME                      = VirtNorFlashStaticLib/BASE_NAME                      = '${brand}'NorFlashStaticLib/g' OvmfPkg/RiscVVirt/Library/VirtNorFlashPlatformLib/VirtNorFlashStaticLib.inf
S 's/BASE_NAME                      = VirtNorFlashDeviceTreeLib/BASE_NAME                      = '${brand}'NorFlashDeviceTreeLib/g' OvmfPkg/RiscVVirt/Library/VirtNorFlashPlatformLib/VirtNorFlashDeviceTreeLib.inf
S 's/BASE_NAME                      = BaseQemuFwCfgS3LibNull/BASE_NAME                      = Base'${brand}'FwCfgS3LibNull/g' OvmfPkg/Library/QemuFwCfgS3Lib/BaseQemuFwCfgS3LibNull.inf
S 's/BASE_NAME                      = DxeQemuFwCfgS3LibFwCfg/BASE_NAME                      = Dxe'${brand}'FwCfgS3LibFwCfg/g' OvmfPkg/Library/QemuFwCfgS3Lib/DxeQemuFwCfgS3LibFwCfg.inf
S 's/BASE_NAME                      = PeiQemuFwCfgS3LibFwCfg/BASE_NAME                      = Pei'${brand}'FwCfgS3LibFwCfg/g' OvmfPkg/Library/QemuFwCfgS3Lib/PeiQemuFwCfgS3LibFwCfg.inf
S 's/BASE_NAME                      = GenericQemuLoadImageLib/BASE_NAME                      = Generic'${brand}'LoadImageLib/g' OvmfPkg/Library/GenericQemuLoadImageLib/GenericQemuLoadImageLib.inf
S 's/1920, 1080/1920, 1080}, {2048, 1506}, {2560, 1664}, {2880, 1864},{2880, 1800},{3024, 1964},{3024, 1900},{3456, 2234/g' OvmfPkg/QemuVideoDxe/Initialize.c

# ---- found by diffing the author's closed "Strong" OVMF against the normal build ----
# The only functional change: QemuVideoDxe matches re-branded PCI vendor IDs for
# stdvga (0x1234), virtio-vga (0x1af4) and vmware-svga (0x15ad). Must be paired with the
# same change on the QEMU side (STRONG_PCI_IDS=1 does both).
if [ "$STRONG_PCI_IDS" = 1 ]; then
  : "${STDVGA_VENDOR:?}" "${VIRTIO_VENDOR:?}"
  S "s/^    0x1234,/    ${STDVGA_VENDOR},/" OvmfPkg/QemuVideoDxe/Driver.c
  S "s/^    0x1af4,/    ${VIRTIO_VENDOR},/" OvmfPkg/QemuVideoDxe/Driver.c
  S "s/^    0x15ad,/    ${VIRTIO_VENDOR},/" OvmfPkg/QemuVideoDxe/Driver.c
fi

[ "$FAILED" -eq 0 ] || { echo "edk2 anti-detection: some edits did not apply" >&2; exit 1; }
echo "edk2 anti-detection: all edits applied"
