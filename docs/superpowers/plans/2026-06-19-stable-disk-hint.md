# Stable Install-Disk Hint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the OpenShift install target stable by writing `rootDeviceHints.serialNumber` (from the selected disk's serial) instead of the unstable kernel device name.

**Architecture:** `hetzner-sno-prepare-pxe.sh` resolves the install disk to a `/dev/...` path, then generates `agent-config.yaml` through a `python3` heredoc. We capture the disk's serial at the single resolve point, pass it into the heredoc, and branch the `rootDeviceHints` field on serial presence (serial → `serialNumber`, empty → `deviceName` fallback with a warning).

**Tech Stack:** Bash, `lsblk`, embedded `python3` heredoc, custom bash test harness in `tests/`.

## Global Constraints

- Pure Bash + coreutils + `lsblk` + `python3`; no new dependencies.
- `python3` heredoc writes YAML line-by-line; string values are JSON-quoted via the existing `q()` helper.
- Tests run via `tests/test-hetzner-sno-prepare-pxe.sh`; source the script under `HSPPXE_TEST_MODE=1` and stub external binaries on `PATH`.
- No Co-Authored-By trailer in commit messages.
- Do not touch `hetzner-sno-provision-host-agentbased.sh`.

---

### Task 1: Capture install-disk serial and write serialNumber hint

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh:1337` (resolve point — add serial capture)
- Modify: `hetzner-sno-prepare-pxe.sh:1131` (heredoc env — export `HSP_INSTALL_DISK_SERIAL`)
- Modify: `hetzner-sno-prepare-pxe.sh:1156-1157` (config writer — branch serial vs name)
- Modify: `hetzner-sno-prepare-pxe.sh:1246` (resolved-config display — add serial line)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh` (two new cases + registration)

**Interfaces:**
- Consumes: `INSTALL_DISK` (set by `resolve_install_disk`, a `/dev/...` path); `generate_agent_config()` and its `python3` heredoc; the `q()` JSON-quote helper inside the heredoc.
- Produces: global `INSTALL_DISK_SERIAL` (trimmed serial string, possibly empty); `agent-config.yaml` containing either `serialNumber: "<serial>"` or `deviceName: "<path>"` under `rootDeviceHints`.

- [ ] **Step 1: Write the failing test (serial present)**

Add to `tests/test-hetzner-sno-prepare-pxe.sh`, before the `run_test` registration block (~line 573):

```bash
test_generate_agent_config_uses_serial_number() {
  local temp_dir
  local config
  local status

  temp_dir="$(mktemp -d)"
  mkdir -p "${temp_dir}/install"

  HSPPXE_TEST_MODE=1 \
  INSTALL_DIR="${temp_dir}/install" \
  CLUSTER_NAME="ocp1" \
  RENDEZVOUS_IP="95.217.75.157" \
  NODE_HOSTNAME="api.ocp1.example.com" \
  DEFAULT_IFACE="eth0" \
  MAC_ADDR="60:cf:84:bc:f6:94" \
  INSTALL_DISK="/dev/nvme1n1" \
  INSTALL_DISK_SERIAL="S63CNF0X212059" \
  IP_ADDR="95.217.75.157" \
  PREFIX_LEN="26" \
  GATEWAY="95.217.75.129" \
  DNS_SERVERS_RAW=$'185.12.64.1\n185.12.64.2' \
  bash -c '
    source "'"${SCRIPT}"'"
    generate_agent_config
  '
  status=$?

  config="$(<"${temp_dir}/install/agent-config.yaml")"

  [[ "${status}" -eq 0 ]] || return 1
  [[ "${config}" == *"serialNumber: \"S63CNF0X212059\""* ]] || return 1
  [[ "${config}" != *"deviceName:"* ]] || return 1

  rm -rf "${temp_dir}"
}
```

Register it in the `run_test` block (~line 573, alongside the other `run_test` lines):

```bash
run_test "generate_agent_config uses serialNumber when serial is known" test_generate_agent_config_uses_serial_number
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep "generate_agent_config uses serialNumber"`
Expected: `not ok - generate_agent_config uses serialNumber when serial is known` (current code writes `deviceName:`, so both asserts fail).

- [ ] **Step 3: Branch the config writer on serial presence**

In `hetzner-sno-prepare-pxe.sh`, replace lines 1156-1157:

```python
    handle.write("    rootDeviceHints:\n")
    handle.write(f"      deviceName: {q(os.environ['HSP_INSTALL_DISK'])}\n")
```

with:

```python
    handle.write("    rootDeviceHints:\n")
    install_disk_serial = os.environ.get("HSP_INSTALL_DISK_SERIAL", "").strip()
    if install_disk_serial:
        handle.write(f"      serialNumber: {q(install_disk_serial)}\n")
    else:
        import sys
        device = os.environ['HSP_INSTALL_DISK']
        print(
            f"WARNING: no serial for {device}; using unstable deviceName as "
            "install target. The kernel device name may resolve to a different "
            "disk inside the installer.",
            file=sys.stderr,
        )
        handle.write(f"      deviceName: {q(device)}\n")
```

- [ ] **Step 4: Export the serial into the heredoc**

