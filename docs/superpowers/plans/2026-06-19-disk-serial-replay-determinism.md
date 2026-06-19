# Deterministic Disk Selection on Replay (`--disk-serial`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--disk-serial` flag so unattended `--yes` replays select the install disk by serial, immune to NVMe kernel-name reordering across reboots.

**Architecture:** Extend the existing single-file Bash script `hetzner-sno-prepare-pxe.sh`. Add a serial→device resolver, give `--disk-serial` top precedence in `resolve_install_disk`, make the captured serial authoritative when supplied, and have `print_replay_command` emit `--disk-serial` (dropping `--disk-device`) whenever a serial is known. Hard-fail (`die`) when a supplied serial matches zero or multiple present disks.

**Tech Stack:** Bash, `lsblk`, `awk`. Tests are plain Bash in `tests/`, sourcing the script with `HSPPXE_TEST_MODE=1` and stubbing `lsblk` via `PATH`.

## Global Constraints

- Single-file script: all logic in `hetzner-sno-prepare-pxe.sh`. No new files except tests/docs.
- Script runs under `set -euo pipefail`; reference possibly-unset new globals as `${DISK_SERIAL_OVERRIDE:-}`.
- No silent fallback: a supplied serial that does not match exactly one present disk must `die`.
- Follow existing style: `die` for fatal errors, `>&2` for warnings, `printf '%q'` for replay quoting, `awk` whitespace-trim idiom already used in the script.
- Tests follow the existing pattern: `mktemp -d` stub dir, stub `lsblk`, `PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c 'source "<script>"; ...'`, register with `run_test`.

---

### Task 1: Add `--disk-serial` CLI flag and usage

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (`parse_args` init near line 223 and its arg `case`; `print_usage` near lines 197 and 214)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: global `DISK_SERIAL_OVERRIDE` (string, empty when unset), set by parsing `--disk-serial <serial>`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-hetzner-sno-prepare-pxe.sh` (place near the existing `parse_args` tests, before the `run_test` registrations near line 581):

```bash
test_parse_args_sets_disk_serial_override() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    parse_args --disk-serial S63CNF0X212063 4.16.15 /tmp/pull-secret.json example.com sno 192.0.2.10
    [[ "${DISK_SERIAL_OVERRIDE}" == "S63CNF0X212063" ]]
  '
}
```

Register it alongside the other `run_test` lines:

```bash
run_test "parse_args sets disk serial override" test_parse_args_sets_disk_serial_override
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: `not ok - parse_args sets disk serial override` (DISK_SERIAL_OVERRIDE unbound or empty).

- [ ] **Step 3: Add the global initializer and arg case**

In `parse_args`, beside the existing `DISK_DEVICE_OVERRIDE=""` initializer (near line 223), add:

```bash
  DISK_SERIAL_OVERRIDE=""
```

In the `while`/`case` arg loop, beside the existing `--disk-device)` case (near line 237), add:

```bash
      --disk-serial)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --disk-serial requires a serial number." >&2
          print_usage
          return 1
        fi
        DISK_SERIAL_OVERRIDE="$2"
        shift 2
        ;;
```

- [ ] **Step 4: Update `print_usage`**

In the options block (after the `--disk-device` line near line 197), add:

```text
  --disk-serial <serial>     Pin install disk by serial; replay-safe across reboots
```

In the examples block (after the `--disk-device` example near line 214), add:

```bash
  ${SCRIPT_NAME} --disk-serial S63CNF0X212063 4.22.1 /root/pull-secret.json example.com sno
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: `ok - parse_args sets disk serial override`, no other test regresses.

- [ ] **Step 6: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Add --disk-serial CLI flag and usage"
```

---

### Task 2: Serial→device resolver and resolution precedence

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (add `find_disk_by_serial`; rewrite `resolve_install_disk` near lines 778-784)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `DISK_SERIAL_OVERRIDE`, `DISK_DEVICE_OVERRIDE` (globals); `normalize_disk_device`, `detect_install_disk`, `die` (existing functions).
- Produces:
  - `find_disk_by_serial <serial>` → prints the matching `/dev/...` disk path on stdout; `die`s (non-zero) on zero or multiple matches.
  - `resolve_install_disk` precedence: `--disk-serial` → `--disk-device` → autodetect; warns to stderr when both serial and device are supplied.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-hetzner-sno-prepare-pxe.sh`:

```bash
test_find_disk_by_serial_resolves_device() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  *"NAME,SERIAL"*)
    printf '/dev/nvme0n1 S63CNF0X212059\n'
    printf '/dev/nvme1n1 S63CNF0X212063\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${stub_dir}/lsblk"
  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    [[ "$(find_disk_by_serial S63CNF0X212063)" == "/dev/nvme1n1" ]]
  '
  status=$?
  rm -rf "${stub_dir}"
  return "${status}"
}

