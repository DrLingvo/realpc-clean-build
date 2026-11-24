#!/bin/bash
# Anti-detection source edits for QEMU 11.1.x (pve-qemu 11.1.3-4).
# Derived from AICodo/pve-emu-realpc sedPatch-pve-qemu-kvm7-8-anti-dection.sh
# (itself based on zhaodice/proxmox-ve-anti-detection), ported to QEMU 11:
#  - every substitution is checked: if it no longer matches, the build stops
#  - author fingerprints (aiiaicodo, 666, 114514...) replaced by config values
#  - edits that were silent no-ops on QEMU 11 re-targeted to the new code locations
# Run from the top of the QEMU source tree. Config comes from ../config.env.
set -euo pipefail
: "${brand:?}" "${IDE_FW_REV:?}" "${SCSI_FW_REV:?}" "${POH:?}" "${PCC:?}" \
  "${SAS_ADDR:?}" "${USB_HUB_SERIAL:?}" "${USB_NET_MAC:?}" "${SMBIOS_T1_VERSION:?}"
POH_LO=$(printf '0x%02x' $((POH & 0xff)));  POH_HI=$(printf '0x%02x' $((POH >> 8 & 0xff)))
PCC_LO=$(printf '0x%02x' $((PCC & 0xff)));  PCC_HI=$(printf '0x%02x' $((PCC >> 8 & 0xff)))

FAILED=0
# S <sed-expr> <file> [more files...]: apply sed in place and require that it changed something
S() {
  local expr=$1; shift
  local f
  for f in "$@"; do
    if [ ! -f "$f" ]; then echo "ERROR: missing file $f (expr: $expr)" >&2; FAILED=1; continue; fi
    local before; before=$(md5sum < "$f")
    sed -i "$expr" "$f"
    if [ "$before" == "$(md5sum < "$f")" ]; then echo "ERROR: no match in $f: $expr" >&2; FAILED=1; fi
  done
}

S 's/QEMU v" QEMU_VERSION/'${brand}' v" QEMU_VERSION/g' block/vhdx.c
S 's/QEMU VVFAT", 10/'${brand}' VVFAT", 10/g' block/vvfat.c
S 's/QEMU Microsoft Mouse/'${brand}' Microsoft Mouse/g' chardev/msmouse.c
S 's/QEMU Wacom Pen Tablet/'${brand}' Wacom Pen Tablet/g' chardev/wctablet.c
S 's/QEMU vhost-user-gpu/'${brand}' vhost-user-gpu/g' contrib/vhost-user-gpu/vhost-user-gpu.c
S 's/desc->oem_id/ACPI_BUILD_APPNAME6/g' hw/acpi/aml-build.c
S 's/desc->oem_table_id/ACPI_BUILD_APPNAME8/g' hw/acpi/aml-build.c
S 's/array, ACPI_BUILD_APPNAME8/array, "PTL "/g' hw/acpi/aml-build.c
S 's/"QEMU/"Intel/g' hw/acpi/aml-build.c

# vmgenid: do not emit the VMGENID SSDT (VM-generation-ID device is a VM indicator)
S 's/    Aml \*ssdt/    return; \/\* anti-detection: no vmgenid ssdt \*\/\n    Aml *ssdt/' hw/acpi/vmgenid.c
S 's/"QEMUQEQEMUQEMU/"ASUSASASUSASUS/g' hw/acpi/core.c
S 's/"QEMU/"'${brand}'/g' hw/acpi/core.c
S "s/QEMU 'SBSA Reference' ARM Virtual Machine/"${brand}" 'SBSA Reference' ARM Real Machine/g" hw/arm/sbsa-ref.c
S 's/QEMU Sun Mouse/'${brand}' Sun Mouse/g' hw/char/escc.c
S 's/info->vendor = "RHT"/info->vendor = "DEL"/g' hw/display/edid-generate.c
S 's/QEMU Monitor/'${brand}' Monitor/g' hw/display/edid-generate.c
S 's/uint16_t model_nr = 0x1234;/uint16_t model_nr = 0xA05F;/g' hw/display/edid-generate.c