In `hetzner-sno-prepare-pxe.sh`, after line 1131 (`  HSP_INSTALL_DISK="$INSTALL_DISK" \`), add:

```sh
  HSP_INSTALL_DISK_SERIAL="${INSTALL_DISK_SERIAL:-}" \
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep "generate_agent_config uses serialNumber"`
Expected: `ok - generate_agent_config uses serialNumber when serial is known`

- [ ] **Step 6: Write the failing test (serial absent → deviceName fallback)**

Add to `tests/test-hetzner-sno-prepare-pxe.sh`, after the previous test function:

```bash
test_generate_agent_config_falls_back_to_device_name() {
  local temp_dir
  local config
  local status

  temp_dir="$(mktemp -d)"
  mkdir -p "${temp_dir}/install"

  HSPPXE_TEST_MODE=1 \
  INSTALL_DIR="${temp_dir}/install" \
  CLUSTER_NAME="ocp1" \
  RENDEZVOUS_IP="95.217.75.157" \
  NODE_HOSTNAME="api.ocp1.example.com" \
  DEFAULT_IFACE="eth0" \
  MAC_ADDR="60:cf:84:bc:f6:94" \
  INSTALL_DISK="/dev/nvme1n1" \
  INSTALL_DISK_SERIAL="" \
  IP_ADDR="95.217.75.157" \
  PREFIX_LEN="26" \
  GATEWAY="95.217.75.129" \
  DNS_SERVERS_RAW=$'185.12.64.1\n185.12.64.2' \
  bash -c '
    source "'"${SCRIPT}"'"
    generate_agent_config
  '
  status=$?

  config="$(<"${temp_dir}/install/agent-config.yaml")"

  [[ "${status}" -eq 0 ]] || return 1
  [[ "${config}" == *"deviceName: \"/dev/nvme1n1\""* ]] || return 1
  [[ "${config}" != *"serialNumber:"* ]] || return 1

  rm -rf "${temp_dir}"
}
```

Register it in the `run_test` block:

```bash
run_test "generate_agent_config falls back to deviceName without serial" test_generate_agent_config_falls_back_to_device_name
```

- [ ] **Step 7: Run test to verify it passes**

The fallback branch already exists from Step 3, so this test should pass immediately.

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep "falls back to deviceName"`
Expected: `ok - generate_agent_config falls back to deviceName without serial`

- [ ] **Step 8: Capture the serial at the resolve point**

In `hetzner-sno-prepare-pxe.sh`, after line 1337 (`  INSTALL_DISK="$(resolve_install_disk)"`), add:

```sh
  INSTALL_DISK_SERIAL="$(lsblk -ndo SERIAL "$INSTALL_DISK" 2>/dev/null | head -1 | awk '{$1=$1; print}')"
```

- [ ] **Step 9: Add the serial to the resolved-config display**

In `hetzner-sno-prepare-pxe.sh`, after line 1246 (`  echo "  Install disk:      ${INSTALL_DISK}"`), add:

```sh
  echo "  Install disk serial: ${INSTALL_DISK_SERIAL:-(none — using device name)}"
```

- [ ] **Step 10: Run the full test suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all tests pass, including the two new cases; failure count `0`.

- [ ] **Step 11: Syntax-check the script**

Run: `bash -n hetzner-sno-prepare-pxe.sh`
Expected: no output, exit 0.

- [ ] **Step 12: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Use disk serial for rootDeviceHints to stabilize install target

Kernel device names (nvme0n1, ...) are not stable across boot
environments, so the recorded deviceName could resolve to a different
physical disk inside the Assisted Installer. Capture the selected disk's
serial and write rootDeviceHints.serialNumber, falling back to deviceName
only when no serial is available."
```

---

### Task 2: Annotate replay command with authoritative-serial note

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh:1278` and the replay output block (`:1304`)

**Interfaces:**
- Consumes: `INSTALL_DISK`, `INSTALL_DISK_SERIAL`, the `lines` array in `print_replay_command()`.
- Produces: an extra comment line after the replay command noting the serial.

- [ ] **Step 1: Add the serial note to the replay output**

In `hetzner-sno-prepare-pxe.sh`, in `print_replay_command()`, replace the closing block at lines 1304 (`  echo ""`) — specifically the final `echo ""` after the loop (line 1304) — with:

```sh
  if [[ -n "${INSTALL_DISK_SERIAL:-}" ]]; then
    echo ""
    echo "  # NOTE: --disk-device ${INSTALL_DISK} is a point-in-time kernel name."
    echo "  #       The install target is pinned by serial ${INSTALL_DISK_SERIAL}."
  fi
  echo ""
```

(Locate by context: it is the `echo ""` immediately before the closing `}` of `print_replay_command`.)

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n hetzner-sno-prepare-pxe.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Run the full test suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all tests still pass; failure count `0`.

- [ ] **Step 4: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh
git commit -m "Note authoritative disk serial in replay output

The replay command's --disk-device is a volatile kernel name; print the
serial alongside it so the operator knows which identifier is binding."
```

---

## Self-Review

**Spec coverage:**
- Spec §Design.1 (capture serial at resolve point) → Task 1 Step 8.
- Spec §Design.2 (branch serial vs name + warning) → Task 1 Steps 3-4. Empty-serial fallback writes `deviceName` and emits a stderr warning; also surfaced in the resolved-config display (Step 9).
- Spec §Design.3 (resolved-config display) → Task 1 Step 9.
- Spec §Design.4 (replay note) → Task 2.
- Spec §Design.5 (two tests) → Task 1 Steps 1, 6.

**Placeholder scan:** No TBD/TODO; all code shown; commands have expected output.

**Type consistency:** `INSTALL_DISK_SERIAL` (bash global) and `HSP_INSTALL_DISK_SERIAL` (heredoc env) used consistently across capture, export, writer, display, and replay. Test env var names match the script's expected variable names (`INSTALL_DIR`, `CLUSTER_NAME`, `DNS_SERVERS_RAW`, etc.).
