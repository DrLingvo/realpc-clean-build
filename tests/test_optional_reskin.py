#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENV = {"FW_CFG_BRAND": "ASUS", "FW_CFG_SIGNATURE_HEX": "0x4155535520434647",
       "FW_CFG_ACPI_ID": "ASUS0002", "HOST_BRIDGE_DEVICE": "0x9b43",
       "HOST_BRIDGE_EVIDENCE_SHA256": "a" * 64, "PATH": os.environ["PATH"]}


class OptionalReskinTest(unittest.TestCase):
    def run_script(self, relative, cwd):
        return subprocess.run(["bash", str(ROOT / relative)], cwd=cwd, env=ENV,
                              text=True, capture_output=True, check=True)

    def test_options_default_off_and_baseline_signature_is_stock(self):
        config = (ROOT / "config.env").read_text()
        self.assertIn("STRONG_FW_CFG=0", config)
        self.assertIn("STRONG_HOST_BRIDGE=0", config)
        qemu = (ROOT / "qemu" / "anti-detection.sh").read_text()
        self.assertNotIn("0x51454d5520434647ULL", qemu)
        seabios = (ROOT / "seabios" / "seabios.patch").read_text()
        self.assertNotIn('char *sig = "intel"', seabios)
        self.assertNotIn("//return 0", seabios)

    def test_disabled_reskins_cannot_fail_build_block_exit_status(self):
        build = (ROOT / "build.sh").read_text()
        for component in ("qemu", "seabios"):
            for option, script in (("STRONG_FW_CFG", "strong-fw-cfg.sh"),
                                   ("STRONG_HOST_BRIDGE", "strong-host-bridge.sh")):
                self.assertIn(
                    f'if [ "${option}" = 1 ]; then bash "$KIT/{component}/{script}"; fi',
                    build)
                self.assertNotIn(
                    f'[ "${option}" = 1 ] && bash "$KIT/{component}/{script}"', build)

    def test_fw_cfg_patchers_cover_qemu_ovmf_seabios_and_optionrom(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files = {
                "hw/nvram/fw_cfg.c": "0x51454d5520434647ULL",
                "include/standard-headers/linux/qemu_fw_cfg.h": '"QEMU0002" 0x51454d5520434647ULL',
                "pc-bios/optionrom/optionrom.h": "0x51454d5520434647ULL",
            }
            for name, data in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data)
            self.run_script("qemu/strong-fw-cfg.sh", root)
            for path in files:
                data = (root / path).read_text()
                self.assertNotIn("51454d5520434647", data)
                self.assertNotIn("QEMU0002", data)
            ovmf = root / "OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgPeiLib.c"
            ovmf.parent.mkdir(parents=True)
            ovmf.write_text('CompareMem(Signature, "QEMU", 4);')
            self.run_script("edk2/strong-fw-cfg.sh", root)
            self.assertIn('"ASUS"', ovmf.read_text())
            seabios = root / "src/fw/paravirt.c"
            seabios.parent.mkdir(parents=True, exist_ok=True)
            seabios.write_text('char *sig = "QEMU";\nif (inb(PORT_QEMU_CFG_DATA) != sig[i])\n return 0;\n')
            self.run_script("seabios/strong-fw-cfg.sh", root)
            self.assertIn('char *sig = "ASUS";', seabios.read_text())

    def test_host_bridge_patchers_use_one_validated_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            qemu = root / "include/hw/pci/pci_ids.h"
            qemu.parent.mkdir(parents=True)
            qemu.write_text("#define PCI_DEVICE_ID_INTEL_P35_MCH      0x29c0\n")
            self.run_script("qemu/strong-host-bridge.sh", root)
            self.assertIn("0x9b43", qemu.read_text())
            seabios = root / "src/fw/paravirt.c"
            seabios.parent.mkdir(parents=True)
            seabios.write_text("case 0x29c0:\n")
            self.run_script("seabios/strong-host-bridge.sh", root)
            self.assertIn("case 0x9b43:", seabios.read_text())


if __name__ == "__main__":
    unittest.main()
