# Debian 12 Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a non-blocking warning when the Hetzner SNO scripts are not running on Debian 12.

**Architecture:** Keep the scripts self-contained, matching the existing local-helper style. Add a `warn_if_not_debian_12` helper to each script and call it immediately after `require_arch`, so the warning appears during both dry-run and normal execution.

**Tech Stack:** Bash, `/etc/os-release`, existing shell test harness, ShellCheck.

---

## File Structure

- Modify `hetzner-sno-prepare-pxe.sh`: add `warn_if_not_debian_12`; call it after `require_arch`.
- Modify `hetzner-sno-provision-host.sh`: add the same helper; call it after `require_arch`.
- Modify `hetzner-sno-provision-host-agentbased.sh`: add the same helper; call it after `require_arch`.
- Modify `tests/test-hetzner-sno-hardening.sh`: add focused tests for Debian 12, non-Debian, and missing metadata.
- Modify `README.md`: document that Debian 12 Hetzner Rescue is the tested runtime and other OSes may fail.

## Task 1: Add Failing OS Warning Tests

**Files:**
- Modify: `tests/test-hetzner-sno-hardening.sh`

- [ ] **Step 1: Add helper tests to `tests/test-hetzner-sno-hardening.sh`**

Add these test functions near the other focused helper tests:

```bash
test_debian12_metadata_does_not_warn() {
  local temp_dir os_release stderr_file status

  temp_dir="$(mktemp -d)"
  os_release="${temp_dir}/os-release"
  stderr_file="${temp_dir}/stderr.log"
  printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' > "$os_release"

  OS_RELEASE_FILE="$os_release" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${PREPARE_SCRIPT}"'"
    warn_if_not_debian_12
  ' 2>"$stderr_file"
  status=$?

  [[ "$status" -eq 0 ]]
  [[ ! -s "$stderr_file" ]]

  rm -rf "$temp_dir"
}

test_non_debian12_metadata_warns_without_failing() {
  local temp_dir os_release stderr_file status

  temp_dir="$(mktemp -d)"
  os_release="${temp_dir}/os-release"
  stderr_file="${temp_dir}/stderr.log"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$os_release"

  OS_RELEASE_FILE="$os_release" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${PREPARE_SCRIPT}"'"
    warn_if_not_debian_12
  ' 2>"$stderr_file"
  status=$?

  [[ "$status" -eq 0 ]]
  grep -F 'WARNING: This script is tested for Debian 12 Hetzner Rescue. Detected Ubuntu 24.04 LTS; it may fail.' "$stderr_file" >/dev/null

  rm -rf "$temp_dir"
}

test_missing_os_release_warns_without_failing() {
  local temp_dir stderr_file status

  temp_dir="$(mktemp -d)"
  stderr_file="${temp_dir}/stderr.log"

  OS_RELEASE_FILE="${temp_dir}/missing-os-release" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${PREPARE_SCRIPT}"'"
    warn_if_not_debian_12
  ' 2>"$stderr_file"
  status=$?

  [[ "$status" -eq 0 ]]
  grep -F 'WARNING: Could not read' "$stderr_file" >/dev/null
  grep -F 'This script is tested for Debian 12 Hetzner Rescue and may fail on other systems.' "$stderr_file" >/dev/null

  rm -rf "$temp_dir"
}
```

- [ ] **Step 2: Register the tests**

Add these `run_test` calls before the final Debian 12 container script existence test:

```bash
run_test "Debian 12 metadata does not warn" test_debian12_metadata_does_not_warn
run_test "non-Debian 12 metadata warns without failing" test_non_debian12_metadata_warns_without_failing
run_test "missing os-release warns without failing" test_missing_os_release_warns_without_failing
```

- [ ] **Step 3: Verify tests fail for missing helper**

Run:

```bash
./tests/test-hetzner-sno-hardening.sh
```

