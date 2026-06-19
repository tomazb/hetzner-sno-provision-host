# Stable install-disk hint via serial number

**Date:** 2026-06-19
**Status:** Approved design
**Component:** `hetzner-sno-prepare-pxe.sh`

## Problem

The generated `agent-config.yaml` records the install target as a raw kernel
device name:

```yaml
rootDeviceHints:
  deviceName: /dev/nvme1n1
```

NVMe kernel names (`nvme0n1`, `nvme1n1`, ...) are **not stable**. The kernel
assigns them by controller/PCIe probe order, which varies across boots and
across boot environments. The disk picker in `hetzner-sno-prepare-pxe.sh` runs
in one environment; the OpenShift Assisted Installer boots its own RHCOS live
image (from the generated ISO) with a different probe order; the final
installed system boots with yet another.

Because `rootDeviceHints.deviceName` does a literal `/dev/...` string match at
install time, the recorded name can resolve to a *different physical disk* than
the one the operator selected.

### Observed failure

Operator selected `[2] /dev/nvme1n1` (476.9G). At that moment the 953.9G disk
was `nvme0n1`. After install, `lsblk` showed the 953.9G disk as `nvme2n1` with
all partitions — the OS was installed on the wrong (largest) disk. Enumeration
shuffled between the picker environment and the installer environment, so
`nvme1n1` inside the installer pointed at the 953.9G disk.

## Root cause

Use of an unstable identifier (kernel device name) where a stable identifier
(disk serial) is required. The picker already reads the serial
(`format_disk_candidate_table`, via `lsblk -ndo SERIAL`) but the value is
displayed only, never written to the config.

Note: the two 476.9G disks share the model string `MZVL2512HCJQ`, so a
model-based hint cannot disambiguate them. Serial (or WWN) is required. We use
serial.

## Decision

Write `rootDeviceHints.serialNumber` (a stable, physical-device identifier)
instead of `deviceName`, derived from the serial of the selected disk.

## Design

### 1. Capture serial at the single resolve point

After `INSTALL_DISK` is resolved (currently `INSTALL_DISK="$(resolve_install_disk)"`),
look up the serial once and store it:

```sh
INSTALL_DISK_SERIAL="$(lsblk -ndo SERIAL "$INSTALL_DISK" 2>/dev/null | head -1 | awk '{$1=$1; print}')"
```

This covers both code paths — interactive/autodetect and the `--disk-device`
override — because both converge on `INSTALL_DISK`.

### 2. Config writer selects the hint field by serial presence

In the `python3` heredoc that writes `agent-config.yaml`, pass
`HSP_INSTALL_DISK_SERIAL` alongside the existing `HSP_INSTALL_DISK`, and branch:

- **Serial non-empty** → write:
  ```
      rootDeviceHints:
        serialNumber: "<serial>"
  ```
- **Serial empty** (rare: some virtio/loop devices expose no serial) → fall
  back to the previous behaviour:
  ```
      rootDeviceHints:
        deviceName: "<path>"
  ```
  and emit a warning to stderr that the install target uses an unstable device
  name. Honest degradation — never silently rely on the unstable name without
  flagging it.

Values are JSON-quoted via the existing `q()` helper.

### 3. Resolved-configuration display

Add a line to the resolved-config summary so the operator confirms the
*physical* disk, not just the volatile name:

```
  Install disk:        /dev/nvme1n1
  Install disk serial: S63CNF0X212059
```

When serial is empty, show `Install disk serial: (none — using device name)`.

### 4. Replay command

Keep emitting `--disk-device <path>` in the printed replay command (the CLI
flag remains name-based; step 1 re-derives the serial automatically on replay).
Append a trailing comment noting that the device name is point-in-time and the
serial is the authoritative identifier.

### 5. Tests

In `tests/test-hetzner-sno-prepare-pxe.sh`, add two cases by mocking `lsblk`:

- **Serial present:** generated `agent-config.yaml` contains a `serialNumber:`
  line with the mocked serial and contains **no** `deviceName:` line.
- **Serial absent:** generated config falls back to a `deviceName:` line.

## Out of scope

- WWN / `by-id` path support (serial is sufficient and unambiguous here).
- Changing the `--disk-device` CLI flag to accept a serial.
- Any change to `hetzner-sno-provision-host-agentbased.sh` (separate script).

## Affected code

- `hetzner-sno-prepare-pxe.sh`
  - resolve point (~`:1337`) — capture `INSTALL_DISK_SERIAL`
  - heredoc env (~`:1131`) — export `HSP_INSTALL_DISK_SERIAL`
  - config writer (~`:1156-1157`) — branch serial vs name
  - resolved-config display (~`:1246`) — add serial line
  - replay command (~`:1278`) — add authoritative-serial comment
- `tests/test-hetzner-sno-prepare-pxe.sh` — two new cases