test_find_disk_by_serial_dies_when_absent() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  *"NAME,SERIAL"*)
    printf '/dev/nvme0n1 S63CNF0X212059\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${stub_dir}/lsblk"
  if PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    find_disk_by_serial NO_SUCH_SERIAL
  ' 2>/dev/null; then
    status=1
  else
    status=0
  fi
  rm -rf "${stub_dir}"
  return "${status}"
}

test_find_disk_by_serial_dies_when_ambiguous() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  *"NAME,SERIAL"*)
    printf '/dev/nvme0n1 DUP_SERIAL\n'
    printf '/dev/nvme1n1 DUP_SERIAL\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${stub_dir}/lsblk"
  if PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    find_disk_by_serial DUP_SERIAL
  ' 2>/dev/null; then
    status=1
  else
    status=0
  fi
  rm -rf "${stub_dir}"
  return "${status}"
}

test_resolve_install_disk_prefers_serial_over_device() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  *"NAME,SERIAL"*)
    printf '/dev/nvme0n1 S63CNF0X212059\n'
    printf '/dev/nvme1n1 S63CNF0X212063\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${stub_dir}/lsblk"
  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DISK_SERIAL_OVERRIDE="S63CNF0X212063"
    DISK_DEVICE_OVERRIDE="/dev/nvme0n1"
    [[ "$(resolve_install_disk 2>/dev/null)" == "/dev/nvme1n1" ]]
  '
  status=$?
  rm -rf "${stub_dir}"
  return "${status}"
}
```

Register them:

```bash
run_test "find_disk_by_serial resolves device" test_find_disk_by_serial_resolves_device
run_test "find_disk_by_serial dies when absent" test_find_disk_by_serial_dies_when_absent
run_test "find_disk_by_serial dies when ambiguous" test_find_disk_by_serial_dies_when_ambiguous
run_test "resolve_install_disk prefers serial over device" test_resolve_install_disk_prefers_serial_over_device
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: the four new tests report `not ok` (`find_disk_by_serial` not defined; serial branch absent).

- [ ] **Step 3: Add `find_disk_by_serial`**

Insert immediately before `resolve_install_disk` (near line 778):

```bash
find_disk_by_serial() {
  local target_serial="$1"
  local -a matches

  mapfile -t matches < <(
    lsblk -dnpo NAME,SERIAL 2>/dev/null \
      | awk -v s="$target_serial" '{ name=$1; $1=""; sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if ($0 == s) print name }'
  )

  if [[ "${#matches[@]}" -eq 0 ]]; then
    echo "ERROR: No disk found with serial '${target_serial}'. Present disks (NAME SERIAL):" >&2
    lsblk -dnpo NAME,SERIAL 2>/dev/null >&2 || true
    die "Cannot pin install disk by serial '${target_serial}'."
    return 1
  fi

  if [[ "${#matches[@]}" -gt 1 ]]; then
    die "Multiple disks match serial '${target_serial}': ${matches[*]}. Refusing to guess."
    return 1
  fi

  printf '%s\n' "${matches[0]}"
}
```

- [ ] **Step 4: Rewrite `resolve_install_disk`**

Replace the existing body (near lines 778-784) with:

```bash
resolve_install_disk() {
  if [[ -n "${DISK_SERIAL_OVERRIDE:-}" ]]; then
    if [[ -n "${DISK_DEVICE_OVERRIDE:-}" ]]; then
      echo "WARNING: --disk-serial given; ignoring --disk-device ${DISK_DEVICE_OVERRIDE}." >&2
    fi
    find_disk_by_serial "$DISK_SERIAL_OVERRIDE"
  elif [[ -n "${DISK_DEVICE_OVERRIDE:-}" ]]; then
    normalize_disk_device "$DISK_DEVICE_OVERRIDE"
  else
    detect_install_disk
  fi
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all four new tests `ok`; the existing `resolve_install_disk prefers explicit override` test still `ok` (it leaves `DISK_SERIAL_OVERRIDE` unset, handled by `:-`).

- [ ] **Step 6: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Resolve install disk by serial with hard-fail on no/ambiguous match"
```

---

### Task 3: Authoritative serial capture, replay emission, and docs

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (`main` serial capture near lines 1356-1357; `print_replay_command` disk line near line 1292)
- Modify: `README.md` (document `--disk-serial`)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `DISK_SERIAL_OVERRIDE`, `INSTALL_DISK`, `INSTALL_DISK_SERIAL` (globals); `print_replay_command` (existing).
- Produces: replay command emits `--disk-serial <serial>` and omits `--disk-device` when `INSTALL_DISK_SERIAL` is non-empty; emits `--disk-device <path>` (unchanged) when it is empty.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-hetzner-sno-prepare-pxe.sh` (model the env on the existing `generate_agent_config` tests near lines 769-825, which set globals then call the function):

```bash
test_replay_emits_disk_serial_when_known() {
  local output
  output="$(HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_NAME="hetzner-sno-prepare-pxe.sh"
    NODE_HOSTNAME="node.example.com"
    SSH_PUBLIC_KEY_FILE="/root/id_ed25519.pub"
    DEFAULT_IFACE="eth0"
    IP_WITH_PREFIX="192.0.2.10/24"
    GATEWAY="192.0.2.1"
    DNS_SERVERS=("192.0.2.53")
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL="S63CNF0X212063"
    ARTIFACT_DIR="/root"
    BIN_DIR="/usr/local/bin"
    OCP_VERSION="4.22.1"
    PULL_SECRET_FILE="/root/pull-secret.json"
    BASE_DOMAIN="example.com"
    CLUSTER_NAME="sno"
    RENDEZVOUS_IP="192.0.2.10"
    print_replay_command
  ')"
  [[ "${output}" == *"--disk-serial S63CNF0X212063"* ]] || return 1
  [[ "${output}" != *"--disk-device"* ]] || return 1
}

