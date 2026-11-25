#!/usr/bin/env python3
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tests" / "guest_audit.ps1"


class GuestAuditTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = SCRIPT.read_bytes()
        cls.text = cls.data.decode("ascii")

    def test_script_is_operational_ascii_and_has_no_auto_download(self):
        self.assertIn("#requires -Version 5.1", self.text)
        self.assertIn("Set-StrictMode -Version Latest", self.text)
        self.assertNotIn("Invoke-WebRequest", self.text)
        self.assertNotIn("DownloadFile", self.text)
        self.assertNotIn("qemu-guest-agent", self.text.lower())

    def test_required_raw_evidence_sources_are_collected(self):
        for marker in (
            "Win32_PnPEntity", "VEN_1B36", "Win32_PhysicalMemory",
            "Win32_PhysicalMemoryArray", "Win32_MemoryDevice", "Win32_MemoryArray",
            "Win32_MemoryDeviceArray", "Win32_Service", "Win32_SystemDriver",
            "Get-StringEvidence", "acpi-string-hits.json", "al-khaser-full",
            "ReadToEndAsync", "RedirectStandardError", "summary.json",
        ):
            self.assertIn(marker, self.text)

    def test_missing_or_failed_probes_are_never_passes(self):
        for probe in ("CpuIdProbePath", "RdMsrProbePath", "PmuProbePath", "AlKhaserPath"):
            self.assertIn(probe, self.text)
        self.assertIn("0x4b564d00 through 0x4b564d08", self.text)
        self.assertIn('status = "NOT_TESTED"', self.text)
        self.assertIn('status = "TIMEOUT"', self.text)
        self.assertIn('status = "ERROR"', self.text)
        self.assertIn("NOT_TESTED, ERROR, and TIMEOUT are never passes", self.text)
        self.assertIn('Where-Object { $_.status -ne "COLLECTED" }', self.text)
        self.assertIn('else { "PARTIAL" }', self.text)

    def test_real_input_is_required_during_detector_run(self):
        self.assertIn("Move the real mouse and use the real keyboard", self.text)
        self.assertIn("Real mouse movement and keyboard input are required", self.text)

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell parser is unavailable")
    def test_powershell_parser_accepts_script(self):
        expression = (
            "$tokens=$null; $errors=$null; "
            "[System.Management.Automation.Language.Parser]::ParseFile("
            f"'{SCRIPT}', [ref]$tokens, [ref]$errors) | Out-Null; "
            "if ($errors.Count) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }"
        )
        subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", expression],
                       check=True, capture_output=True, text=True, timeout=60)


if __name__ == "__main__":
    unittest.main()
