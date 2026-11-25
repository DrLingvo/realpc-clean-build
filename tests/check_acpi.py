#!/usr/bin/env python3
"""Compile and inspect the injected ACPI tables; requires iasl and acpiexec."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, capture_output=True, **kwargs)


def main():
    if not shutil.which("iasl") or not shutil.which("acpiexec"):
        raise SystemExit("iasl and acpiexec are required")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        env = dict(os.environ)
        run(["bash", str(ROOT / "acpi" / "build-acpi.sh"), str(out)], env=env)
        for name in ("ssdt.aml", "ssdt-battery.aml", "wsmt.aml"):
            data = (out / name).read_bytes()
            assert len(data) >= 36 and struct.unpack_from("<I", data, 4)[0] == len(data)
            assert sum(data) & 0xFF == 0, f"bad checksum: {name}"
            assert data[28:32] == b"INTL", f"compiler mismatch: {name}"
        data = (out / "ssdt.aml").read_bytes()
        assert data[10:16] == b"ALASKA" and data[16:24] == b"A M I   "
        disassembly = run(["iasl", "-d", str(out / "ssdt.aml")]).stdout
        dsl = (out / "ssdt.dsl").read_text()
        for forbidden in ("Device (EC)", "Device (HPET)", "Device (PWRB)",
                          "Device (SLPB)", "Device (PIC0)", "Device (WMI0)",
                          "Device (WINB)", "WAET"):
            assert forbidden not in dsl, forbidden
        assert dsl.count("Device (HSEN)") == 1
        assert "0x0FF6" not in dsl
        result = run(["acpiexec", "-b", "quit", str(out / "ssdt.aml")], timeout=30)
        assert "ACPI Error" not in result.stdout + result.stderr
        assert not (out / "ssdt-ec.aml").exists()
        assert not (out / "hpet.aml").exists()
    print("ACPI checks passed: headers, checksums, namespace, iasl and acpiexec")


if __name__ == "__main__":
    main()