# acpi-build: empty debug AML, comment out the fw_cfg ACPI node
S '/static void build_dbg_aml(Aml \*table)/,/ /s/{/{\n     return;/' hw/i386/acpi-build.c
S '/create fw_cfg node/,/}/s/}/}*\//' hw/i386/acpi-build.c
S '/create fw_cfg node/,/}/s/{/\/*{/' hw/i386/acpi-build.c
S 's/"QEMU/"'${brand}'/g' hw/i386/fw_cfg.c
S 's/Standard PC (i440FX + PIIX, 1996)/'${brand}' M4A88TD-Mi440fx/g' hw/i386/pc_piix.c
S 's/Standard PC (Q35 + ICH9, 2009)/'${brand}' M4A88TD-Mq35/g' hw/i386/pc_q35.c
S 's/"QEMU/"'${brand}'/g' hw/ide/atapi.c
S 's/"QEMU/"'${brand}'/g' hw/ide/core.c
#sed -i 's/QM%05d/'${brand}'-aiiaicodo666-%02d/g' hw/ide/core.c  #ide sata硬盘序列号drive_serial_str 20字符大小 这个是固定硬盘序列号方法，下面三行是硬盘随机序列号方法
S 's/0x09, 0x03, 0x00, 0x64, 0x64, 0x01, 0x00/0x09, 0x03, 0x00, 0x64, 0x64, '${POH_LO}', '${POH_HI}'/g' hw/ide/core.c  # SMART power-on hours (configurable)
S 's/0x0c, 0x03, 0x00, 0x64, 0x64, 0x00, 0x00/0x0c, 0x03, 0x00, 0x64, 0x64, '${PCC_LO}', '${PCC_HI}'/g' hw/ide/core.c  # SMART power-cycle count (configurable)
S 's/"QEMU/"'${brand}'/g' hw/input/adb-kbd.c
S 's/"QEMU/"'${brand}'/g' hw/input/adb-mouse.c
S 's/"QEMU/"'${brand}'/g' hw/input/hid.c
S 's/"QEMU/"'${brand}'/g' hw/input/ps2.c
S 's/"QEMU Virtio/"'${brand}'/g' hw/input/virtio-input-hid.c
S 's/QEMU M68K Virtual Machine/'${brand}' M68K Real Machine/g' hw/m68k/virt.c
S 's/"QEMU/"'${brand}'/g' hw/misc/pvpanic-isa.c
S 's/"QEMU/"'${brand}'/g' hw/nvme/ctrl.c
S 's/0x51454d5520434647ULL/0x4155535520434647ULL/g' hw/nvram/fw_cfg.c
S 's/"QEMU/"'${brand}'/g' hw/nvram/fw_cfg-acpi.c
S 's/"QEMU/"'${brand}'/g' hw/pci-host/gpex.c
S 's/"QEMU/"'${brand}'/g' hw/ppc/prep.c
S 's/"QEMU/"'${brand}'/g' hw/ppc/e500plat.c
S 's/qemu-e500/asus-e500/g' hw/ppc/e500plat.c
S 's/"QEMU Virtual/"'${brand}'/g' hw/riscv/virt.c
S 's/"KVM Virtual/"'${brand}'/g' hw/riscv/virt.c
S 's/"QEMU/"'${brand}'/g' hw/riscv/virt.c
S 's/s16s8s16s16s16/s11s4s51s41s91/g' hw/scsi/mptconfig.c
S 's/QEMU MPT Fusion/'${brand}' MPT Fusion/g' hw/scsi/mptconfig.c
S 's/"QEMU"/"'${brand}'"/g' hw/scsi/mptconfig.c
S 's/0000111122223333/'${SAS_ADDR}'/g' hw/scsi/mptconfig.c
S 's/"QEMU/"'${brand}'/g' hw/scsi/scsi-bus.c
S 's/"QEMU/"'${brand}'/g' hw/scsi/megasas.c
S 's/"QEMU/"'${brand}'/g' hw/scsi/scsi-disk.c
S 's/"QEMU/"'${brand}'/g' hw/scsi/spapr_vscsi.c
S 's/"QEMU/"'${brand}'/g' hw/sd/sd.c
S 's/"QEMU/"'${brand}'/g' hw/ufs/lu.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-audio.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-hid.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-hub.c
S 's/314159/'${USB_HUB_SERIAL}'/g' hw/usb/dev-hub.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-mtp.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-network.c
S 's/"RNDIS\/QEMU/"RNDIS\/'${brand}'/g' hw/usb/dev-network.c
S 's/400102030405/'${USB_NET_MAC}'/g' hw/usb/dev-network.c
S 's/s->vendorid = 0x1234/s->vendorid = 0x8086/g' hw/usb/dev-network.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-serial.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-smartcard-reader.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-storage.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-uas.c
S 's/27842/33121/g' hw/usb/dev-uas.c
S 's/"QEMU/"'${brand}'/g' hw/usb/dev-wacom.c
S 's/"QEMU/"'${brand}'/g' hw/usb/u2f-emulated.c
S 's/"QEMU/"'${brand}'/g' hw/usb/u2f-passthru.c
S 's/"QEMU/"'${brand}'/g' hw/usb/u2f.c
S 's/"BOCHS/"INTEL/g' include/hw/acpi/aml-build.h
S 's/"BXPC/"PC8086/g' include/hw/acpi/aml-build.h
S 's/"QEMU0002/"'${brand}'0002/g' include/standard-headers/linux/qemu_fw_cfg.h
S 's/0x51454d5520434647ULL/0x4155535520434647ULL/g' include/standard-headers/linux/qemu_fw_cfg.h
S 's/"QEMU/"'${brand}'/g' migration/rdma.c
S 's/0x51454d5520434647ULL/0x4155535520434647ULL/g' pc-bios/optionrom/optionrom.h
S 's/"QEMU/"'${brand}'/g' pc-bios/s390-ccw/virtio-scsi.h
S 's/KVMKVMKVM\\0\\0\\0/\\1\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0\\0/g' target/i386/kvm/kvm.c
S 's/QEMUQEMUQEMUQEMU/ASUSASUSASUSASUS/g' target/s390x/tcg/misc_helper.c
S 's/"QEMU/"'${brand}'/g' target/s390x/tcg/misc_helper.c
S 's/"KVM/"ATX/g' target/s390x/tcg/misc_helper.c
S 's/"QEMU TCG CPU version/"TCG CPU version/g' target/i386/cpu.c
S 's/"Microsoft Hv/"GenuineIntel/g' target/i386/cpu.c  #解决n卡vgpu驱动43问题
S 's/for (i = 0; i < nb_eeprom/eeprom_buf[0]=0x92;\neeprom_buf[1]=0x10;\neeprom_buf[2]=0x0B;\neeprom_buf[3]=0x03;\neeprom_buf[4]=0x06;\neeprom_buf[5]=0x21;\neeprom_buf[6]=0x02;\neeprom_buf[7]=0x09;\neeprom_buf[8]=0x03;\neeprom_buf[9]=0x52;\neeprom_buf[0x0a]=0x01;\neeprom_buf[0x0b]=0x08;\neeprom_buf[0x0c]=0x0A;\neeprom_buf[0x0d]=0x00;\neeprom_buf[0x0e]=0xFE;\neeprom_buf[0x0f]=0x00;\neeprom_buf[0x10]=0x5A;\neeprom_buf[0x11]=0x78;\neeprom_buf[0x12]=0x5A;\neeprom_buf[0x13]=0x30;\neeprom_buf[0x14]=0x5A;\neeprom_buf[0x15]=0x11;\neeprom_buf[0x16]=0x0E;\neeprom_buf[0x17]=0x81;\neeprom_buf[0x18]=0x20;\neeprom_buf[0x19]=0x08;\neeprom_buf[0x1a]=0x3C;\neeprom_buf[0x1b]=0x3C;\neeprom_buf[0x1c]=0x00;\neeprom_buf[0x1d]=0xF0;\neeprom_buf[0x1e]=0x83;\neeprom_buf[0x1f]=0x81;\neeprom_buf[0x3c]=0x0F;\neeprom_buf[0x3d]=0x11;\neeprom_buf[0x3e]=0x65;\neeprom_buf[0x3f]=0x00;\neeprom_buf[0x70]=0x00;\neeprom_buf[0x71]=0x00;\neeprom_buf[0x72]=0x00;\neeprom_buf[0x73]=0x00;\neeprom_buf[0x74]=0x00;\neeprom_buf[0x75]=0x01;\neeprom_buf[0x76]=0x98;\neeprom_buf[0x77]=0x07;\neeprom_buf[0x78]=0x25;\neeprom_buf[0x79]=0x18;\neeprom_buf[0x7a]=0x00;\neeprom_buf[0x7b]=0x00;\neeprom_buf[0x7c]=0x00;\neeprom_buf[0x7d]=0x00;\neeprom_buf[0x7e]=0x3D;\neeprom_buf[0x7f]=0xA7;\neeprom_buf[0x80]=0x4B;\neeprom_buf[0x81]=0x48;\neeprom_buf[0x82]=0x58;\neeprom_buf[0x83]=0x31;\neeprom_buf[0x84]=0x36;\neeprom_buf[0x85]=0x30;\neeprom_buf[0x86]=0x30;\neeprom_buf[0x87]=0x43;\neeprom_buf[0x88]=0x39;\neeprom_buf[0x89]=0x53;\neeprom_buf[0x8a]=0x33;\neeprom_buf[0x8b]=0x4C;\neeprom_buf[0x8c]=0x2F;\neeprom_buf[0x8d]=0x33;\neeprom_buf[0x8e]=0x32;\neeprom_buf[0x8f]=0x47;\neeprom_buf[0x90]=0x20;\neeprom_buf[0x91]=0x20;\neeprom_buf[0x92]=0x00;\neeprom_buf[0x93]=0x00;\neeprom_buf[0x94]=0x00;\neeprom_buf[0x95]=0x00;\neeprom_buf[0xfe]=0x00;\neeprom_buf[0xff]=0x5A;\nfor (i = 0; i < nb_eeprom/g' hw/i2c/smbus_eeprom.c  #添加内存 DDR3L 8G的默认spd信息，序列号0000000不处理
#sed -i 's/#define PCI_SUBVENDOR_ID_REDHAT_QUMRANET 0x1af4/#define PCI_SUBVENDOR_ID_REDHAT_QUMRANET 0x8086/g' include/hw/pci/pci.h # 0x1afe 是qemu虚拟机的id，这里为了兼容性只处理SUBVENDOR_ID。如果处理了VENDOR_ID=0x1af4 或者 VENDOR_ID=0x1b36 为其他值会造成一些设备无法使用。
#sed -i 's/#define PCI_VENDOR_ID_REDHAT_QUMRANET    0x1af4/#define PCI_VENDOR_ID_REDHAT_QUMRANET    0x8085/g' include/hw/pci/pci.h #如果处理了VENDOR_ID=0x1af4 或者 VENDOR_ID=0x1b36 为其他值会造成一些设备无法使用。比如scsi virtioNET virtioBlock不认
# Do not globally renumber PCI vendors or device IDs. Board-specific identity values
# come only from profiles/chipset-map.json imported from real host dumps. Device behavior
# remains the selected QEMU model; configvm also excludes devices that expose VEN_1B36.
S 's/build_append_int_noprefix(tbl, 0 \/\* Unspecified \*\/, 1);/build_append_int_noprefix(tbl, 1 \/\* Desktop \*\/, 1);/' hw/acpi/aml-build.c # Desktop power profile; zero is a QEMU indicator.
S 's/rev = 3/rev = 4/g' hw/i386/acpi-build.c # Most VMs use an older-style FADT of length 244  bytes (revision  3), cutting off before the Sleep Control/Status registers and Hypervisor ID
S 's/fadt.rev = 1/fadt.rev = 4/g' hw/i386/acpi-build.c # Most VMs use an older-style FADT of length 244  bytes (revision  3), cutting off before the Sleep Control/Status registers and Hypervisor ID
S 's/if (f->rev <= 4) {/if (f->rev <= 6) {\n\t\tbuild_append_gas_from_struct(tbl, \&f->sleep_ctl);\n\t\tbuild_append_gas_from_struct(tbl, \&f->sleep_sts);/g' hw/acpi/aml-build.c # # Most VMs use an older-style FADT of length 244  bytes (revision  3), cutting off before the Sleep Control/Status registers and Hypervisor ID
S 's/lat = 0xfff/lat = 0x1fff/g' hw/i386/acpi-build.c  # A value > 100 indicates the system does not support a C2/C3 state
# Remove WAET generation entirely; renaming its signature only hides a marker.
sed -i '/^    acpi_add_table(table_offsets, tables_blob);$/{N;/\n    build_waet(/d;}' hw/i386/acpi-build.c
! grep -q '^    build_waet(' hw/i386/acpi-build.c || { echo "ERROR: WAET emission remains" >&2; FAILED=1; }
# QEMU already builds one HPET device and one HPET table. Correct its OEM data
# and valid periodic tick minimum; do not inject another HPET from an AML file.
sed -i '/^build_hpet(/,/^}/ s/\.oem_id = oem_id, \.oem_table_id = oem_table_id };/                        .oem_id = "ALASKA", .oem_table_id = "A M I " };/' hw/i386/acpi-build.c
grep -A4 '^build_hpet(' hw/i386/acpi-build.c | grep -q '.oem_id = "ALASKA", .oem_table_id = "A M I "' || { echo "ERROR: HPET OEM edit failed" >&2; FAILED=1; }
S 's/build_append_int_noprefix(table_data, 0, 2);/build_append_int_noprefix(table_data, 0x80, 2);/g' hw/i386/acpi-build.c
S 's/rev = 1/rev = 3/g' hw/i386/acpi-build.c # 全部升级最低为3
S 's/dev = aml_device("PCI0");/aml_append(sb_scope, aml_name_decl("OSYS", aml_int(0x03E8)));\n\tAml *osi = aml_if(aml_equal(aml_call1("_OSI", aml_string("Windows 2012")), aml_int(1)));\n\taml_append(osi, aml_store(aml_int(0x07DC), aml_name("OSYS")));\n\taml_append(sb_scope, osi);\n\tosi = aml_if(aml_equal(aml_call1("_OSI",aml_string("Windows 2013")), aml_int(1)));\n\taml_append(osi, aml_store(aml_int(0x07DD), aml_name("OSYS")));\n\taml_append(sb_scope, osi);\n\tdev = aml_device("PCI0");/g' hw/i386/acpi-build.c # windows 2012 2013 _TZ_ _PTS dsdt
#sed -i 's/0x0627/0x6666/g' hw/input/virtio-input-hid.c # 0x0627=QEMU tablet usb键鼠会有少量问题
#sed -i 's/0x0627/0x6666/g' hw/usb/dev-hid.c # 0x0627=QEMU tablet usb键鼠会有少量问题

