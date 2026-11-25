# Real-dump chipset identity map

`chipset-map.json` is intentionally empty until a physical-host dump is imported. PCI IDs are
not guessed from a CPU or board name, and there is no global `0x1b36 -> 0x8086` substitution.

On the physical host, collect:

```sh
lspci -D -vmmnn > lspci-vmmnn.txt
dmidecode -t baseboard -t processor > dmidecode-board.txt
```

Import the evidence:

```sh
python3 tools/chipset_map.py --lspci lspci-vmmnn.txt \
  --dmidecode dmidecode-board.txt --map profiles/chipset-map.json
```

The importer requires the host bridge, LPC/eSPI bridge, baseboard manufacturer/product and
processor socket. It stores numeric PCI identity, subsystem IDs and SHA-256 hashes of both input
dumps. Importing the same board/socket again replaces its record. Raw SMBIOS serial numbers are
not copied into the map.

When a generated board has a matching map record, `gen-profile.py` uses the observed LPC
subsystem vendor/device instead of inventing them. Merge the resulting `profile.env` into the
QEMU build configuration and explicitly enable `STRONG_SUBSYS_IDS=1` if those build-time
subsystem defaults are wanted. Unmapped profiles leave subsystem overrides absent.

This is **identity-only**. It does not turn Q35 into the physical chipset, import ACPI behavior,
or emulate device registers. Strong-real also removes virtual devices known to expose
`VEN_1B36`; the map must not be used to keep such devices by renumbering them. A host-dump import,
QEMU rebuild and guest PCI audit are required before the mapped identities can be called closed.