Expected: the three new tests fail because `warn_if_not_debian_12` is not defined.

## Task 2: Implement Warning Helper and Wire It Into Scripts

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh`
- Modify: `hetzner-sno-provision-host.sh`
- Modify: `hetzner-sno-provision-host-agentbased.sh`

- [ ] **Step 1: Add `warn_if_not_debian_12` after `require_arch` in each script**

Use this exact helper body in all three scripts:

```bash
warn_if_not_debian_12() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local os_id=""
  local version_id=""
  local pretty_name=""
  local key=""
  local value=""

  if [[ ! -r "$os_release_file" ]]; then
    echo "WARNING: Could not read ${os_release_file}. This script is tested for Debian 12 Hetzner Rescue and may fail on other systems." >&2
    return 0
  fi

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      ID)
        os_id="${value%\"}"
        os_id="${os_id#\"}"
        ;;
      VERSION_ID)
        version_id="${value%\"}"
        version_id="${version_id#\"}"
        ;;
      PRETTY_NAME)
        pretty_name="${value%\"}"
        pretty_name="${pretty_name#\"}"
        ;;
    esac
  done < "$os_release_file"

  if [[ -z "$pretty_name" ]]; then
    pretty_name="${os_id:-unknown} ${version_id}"
  fi

  if [[ "$os_id" != "debian" || "$version_id" != "12" ]]; then
    echo "WARNING: This script is tested for Debian 12 Hetzner Rescue. Detected ${pretty_name}; it may fail." >&2
  fi
}
```

- [ ] **Step 2: Call helper after `require_arch` in each `main`**

In `hetzner-sno-prepare-pxe.sh`:

```bash
  require_arch
  warn_if_not_debian_12
  require_commands python3 awk head lsblk findmnt ip hostname
```

In `hetzner-sno-provision-host.sh`:

```bash
  require_arch
  warn_if_not_debian_12
  print_resolved_config
```

In `hetzner-sno-provision-host-agentbased.sh`:

```bash
  require_arch
  warn_if_not_debian_12
  validate_agent_artifacts
```

- [ ] **Step 3: Run focused test**

Run:

```bash
./tests/test-hetzner-sno-hardening.sh
```

Expected: all tests pass.

## Task 3: Document Runtime Warning

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add troubleshooting bullet**

In the warnings/troubleshooting section, add:

```markdown
- The scripts are tested on Debian 12 Hetzner Rescue. They print a warning and continue on other operating systems, but package installation, network discovery, or boot tooling may fail outside that environment.
```

- [ ] **Step 2: Run README-neutral checks**

Run:

```bash
git diff --check
```

Expected: no output and exit code 0.

## Task 4: Final Verification and Commit

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run full local verification**

Run:

```bash
git diff --check
bash -n *.sh tests/*.sh scripts/*.sh
shellcheck *.sh tests/*.sh scripts/*.sh
./tests/test-hetzner-sno-prepare-pxe.sh
./tests/test-hetzner-sno-hardening.sh
```

Expected: all commands exit 0.

- [ ] **Step 2: Run Debian 12 container verification**

Run:

```bash
./scripts/test-debian12-container.sh
```

Expected: container completes syntax, ShellCheck, and shell tests with exit code 0.

- [ ] **Step 3: Commit implementation**

Run:

```bash
git add README.md hetzner-sno-prepare-pxe.sh hetzner-sno-provision-host.sh hetzner-sno-provision-host-agentbased.sh tests/test-hetzner-sno-hardening.sh docs/superpowers/plans/2026-06-12-debian-12-warning.md
git commit -m "Warn outside Debian 12 rescue"
```

Expected: one commit containing the helper, tests, docs, and implementation plan.

- [ ] **Step 4: Push branch and update PR**

Run:

```bash
git push -u origin copilot/use-nmstatectl-for-agent-installer
```

Then update the existing PR body/checklist to mention the Debian 12 runtime warning and verification.
