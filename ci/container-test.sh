#!/bin/bash
# Runs inside a stock debian:trixie container: installs the freshly built packages
# (dependencies from the official Proxmox repo) and runs tests/check.py.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cd "$here/.."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg python3 python3-pip
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
if [ -f ci/proxmox-archive-keyring.gpg ]; then install -m 0644 ci/proxmox-archive-keyring.gpg "$KEYRING"
else curl -fsSL -o "$KEYRING" https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg; fi
cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: $KEYRING
EOF
apt-get update

echo "=== artifacts"; ls -la out; (cd out && for f in SHA256SUMS*; do sha256sum -c "$f" --ignore-missing; done)
apt-get install -y --no-install-recommends ./out/pve-qemu-kvm_*_amd64.deb ./out/pve-edk2-firmware-ovmf_*_all.deb
dpkg -l pve-qemu-kvm pve-edk2-firmware-ovmf | tail -2
qemu-system-x86_64 --version
qemu-system-x86_64 -device help | grep -F 'host-sensors'

echo "=== generated Strong-real profile"
qtest_profile=/tmp/realpc-qtest-profile
python3 tools/gen-profile.py --platform intel_desktop_lga1200 \
  --host-vendor intel --host-cpu-model 'Test CPU' --socket LGA1200 \
  --seed 42 --vmid 100 --out "$qtest_profile"
cat > /tmp/realpc-qtest-input.conf <<'CFG'
memory: 32768
net0: e1000e=02:F0:5D:01:02:03,bridge=vmbr0
CFG
python3 tools/vm-config.py --config /tmp/realpc-qtest-input.conf \
  --profile "$qtest_profile/profile.json" --acpi-dir "$(pwd)/out" \
  --out /tmp/realpc-qtest.conf
python3 tools/consistency_lint.py --config /tmp/realpc-qtest.conf \
  --profile "$qtest_profile/profile.json"
python3 -I - /tmp/realpc-qtest.conf > /tmp/realpc-qtest-args <<'PY'
import shlex, sys
lines = open(sys.argv[1]).read().splitlines()
args = shlex.split(next(line[6:] for line in lines if line.startswith("args: ")))
index = args.index("-cpu") + 1
assert args[index].startswith("host,")
args[index] = "max," + args[index][5:]
for arg in args:
    print(arg)
PY
mapfile -t vm_args < /tmp/realpc-qtest-args
python3 -I - "$qtest_profile/profile.json" > /tmp/realpc-qtest-identity <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))["summary"]
topology = profile["topology"]
print(profile["mac"])
print(topology["sockets"] * topology["cores"] * topology["threads"])
PY
mapfile -t qtest_identity < /tmp/realpc-qtest-identity

echo "=== fw_cfg and PCI dump (qtest, no guest code)"
python3 -I tests/fwcfg_dump.py /tmp/fw -- qemu-system-x86_64 -accel qtest -machine q35 \
  -m 32768 -smp "${qtest_identity[1]}" -display none -nodefaults -qtest stdio \
  "${vm_args[@]}" -device "e1000e,id=net0,mac=${qtest_identity[0]}"

echo "=== host sensor I/O registers"
python3 -I tests/qtest_sensors.py -- qemu-system-x86_64 -accel qtest -machine q35 -m 1024 \
  -display none -nodefaults -qtest stdio -device host-sensors

echo "=== OVMF extract"
pip install --break-system-packages -q uefi_firmware
mkdir -p /tmp/ovmf && cp /usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd /tmp/ovmf/
uefi-firmware-parser --brute -e -O /tmp/ovmf/OVMF_CODE_4M.fd | tail -3
find /tmp/ovmf -name "*.pe" | wc -l

echo "=== checks"
python3 -I tests/check.py /tmp/fw /tmp/ovmf/OVMF_CODE_4M.fd_output /usr/bin/qemu-system-x86_64
