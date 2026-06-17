# Multi-Disk Rescue Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe interactive disk picker for multi-disk Hetzner rescue hosts, keep network discovery automatic, and document the real-server workflow for a 3-NVMe machine.

**Architecture:** Keep the existing single-file shell script structure. Extend `hetzner-sno-prepare-pxe.sh` with small disk-selection helpers, drive the behavior with focused shell tests, and update the README so the rescue workflow matches what the script really does.

**Tech Stack:** Bash, `lsblk`, existing shell test harness, ShellCheck, README documentation.

---

## File Structure

- Modify `tests/test-hetzner-sno-prepare-pxe.sh`: add failing tests for multi-disk interactive selection, non-interactive failure output, single-disk auto-pick, and explicit override handling.
- Modify `hetzner-sno-prepare-pxe.sh`: add disk candidate listing, candidate table formatting, interactive selection, and resolve-time selection flow.
- Modify `README.md`: add the rescue quick start, simplify the rescue dry-run example, and document the 3-NVMe real-server runbook.
- Create `docs/superpowers/specs/2026-06-17-multi-disk-rescue-design.md`: capture the approved design.
- Create `docs/superpowers/plans/2026-06-17-multi-disk-rescue-testing.md`: capture this implementation plan.

## Task 1: Add Failing Disk-Selection Tests

**Files:**
- Modify: `tests/test-hetzner-sno-prepare-pxe.sh`

- [ ] **Step 1: Register the new helper functions in the sourceability test**

Add the new declarations alongside the existing `declare -F` checks:

```bash
declare -F list_install_disk_candidates >/dev/null
declare -F format_disk_candidate_table >/dev/null
declare -F prompt_install_disk_choice >/dev/null
declare -F resolve_install_disk >/dev/null
```

- [ ] **Step 2: Add a failing multi-disk interactive selection test**

Add a test like this:

```bash
test_detect_install_disk_prompts_for_multi_disk_selection() {
  local stub_dir status
  stub_dir="$(mktemp -d)"

  cat > "${stub_dir}/findmnt" <<'EOF'
#!/bin/bash
printf 'overlay\n'
EOF

  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  "-dnpo NAME,TYPE,RM")
    printf '/dev/nvme0n1 disk 0\n/dev/nvme1n1 disk 0\n/dev/nvme2n1 disk 0\n'
    ;;
  *"TYPE /dev/nvme0n1"*|*"TYPE /dev/nvme1n1"*|*"TYPE /dev/nvme2n1"*)
    printf 'disk\n'
    ;;
  *"SIZE /dev/nvme0n1"*)
    printf '1.8T\n'
    ;;
  *"SIZE /dev/nvme1n1"*)
    printf '1.8T\n'
    ;;
  *"SIZE /dev/nvme2n1"*)
    printf '1.8T\n'
    ;;
  *"MODEL /dev/nvme0n1"*)
    printf 'Samsung A\n'
    ;;
  *"MODEL /dev/nvme1n1"*)
    printf 'Samsung B\n'
    ;;
  *"MODEL /dev/nvme2n1"*)
    printf 'Samsung C\n'
    ;;
  *"SERIAL /dev/nvme0n1"*)
    printf 'SN-A\n'
    ;;
  *"SERIAL /dev/nvme1n1"*)
    printf 'SN-B\n'
    ;;
  *"SERIAL /dev/nvme2n1"*)
    printf 'SN-C\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

  chmod +x "${stub_dir}/findmnt" "${stub_dir}/lsblk"

  printf '2\n' | PATH="${stub_dir}:${PATH}" HSPPXE_ALLOW_NON_TTY_INTERACTIVE=1 HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    [[ "$(detect_install_disk)" == "/dev/nvme1n1" ]]
  '
  status=$?

  rm -rf "${stub_dir}"
  return "${status}"
}
```

- [ ] **Step 3: Add a failing non-interactive multi-disk error test**

Add a test like this:

