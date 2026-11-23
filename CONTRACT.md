# Proxmox host-tools configuration contract v1

This contract coordinates `realpc-clean-build` and `pve-intel-gpu` when both
projects manage the same VM.

## Locking

Every modifying operation takes the shared exclusive lock
`/run/lock/pve-host-tools.lock`. A tool waits at most 60 seconds and fails
without changing configuration when the lock cannot be acquired.

## Main configuration and snapshots

Only the main VM section before the first `[snapshot]` section may be changed.
Snapshot sections are never rewritten. `update` does not change VM
configurations; `configvm` is a separate explicit operation.

## Arguments

Fragments live in `/etc/pve-host-tools/args.d/<vmid>/NN-<tool>.args`.
`pve-intel-gpu` uses `50-pve-intel-gpu.args`.

realpc rebuilds its main `args:` value and then appends every fragment in
filename order. A fragment contains one line of QEMU arguments. Repeated
application is idempotent and does not duplicate fragment arguments.

Ownership is limited to the following settings:

- realpc: `machine`, `bios`, `localtime`, `tablet`, its base `args:` value,
  and normally `vga`;
- pve-intel-gpu: its `hostpciN` entries and corresponding
  `-set device.hostpciN.*` arguments for host devices `00:02.x` and `00:1f.3`.

realpc does not change those vGPU-owned entries. When a main-section
`hostpciN` entry contains host `00:02.0`, realpc leaves `vga` unchanged;
full IGD passthrough requires `vga: none`. Ordinary realpc VMs use a
non-VMware VGA adapter by default.

## State and rollback

Each tool writes `CONTRACT_VERSION=1` in its own state. realpc state is
`/root/realpc/.realpc-state`; vGPU state is `/var/lib/pve-intel-gpu/state`.

A full VM-config rollback is allowed only while the configuration hash still
matches the hash recorded after that tool's own write. If another tool has
changed the file, rollback restores only realpc-owned keys and preserves the
current fragments, vGPU `hostpciN` entries, and snapshot sections.
