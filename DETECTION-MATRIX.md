# Strong-real v1 detection matrix

This matrix records evidence, not promises. `CLOSED` applies only to the stated
scope and proof layer. It does not mean that a VM is indistinguishable from
physical hardware.

## Status meanings

- **CLOSED**: the stated check is implemented and its required machine proof has
  passed at the stated layer.
- **PARTIAL**: source or fixture checks exist, but a required qtest, firmware,
  real-host, or guest result is still missing.
- **KNOWN**: a residual detection surface or architectural limitation remains.
  It must be reported rather than renamed as a pass.

`NOT_TESTED`, `ERROR`, `TIMEOUT`, and an unavailable PMU are not passes. A clean
Al-Khaser run without real mouse/keyboard input is not valid behavioral evidence.

## R1-R14 implementation and proof

| Item | Status | Implemented control and existing proof | Evidence still required or remaining limit |
|---|---|---|---|
| R1 disk identity | PARTIAL | `tools/disk_identity.py` derives deterministic per-VM/per-disk vendor, model, serial, firmware, WWN, and exact SKU LBA capacity. `tests/test_disk_identity.py` and `tests/test_vm_config.py` pass. SATA properties are shell-quoted as one QEMU argument. | Read ATA IDENTIFY and LBA capacity in the guest for every disk. No full SMART-table emulation is claimed. |
| R2 ACPI | PARTIAL | Fake desktop EC, duplicate HPET, WAET, and duplicate namespace objects are removed; HPET OEM and compiler data are patched. `tests/check_acpi.py` covers checksums, iasl disassembly, namespace rules, and acpiexec. | Run the updated full qtest and inspect Windows ACPI dumps/strings. Laptop battery/EC behavior is not guest-proven. |
| R3 host CPU identity | PARTIAL | Strong-real defaults to `-cpu host`; type 4 version equals the exact host model and arbitrary SKU input is rejected. Profile and VM-config fixtures pass. | Compare guest CPUID brand, `Win32_Processor`, and SMBIOS type 4 on the real host. |
| R4 network identity | PARTIAL | `net0` becomes `e1000e` with the profile MAC; Proxmox/QEMU OUIs are rejected. Type 41 references `net0`; linter and corruption tests pass. | Verify the guest MAC, type 41 BDF, and driver. The gateway and other network observers still see the VM MAC. |
| R5 device hygiene | PARTIAL | Agent, balloon, and tablet are disabled; disks are SATA; VirtIO, SPICE, QEMU XHCI, pvpanic, and PCIe-PCI bridges are rejected. qtest now scans bus 0 for `VEN_1B36`. | The new qtest has not run on branch-built packages. Windows PNP and Al-Khaser results are not yet available, so `VEN_1B36` is not closed. |
| R6 KVM CPUID/MSR | PARTIAL | KVM PV signature/feature leaves and CPUID.1 hypervisor bit are cleared during vCPU configuration. RDMSR `0x4b564d00-0x4b564d08` returns `#GP`. Injector, atomicity, idempotence, and setup tests pass. | Build/install the exact-host module and collect guest CPUID plus kernel-backed RDMSR results. No timing-path change was made. |
| R7 real PMU | PARTIAL | `tests/guest_pmu.c` uses real `perf_event_open` cycles and instructions at two workloads; synthetic values are forbidden. Strict compilation passes. | The sandbox reported no architectural PMU. A meaningful load-dependent PASS is still required in the target guest. |
| R8 chipset identities | PARTIAL | `tools/chipset_map.py` imports only real per-board/socket PCI dumps with evidence hashes. Blind global vendor substitutions were removed. Fixture and fail-closed tests pass. | Import the actual host dumps and rebuild/audit. The shipped map is empty. This mechanism changes identity only, not chipset behavior. |
| R9 topology and caches | PARTIAL | Host sockets/cores/threads and cache geometry are observed with `lscpu`; per-VM type 7 binaries are generated. `profile.conf`, CPUID.4/type 7 linkage, and `vmware-cpuid-freq=false` are covered by fixtures/lint. | Validate CPUID.4, CPUID `0x15/0x16`, cache size/ways, and topology in the guest. TSC pinning and timing behavior remain unchanged. |
| R10 SMBIOS coherence | PARTIAL | Board-specific BIOS records, distinct serials/assets, synchronized UUIDs, per-DIMM values, type 41, and chassis-specific type 22/type 39 records are implemented. Binary layout and patch tests pass. | Run the new qtest and guest WMI/CIM audit. Desktop PSU probes are absent (`0xFFFF`), not fabricated. Laptop records remain unproven. |
| R11 optional re-skins | PARTIAL | Host-bridge/fw_cfg re-skins are default-off and coordinated across QEMU, OVMF, SeaBIOS, and option ROMs. Isolated patcher fixtures pass; baseline SeaBIOS again rejects a bad signature. | OVMF and SeaBIOS boot tests are mandatory before either option can be marked closed. No such boot test has run on this branch. |
| R12 consistency and CI | PARTIAL | `tools/consistency_lint.py` fails before the main VM section is written. Valid configurations pass; UUID, MAC/OUI, topology, and cache corruption fail. Setup, the Python suite, strict timing build, and recipe coverage pass locally. | Full branch-built QEMU/EDK2 qtest and guest CI evidence remain pending. |
| R13 Windows audit | PARTIAL | `tests/guest_audit.ps1` collects raw PNP, memory WMI/CIM, services/drivers, ACPI strings, optional CPUID/RDMSR/PMU probes, and complete Al-Khaser output. Static regression tests pass and missing probes become `NOT_TESTED`. | Run on the clean activated Windows guest. The PowerShell SDK parser accepted the script with zero errors; no Windows detector run has occurred. |
| R14 matrix | CLOSED | This document names the proof layer, pending evidence, and known residuals without claiming complete invisibility. | Keep statuses tied to retained raw logs and update them after each verified run. |