# ---- QEMU 11 re-targets (these were silent no-ops in the original script) ----
# Legacy CPU model ids ("QEMU Virtual CPU version 2.5+") moved from hw/i386/pc.c to target/i386/cpu.c
S 's/"QEMU Virtual CPU version "/"CPU version "/g' target/i386/cpu.c
# SMBIOS type 1 "version" default was the machine type name (e.g. pc-q35-11.1)
S 's/smbios_set_defaults("'${brand}'", mc->desc, mc->name);/smbios_set_defaults("'${brand}'", mc->desc, "'${SMBIOS_T1_VERSION}'");/' hw/i386/fw_cfg.c
# Disk firmware revision: QEMU_HW_VERSION ("2.5+") is a well-known VM marker
S 's/pstrcpy(s->version, sizeof(s->version), QEMU_HW_VERSION);/pstrcpy(s->version, sizeof(s->version), "'${IDE_FW_REV}'");/' hw/ide/core.c
S 's/pstrcpy((char \*) \&r->buf\[32\], 4, QEMU_HW_VERSION);/pstrcpy((char *) \&r->buf[32], 4, "'${SCSI_FW_REV}'");/' hw/scsi/scsi-bus.c
S 's/s->version = g_strdup(QEMU_HW_VERSION);/s->version = g_strdup("'${SCSI_FW_REV}'");/' hw/scsi/scsi-disk.c

if [ "$FAILED" -ne 0 ]; then echo "anti-detection.sh: some edits did not apply, refusing to continue" >&2; exit 1; fi
echo "anti-detection.sh: all edits applied"
