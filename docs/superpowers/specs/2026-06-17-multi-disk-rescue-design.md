# Multi-Disk Rescue Design

## Goal

Make `hetzner-sno-prepare-pxe.sh` work better on Hetzner rescue hosts with multiple NVMe drives by keeping network discovery automatic and only requiring human input for disk selection when more than one install target is available.

## Context

Hetzner rescue access already depends on DHCP working well enough to obtain network connectivity and permit SSH login. Because of that, the prepare script can safely discover most runtime values from the live rescue environment instead of asking the operator to supply them.

The current implementation already auto-discovers:

- The default network interface from the default route
- The IPv4 address and prefix from that interface
- The default gateway from the default route
- DNS servers from `/etc/resolv.conf`
- The hostname from `hostname -f`
- The rendezvous IP from the detected node IP unless overridden

The remaining operator choice is the install disk when the host exposes more than one non-removable disk.

## Problem

`detect_install_disk()` currently auto-picks the root disk when `/` is backed by a block device and otherwise falls back to `lsblk` disk enumeration. When more than one candidate disk exists, the script exits with an error and requires `--disk-device`.

That behavior is safe, but it is awkward for common Hetzner layouts such as three similar NVMe drives:

- `--interactive` prompts for an install disk too early
- Leaving that prompt blank still leads to a later failure on multi-disk hosts
- The operator gets no guided disk picker
- The README examples suggest network flags that are usually unnecessary on rescue

## Decision

Keep network discovery fully automatic and improve only the multi-disk selection flow.

The prepare script will:

1. Continue auto-detecting network values from the live rescue host.
2. Continue auto-selecting the install disk when there is only one candidate.
3. Present a numbered disk menu when multiple candidate disks exist and prompting is possible.
4. Fail with a detailed candidate list when multiple disks exist but prompting is not possible, telling the operator to pass `--disk-device`.

The design does **not** add heuristics such as "largest empty disk" because they are risky on servers with multiple identical NVMe devices.

## Script Behavior

### Disk candidate listing

Add a helper that returns the current set of non-removable block devices that look like install targets. The helper should reuse the current `lsblk` filter so behavior stays conservative and predictable.

### Interactive selection

When multiple candidates exist and `can_prompt()` succeeds, the script should print a compact numbered table that includes:

- Device path
- Size
- Model, if available
- Serial, if available

The prompt should accept a numeric choice, loop on invalid input, and return the selected device path for normal downstream handling.

### Non-interactive failure mode

When prompting is not possible, the script should continue to fail rather than guess. The error output should include the candidate table so operators and automation can see exactly which devices were detected before rerunning with `--disk-device`.

### Prompt timing

Disk selection should happen during `resolve_install_disk()`, not during the early `prompt_for_missing_config()` pass. This avoids double-prompting and lets the resolved configuration summary show the final selected disk.

## Documentation Changes

Update `README.md` to reflect the rescue-first workflow:

- Add a short Hetzner rescue quick start
- Make the rescue dry-run example use only the cluster inputs plus `--disk-device` on multi-disk systems
- Keep manual network overrides as troubleshooting guidance rather than the primary example
- Document that interactive sessions can choose from a disk menu while automation should pass `--disk-device`

## Testing

Extend `tests/test-hetzner-sno-prepare-pxe.sh` with focused shell tests for:

- Multi-disk interactive selection
- Multi-disk non-interactive failure output
- Single-disk auto-selection
- Explicit `--disk-device` override behavior

The tests should continue using stubs so they do not install packages, write system paths, or invoke `kexec`.