## Known residual detection surfaces

| Surface | Status | Current interpretation and required evidence |
|---|---|---|
| Median CPUID/VM-exit latency | KNOWN | KVM still exits on CPUID. The established timing/jitter implementation is unchanged; jitter cannot remove the median VM-exit signal. Run the complete timing suite and treat incomplete results as errors. |
| Mouse movement and lack of user input | KNOWN | Behavioral checks remain detectable without genuine activity. Use real mouse and keyboard input during detector tests; synthetic counters or fabricated input results are invalid. |
| Gateway/network observation | KNOWN | Changing the guest MAC does not hide the VM's traffic or MAC from the gateway, bridge, switch, or other network observers. |
| Windows memory and ACPI pinpointing | KNOWN | `Win32_MemoryDevice`, memory WMI/CIM classes, and ACPI strings remain explicit audit watch items. No current-branch Windows evidence establishes that every residual is gone. |
| `VEN_1B36` and virtual drivers/services | PARTIAL | The configuration and qtest are designed to reject them, but only a branch-built qtest plus Windows PNP/driver/service evidence can close this item. |
| Default firmware identity | KNOWN | The R11 fw_cfg and host-bridge re-skins are optional and default-off. Baseline identity must not be described as re-skinned, and enabling an option without both firmware boot tests is invalid. |
| Full SMART behavior | KNOWN | Coherent ATA identity and exact capacity do not implement a complete physical-drive SMART data set. |
| Secure Boot and TPM | KNOWN | Strong requires Secure Boot disabled for the host-side module workflow. Secure Boot/TPM concealment is outside Strong-real v1 scope. |
| Complete VM invisibility | KNOWN | Not claimed. Identity coherence cannot eliminate hypervisor timing, behavioral, network, and all platform-level signals. |

## Proof commands and retained artifacts

Run fast checks from the repository root:

```bash
python3 -m unittest discover -v -s tests -p 'test_*.py'
python3 -m unittest -v tests/timing_tests/test_analyze.py
bash tests/test_setup.sh
make -C tests/timing_tests clean
make -C tests/timing_tests -j2 \
  CFLAGS='-O2 -Wall -Wextra -Werror -std=gnu11 -Icommon'
```

With ACPICA installed:

```bash
python3 tests/check_acpi.py
```

After the QEMU and EDK2 artifacts from this exact branch have built successfully,
`.github/workflows/test.yml` runs `ci/container-test.sh`. That path generates a
Strong-real profile, runs the consistency linter, dumps fw_cfg and PCI through
qtest, and checks ACPI/SMBIOS/type 41/DIMM/PCI invariants. A static review of this
script is not a substitute for the run.

Import physical-host chipset evidence before claiming a mapped board:

```bash
lspci -D -vmmnn > lspci-vmmnn.txt
dmidecode -t baseboard -t processor > dmidecode-board.txt
python3 tools/chipset_map.py --lspci lspci-vmmnn.txt \
  --dmidecode dmidecode-board.txt --map profiles/chipset-map.json
```

On the clean, activated Windows guest, retain the entire output directory:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\guest_audit.ps1 `
  -OutputDirectory .\realpc-audit `
  -AlKhaserPath C:\Tools\al-khaser.exe `
  -CpuIdProbePath C:\Tools\cpuid-probe.exe `
  -RdMsrProbePath C:\Tools\rdmsr-probe.exe `
  -PmuProbePath C:\Tools\pmu-probe.exe `
  -AcpiDumpPath C:\Tools\acpidump.exe `
  -AcpiTableDirectory C:\Tools\acpi-tables
```

The probe paths are placeholders for trusted tools, not bundled implementations.
The RDMSR probe must be kernel-backed and report actual `#GP` outcomes. The PMU
probe must measure real load-dependent hardware events. Move the real mouse and
use the real keyboard during Al-Khaser. Preserve `summary.json`, all raw output,
exit codes, the Al-Khaser report, and a clean activated VM snapshot. Any omitted
probe leaves the corresponding item unproven.