test_replay_emits_disk_device_when_no_serial() {
  local output
  output="$(HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_NAME="hetzner-sno-prepare-pxe.sh"
    NODE_HOSTNAME="node.example.com"
    SSH_PUBLIC_KEY_FILE="/root/id_ed25519.pub"
    DEFAULT_IFACE="eth0"
    IP_WITH_PREFIX="192.0.2.10/24"
    GATEWAY="192.0.2.1"
    DNS_SERVERS=("192.0.2.53")
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL=""
    ARTIFACT_DIR="/root"
    BIN_DIR="/usr/local/bin"
    OCP_VERSION="4.22.1"
    PULL_SECRET_FILE="/root/pull-secret.json"
    BASE_DOMAIN="example.com"
    CLUSTER_NAME="sno"
    RENDEZVOUS_IP="192.0.2.10"
    print_replay_command
  ')"
  [[ "${output}" == *"--disk-device /dev/nvme0n1"* ]] || return 1
  [[ "${output}" != *"--disk-serial"* ]] || return 1
}
```

Register them:

```bash
run_test "replay emits --disk-serial when serial known" test_replay_emits_disk_serial_when_known
run_test "replay emits --disk-device when no serial" test_replay_emits_disk_device_when_no_serial
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: `replay emits --disk-serial when serial known` reports `not ok` (current code always emits `--disk-device`).

- [ ] **Step 3: Make the captured serial authoritative in `main`**

After the existing `INSTALL_DISK_SERIAL="$(lsblk ...)"` capture line (near line 1357), add:

```bash
  if [[ -n "${DISK_SERIAL_OVERRIDE:-}" ]]; then
    INSTALL_DISK_SERIAL="$DISK_SERIAL_OVERRIDE"
  fi
```

- [ ] **Step 4: Emit `--disk-serial` in `print_replay_command`**

Replace the single disk line (near line 1292):

```bash
  lines+=("  --disk-device $(printf '%q' "$INSTALL_DISK") \\")
```

with:

```bash
  if [[ -n "${INSTALL_DISK_SERIAL:-}" ]]; then
    lines+=("  --disk-serial $(printf '%q' "$INSTALL_DISK_SERIAL") \\")
  else
    lines+=("  --disk-device $(printf '%q' "$INSTALL_DISK") \\")
  fi
```

(The existing NOTE block below — gated on `INSTALL_DISK_SERIAL` — stays; it correctly explains the kernel name was point-in-time and the target is the serial.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: both new replay tests `ok`; no regressions.

- [ ] **Step 6: Document `--disk-serial` in README**

In `README.md`, where `--disk-device` / disk options are described, add an entry such as:

```markdown
- `--disk-serial <serial>` — Pin the install disk by its hardware serial number.
  This is the stable, replay-safe selector: it survives NVMe kernel-name
  reordering across reboots, unlike `--disk-device`. The printed replay command
  uses `--disk-serial` automatically whenever a serial is known.
```

(If `README.md` has no disk-options section, add the entry under the options/usage section near the other flags. Confirm the exact surrounding wording at edit time.)

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh README.md
git commit -m "Emit --disk-serial in replay and make supplied serial authoritative"
```

---

## Self-Review

**Spec coverage:**
- CLI `--disk-serial` + usage → Task 1. ✓
- Resolution precedence serial→device→autodetect, `find_disk_by_serial`, conflict warning, not-found/ambiguous die → Task 2. ✓
- Serial authoritative when supplied → Task 3 Step 3. ✓
- Replay emits `--disk-serial`, drops `--disk-device`; no-serial path unchanged → Task 3 Steps 1/4. ✓
- Hard-fail (no fallback) → Task 2 `find_disk_by_serial`. ✓
- Tests for all six spec test cases → Tasks 1-3 (parse covered; resolve/absent/ambiguous/precedence in Task 2; two replay paths in Task 3). ✓
- README docs → Task 3 Step 6. ✓

**Placeholder scan:** README wording at Step 6 notes "confirm surrounding wording at edit time" because README structure is not yet inspected; the entry text itself is complete. No other placeholders.

**Type consistency:** `DISK_SERIAL_OVERRIDE`, `find_disk_by_serial`, `INSTALL_DISK_SERIAL`, `resolve_install_disk` names used identically across all tasks. ✓
