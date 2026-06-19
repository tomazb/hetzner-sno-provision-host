# Design: Deterministic disk selection on replay via `--disk-serial`

Date: 2026-06-19
Status: Approved
Follows: [2026-06-19-stable-disk-hint-design.md](2026-06-19-stable-disk-hint-design.md)

## Problem

The stable-disk-hint work (PR #6) pins the generated AgentConfig
`rootDeviceHints` by `serialNumber`, which correctly survives NVMe kernel-name
reordering across reboots. However, the **replay command** the script prints is
not serial-deterministic:

- Replay emits only `--disk-device /dev/nvme0n1` (a point-in-time kernel name).
  No `--disk-serial` flag exists.
- On a `--yes` non-interactive replay, `resolve_install_disk` normalizes the
  given device path, then `INSTALL_DISK_SERIAL` is **re-derived** from whatever
  physical disk holds that kernel name at the next boot.
- NVMe names reorder across boots — the exact failure serial-pinning was meant
  to eliminate. An unattended replay can therefore pin the AgentConfig to the
  **wrong disk**.
- The printed NOTE ("The install target is pinned by serial S63CNF0X212063") is
  misleading: the replay command carries no serial, so replaying it does not
  actually pin by that serial.

## Goal

Make replay select the install disk deterministically by serial, independent of
kernel device naming. Never silently install to an unintended disk.

## Non-goals

- No change to autodetection logic or the interactive multi-disk selection flow
  beyond surfacing the chosen serial (the candidate table already shows serial).
- No change to the AgentConfig `rootDeviceHints` emission (already correct).

## Design

### 1. CLI

Add `--disk-serial <serial>` setting `DISK_SERIAL_OVERRIDE`.

- `--disk-device` remains supported as a hint/fallback selector and is still
  usable standalone (unchanged behavior when `--disk-serial` is absent).
- Usage text documents `--disk-serial` as the stable, replay-safe selector, with
  an example invocation.

### 2. Resolution precedence (`resolve_install_disk`)

Order: `--disk-serial` → `--disk-device` → autodetect.

New helper `find_disk_by_serial <serial>`:

- Enumerates disks with `lsblk -dnpo NAME,SERIAL`, matching on the trimmed
  serial (same trimming convention used elsewhere in the script).
- No match → `die` with a clear error that lists the present disks and their
  serials, so the operator can correct the invocation.
- Multiple matches (rare; duplicate/blank serials) → `die` with an ambiguity
  error.

Conflict handling: if both `--disk-serial` and `--disk-device` are supplied,
serial wins; emit a warning that the device argument is ignored.

### 3. Serial capture

- Resolved via serial: `INSTALL_DISK_SERIAL` is the supplied override
  (authoritative — not re-derived). `INSTALL_DISK` is the matched kernel name,
  used only for logging and the replay NOTE.
- Resolved via device or autodetect: existing re-derive behavior is unchanged.

### 4. Replay output

- When a serial is known: emit `--disk-serial <serial>` as the active pin and
  **drop** `--disk-device` from the printed command. The NOTE remains,
  explaining that the kernel name was point-in-time and the target is the
  serial.
- When no serial is known: output is unchanged (`--disk-device`, no NOTE).

### 5. Error handling

- Serial not found / ambiguous: hard `die` (no fallback). This guarantees an
  unattended replay never installs to an unintended disk; the operator re-runs
  after correcting the serial or hardware state.

## Testing

Bash test suite in `tests/`:

1. `--disk-serial` resolves to the correct device when present.
2. `--disk-serial` with no matching disk → non-zero exit, error lists present
   serials.
3. Ambiguous serial (two disks match) → non-zero exit, ambiguity error.
4. Precedence: `--disk-serial` + `--disk-device` → serial-selected disk wins,
   warning emitted.
5. Replay command for a serial-pinned run emits `--disk-serial` and omits
   `--disk-device`.
6. No-serial path (device/autodetect) replay output unchanged.

## Documentation

README / usage: document `--disk-serial` and note it is the stable,
replay-safe selector that survives NVMe kernel-name reordering.