```bash
test_detect_install_disk_lists_candidates_when_prompting_is_unavailable() {
  local stub_dir err_file status err_output
  stub_dir="$(mktemp -d)"
  err_file="$(mktemp)"

  cat > "${stub_dir}/findmnt" <<'EOF'
#!/bin/bash
printf 'overlay\n'
EOF

  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  "-dnpo NAME,TYPE,RM")
    printf '/dev/nvme0n1 disk 0\n/dev/nvme1n1 disk 0\n/dev/nvme2n1 disk 0\n'
    ;;
  *"SIZE /dev/nvme0n1"*|*"SIZE /dev/nvme1n1"*|*"SIZE /dev/nvme2n1"*)
    printf '1.8T\n'
    ;;
  *"MODEL /dev/nvme0n1"*|*"MODEL /dev/nvme1n1"*|*"MODEL /dev/nvme2n1"*)
    printf 'Samsung\n'
    ;;
  *"SERIAL /dev/nvme0n1"*)
    printf 'SN-A\n'
    ;;
  *"SERIAL /dev/nvme1n1"*)
    printf 'SN-B\n'
    ;;
  *"SERIAL /dev/nvme2n1"*)
    printf 'SN-C\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

  chmod +x "${stub_dir}/findmnt" "${stub_dir}/lsblk"

  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ! detect_install_disk
  ' > /dev/null 2>"${err_file}"
  status=$?
  err_output="$(<"${err_file}")"

  [[ "${status}" -eq 0 ]]
  [[ "${err_output}" == *"Multiple candidate install disks detected"* ]]
  [[ "${err_output}" == *"/dev/nvme0n1"* ]]
  [[ "${err_output}" == *"/dev/nvme1n1"* ]]
  [[ "${err_output}" == *"/dev/nvme2n1"* ]]
  [[ "${err_output}" == *"Use --disk-device <path> to choose one explicitly."* ]]

  rm -rf "${stub_dir}" "${err_file}"
}
```

- [ ] **Step 4: Add single-disk and explicit-override tests**

Add two more focused tests:

```bash
test_detect_install_disk_autopicks_single_candidate() {
  local stub_dir status
  stub_dir="$(mktemp -d)"

  cat > "${stub_dir}/findmnt" <<'EOF'
#!/bin/bash
printf 'overlay\n'
EOF

  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  "-dnpo NAME,TYPE,RM")
    printf '/dev/nvme2n1 disk 0\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

  chmod +x "${stub_dir}/findmnt" "${stub_dir}/lsblk"

  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    [[ "$(detect_install_disk)" == "/dev/nvme2n1" ]]
  '
  status=$?

  rm -rf "${stub_dir}"
  return "${status}"
}

test_resolve_install_disk_prefers_explicit_override() {
  local stub_dir status
  stub_dir="$(mktemp -d)"

  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  *"TYPE /dev/nvme1n1p3"*)
    printf 'part\n'
    ;;
  *"PKNAME /dev/nvme1n1p3"*)
    printf 'nvme1n1\n'
    ;;
  *"TYPE /dev/nvme1n1"*)
    printf 'disk\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

  chmod +x "${stub_dir}/lsblk"

  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DISK_DEVICE_OVERRIDE="/dev/nvme1n1p3"
    [[ "$(resolve_install_disk)" == "/dev/nvme1n1" ]]
  '
  status=$?

  rm -rf "${stub_dir}"
  return "${status}"
}
```

- [ ] **Step 5: Register the tests and watch them fail**

Add these lines near the existing `run_test` calls:

```bash
run_test "detect_install_disk prompts for multi-disk selection" test_detect_install_disk_prompts_for_multi_disk_selection
run_test "detect_install_disk lists candidates when prompting is unavailable" test_detect_install_disk_lists_candidates_when_prompting_is_unavailable
run_test "detect_install_disk auto-picks a single candidate" test_detect_install_disk_autopicks_single_candidate
run_test "resolve_install_disk prefers explicit override" test_resolve_install_disk_prefers_explicit_override
```

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the new tests fail because the helper functions or multi-disk behavior do not exist yet.

## Task 2: Implement the Multi-Disk Selection Helpers

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh`

- [ ] **Step 1: Add the disk helper functions after `normalize_disk_device()`**

Add these helpers:

```bash
list_install_disk_candidates() {
  lsblk -dnpo NAME,TYPE,RM 2>/dev/null | awk '$2 == "disk" && $3 == "0" {print $1}'
}

format_disk_candidate_table() {
  local device
  local index=1
  local size
  local model
  local serial
  local details

  for device in "$@"; do
    size="$(lsblk -ndo SIZE "$device" 2>/dev/null | head -1 || true)"
    model="$(lsblk -ndo MODEL "$device" 2>/dev/null | head -1 | awk '{$1=$1; print}' || true)"
    serial="$(lsblk -ndo SERIAL "$device" 2>/dev/null | head -1 | awk '{$1=$1; print}' || true)"
    details="${model}"
    if [[ -n "$serial" ]]; then
      details="${details:+${details} }${serial}"
    fi
    printf '  [%d] %-14s %-6s %s\n' "$index" "$device" "${size:-unknown}" "${details:-no model or serial reported}"
    index=$((index + 1))
  done
}

