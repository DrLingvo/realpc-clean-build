from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PrebuiltKvmRecipeTests(unittest.TestCase):
    def read(self, name):
        return (ROOT / name).read_text(encoding="utf-8")

    def test_installer_offers_two_explicit_strong_paths(self):
        setup = self.read("deploy/realpc-setup.sh")
        self.assertIn('CFG_KVM_BUILD=0', setup)
        self.assertIn('--kvm-prebuilt) KVM_BUILD=0', setup)
        self.assertIn('--kvm-build) KVM_BUILD=1', setup)
        self.assertIn('KVM_BUILD=1; shift 2', setup)
        self.assertIn('if [[ "$KVM_BUILD" == 1 ]]; then build_install_module; else prebuilt_install_module; fi', setup)
        self.assertIn('if [[ "$KVM_BUILD" == 1 ]]; then\n    local free;', setup)

    def test_prebuilt_identity_is_fail_closed(self):
        setup = self.read("deploy/realpc-setup.sh")
        for marker in (
            'REALPC_CONFIG_SHA256',
            'REALPC_MODULE_SYMVERS_SHA256',
            'REALPC_MODULE_SHA256',
            'REALPC_VERMAGIC',
            'use --kvm-build',
            'rerun with --kvm-build',
        ):
            self.assertIn(marker, setup)
        self.assertIn('[[ "$new_vm" == "$current_vm" ]]', setup)
        self.assertIn('verify_prebuilt_module "$WORKDIR/$kvm_asset" "$WORKDIR/$kvm_info"', setup)

    def test_ci_pins_signed_kernel_packages_and_host_abi_hashes(self):
        ci = self.read("ci/container-kvm.sh")
        self.assertIn('KREL=7.0.14-6-pve', ci)
        self.assertIn('PKGVER=7.0.14-6', ci)
        self.assertIn('EXPECTED_CONFIG_SHA256=d7d7c2ae6b96aa04adfc16b1262269a951a0dd33a945eab4cf2fa6937469e5f7', ci)
        self.assertIn('EXPECTED_SYMVERS_SHA256=0e39472916fa6286519fe1c8cd39740535f31140a1145e16f0e07fd62ed87f9d', ci)
        self.assertIn('Signed-By: $keyring', ci)
        self.assertIn('proxmox-archive-keyring-trixie.gpg', ci)
        self.assertIn('136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45', ci)
        self.assertIn('proxmox-kernel-$KREL=$PKGVER', ci)
        self.assertIn('proxmox-headers-$KREL=$PKGVER', ci)
        self.assertIn('REALPC_FORCE_GIT=1', ci)

    def test_build_produces_and_uploads_the_prebuilt_module(self):
        build = self.read(".github/workflows/build.yml")
        self.assertNotIn("- 'kernel/**'", build)
        self.assertIn('name: out-kvm', build)
        self.assertIn('debian:trixie bash ci/container-kvm.sh', build)
        self.assertIn('out/kvm-*.ko', build)
        self.assertIn('out/kvm-*.modinfo', build)
        self.assertIn('sha256sum -c SHA256SUMS.kvm', build)

    def test_release_requires_matching_prebuilt_assets(self):
        release = self.read(".github/workflows/release.yml")
        self.assertIn('kvm=(dist/kvm-*.ko)', release)
        self.assertIn('kvm_info=(dist/kvm-*.modinfo)', release)
        self.assertIn('Expected exactly one prebuilt KVM module', release)
        self.assertIn('"${kvm[@]}" "${kvm_info[@]}"', release)
        self.assertIn('Kernel recipes differ; prebuilt KVM reuse is forbidden', release)
        self.assertIn('KVM-RECIPE-SHA256', release)

    def test_kernel_builder_supports_ci_without_changing_host_default(self):
        build = self.read("kernel/build-kvm.sh")
        self.assertIn('KREL=${KREL:-$(uname -r)}', build)
        self.assertIn('KERNEL_CONFIG', build)
        self.assertIn('MODULE_SYMVERS', build)
        self.assertIn('d4439e71d7865ecaa01a48033f96ff8ac1df16f8', build)
        self.assertIn('660d1f05673c4e02cc3c2c056afc0dc14c0075f0', build)
        recipe = self.read("tools/source-hash.sh")
        self.assertIn('ci/container-(build|kvm)', recipe)


if __name__ == '__main__':
    unittest.main()
