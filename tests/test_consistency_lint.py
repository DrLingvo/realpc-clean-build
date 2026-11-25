#!/usr/bin/env python3
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

GEN = load("gen_profile", ROOT / "tools" / "gen-profile.py")
VM = load("vm_config", ROOT / "tools" / "vm-config.py")
SMBIOS = load("smbios_tables", ROOT / "tools" / "smbios_tables.py")
LINT = load("consistency_lint", ROOT / "tools" / "consistency_lint.py")


class ConsistencyLintTest(unittest.TestCase):
    def make_config(self, directory):
        env, args, summary, _, _ = GEN.gen(
            "intel_desktop_lga1200", "neutral", 1, host_vendor="intel",
            host_cpu_model="Intel Host CPU")
        summary["vmid"] = "100"
        profile = {"summary": summary, "args": args, "env": env}
        SMBIOS.write_profile_records(profile, directory)
        acpi = Path(directory) / "acpi"
        acpi.mkdir()
        for name in ("ssdt.aml", "wsmt.aml"):
            (acpi / name).write_bytes(name.encode())
        config = """memory: 16384
net0: virtio=02:F0:5D:01:02:03,bridge=vmbr0
virtio0: local:100/vm-100-disk-0.qcow2
[snapshot]
args: unchanged
"""
        text = VM.render(config, profile, {"virtio0": 500107862016}, str(acpi))
        return text, profile

    def test_complete_configuration_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            text, profile = self.make_config(tmp)
            self.assertEqual(LINT.lint(text, profile), [])

    def test_cross_layer_corruption_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            text, profile = self.make_config(tmp)
            bad = text.replace("smbios1: uuid=" + profile["summary"]["uuid"],
                               "smbios1: uuid=00000000-0000-0000-0000-000000000000")
            self.assertTrue(any("UUID" in error for error in LINT.lint(bad, profile)))
            bad = text.replace("e1000e,bridge", "e1000e,bridge").replace(
                "mac=" + profile["summary"]["mac"], "mac=52:54:00:01:02:03")
            self.assertTrue(any("MAC" in error or "OUI" in error for error in LINT.lint(bad, profile)))
            bad = text.replace("cores: " + str(profile["summary"]["topology"]["cores"]), "cores: 1")
            self.assertTrue(any("topology" in error for error in LINT.lint(bad, profile)))
            cache_path = profile["summary"]["smbios_files"][0]
            bad = text.replace(" -smbios file=" + cache_path, "")
            self.assertTrue(any("type 7" in error for error in LINT.lint(bad, profile)))


if __name__ == "__main__":
    unittest.main()