prompt_install_disk_choice() {
  local -a candidate_disks=("$@")
  local selection

  while true; do
    echo "Multiple candidate install disks detected:" >&2
    format_disk_candidate_table "${candidate_disks[@]}" >&2
    read -r -p "Select install disk [1-${#candidate_disks[@]}]: " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#candidate_disks[@]} )); then
      printf '%s\n' "${candidate_disks[$((selection - 1))]}"
      return 0
    fi
    echo "ERROR: Invalid selection '${selection}'. Enter a number from 1 to ${#candidate_disks[@]}." >&2
  done
}
```

- [ ] **Step 2: Update `detect_install_disk()` to use the helpers**

Change the function so it looks like this:

```bash
detect_install_disk() {
  local root_source
  local normalized_device
  local -a candidate_disks

  root_source="$(findmnt -n -o SOURCE / 2>/dev/null | head -1 || true)"
  if [[ "$root_source" == /dev/* ]]; then
    normalized_device="$(normalize_disk_device "$root_source" 2>/dev/null || true)"
    if [[ -n "$normalized_device" ]]; then
      printf '%s\n' "$normalized_device"
      return 0
    fi
  fi

  mapfile -t candidate_disks < <(list_install_disk_candidates)

  if [[ "${#candidate_disks[@]}" -eq 1 ]]; then
    printf '%s\n' "${candidate_disks[0]}"
    return 0
  fi

  if [[ "${#candidate_disks[@]}" -eq 0 ]]; then
    die "Could not autodetect an install disk. Use --disk-device <path>."
    return 1
  fi

  if can_prompt; then
    prompt_install_disk_choice "${candidate_disks[@]}"
    return 0
  fi

  echo "ERROR: Multiple candidate install disks detected:" >&2
  format_disk_candidate_table "${candidate_disks[@]}" >&2
  echo "Use --disk-device <path> to choose one explicitly." >&2
  return 1
}
```

- [ ] **Step 3: Keep `resolve_install_disk()` conservative**

Use:

```bash
resolve_install_disk() {
  if [[ -n "${DISK_DEVICE_OVERRIDE}" ]]; then
    normalize_disk_device "$DISK_DEVICE_OVERRIDE"
  else
    detect_install_disk
  fi
}
```

- [ ] **Step 4: Run the focused test file**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the new disk-selection tests now pass.

## Task 3: Remove the Early Disk Prompt and Update the README

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh`
- Modify: `README.md`

- [ ] **Step 1: Remove the early interactive disk prompt**

Delete this line from `prompt_for_missing_config()`:

```bash
prompt_optional_value DISK_DEVICE_OVERRIDE "Install disk"
```

Leave the other prompts intact so the disk is chosen only at resolve time.

- [ ] **Step 2: Update the README agent-based section**

Revise the agent-based section so it clearly states:

```markdown
- On Hetzner rescue, DHCP-backed network values are auto-detected.
- On multi-disk systems, pass `--disk-device` for automation or choose from the interactive disk menu.
```

Replace the rescue dry-run example with:

```bash
./hetzner-sno-prepare-pxe.sh --dry-run \
  --disk-device /dev/nvme1n1 \
  4.16.15 ./pull-secret.json example.com sno
```

Keep the network override example, but introduce it as a troubleshooting path rather than the main rescue workflow.

- [ ] **Step 3: Add a short real-server runbook**

Document these exact rescue steps:

```bash
chmod +x /root/hetzner-sno-*.sh
./hetzner-sno-prepare-pxe.sh --dry-run --disk-device /dev/nvme1n1 4.16.15 /root/pull-secret.json example.com sno
./hetzner-sno-prepare-pxe.sh --yes --disk-device /dev/nvme1n1 4.16.15 /root/pull-secret.json example.com sno
ls -la /root/agent.x86_64-*
./hetzner-sno-provision-host-agentbased.sh --dry-run
./hetzner-sno-provision-host-agentbased.sh --yes
```

- [ ] **Step 4: Re-run the focused tests**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: still all green after the prompt cleanup and doc updates.

## Task 4: Verify the Whole Change Set

**Files:**
- Verify all touched files.

- [ ] **Step 1: Run syntax and focused verification**

Run:

```bash
git diff --check
bash -n *.sh tests/*.sh scripts/*.sh
./tests/test-hetzner-sno-prepare-pxe.sh
./tests/test-hetzner-sno-hardening.sh
```

Expected: all commands exit 0.

- [ ] **Step 2: Run ShellCheck**

Run:

```bash
shellcheck *.sh tests/*.sh scripts/*.sh
```

Expected: exit code 0.

- [ ] **Step 3: Run Debian 12 container verification**

Run:

```bash
./scripts/test-debian12-container.sh
```

Expected: syntax checks, ShellCheck, and shell tests all pass inside the container.

- [ ] **Step 4: Do not commit automatically**

Per the repository instructions, stop after verification and leave the branch ready for review unless the user explicitly asks for a commit.
