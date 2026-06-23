# Boot Disk CSI Raw Partition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit `--csi-reserve-size` option to `hetzner-sno-prepare-pxe.sh` that reserves a raw day-1 boot-disk partition for LVMS or another CSI operator.

**Architecture:** Keep the implementation inside the existing single Bash script and existing Bash test harness. Parse CSI flags into globals, compute the partition start after install-disk and serial resolution, write one day-1 `MachineConfig` under `<install-dir>/openshift/`, and keep no-CSI behavior byte-stable for generated install and agent configs.

**Tech Stack:** Bash, `lsblk`, `awk`, here-doc YAML generation, existing plain Bash tests in `tests/test-hetzner-sno-prepare-pxe.sh`, README documentation.

## Global Constraints

- Feature is explicit-only: enabled only by `--csi-reserve-size <size>`.
- OpenShift minimum remains 4.14 for this repository's direct agent PXE workflow.
- Do not mutate the rescue-system disk with `sgdisk`, `parted`, `wipefs`, `mkfs`, or LVM commands.
- Do not generate LVMS, `LVMCluster`, StorageClass, or CSI/operator resources.
- Use `/dev/disk/by-partlabel/<label>` as the post-install device contract.
- Generate a direct `MachineConfig` with `ignition.version: 3.4.0`.
- Target `/dev/disk/by-id/coreos-boot-disk` in the MachineConfig.
- Use partition `number: 0`, omit `sizeMiB`, omit `wipePartitionEntry`, omit `wipeTable`, and omit `filesystems`.
- Real runs with CSI reservation require non-empty `INSTALL_DISK_SERIAL`; dry-run may defer CSI split validation after disk resolution.
- Default minimum OpenShift-side offset is `120GiB`, parsed to `122880` MiB.
- Default partition label is `openshift-csi`; valid labels match `^[A-Za-z0-9._-]{1,36}$`.
- Size strings require suffixes: `M`, `MiB`, `G`, `GiB`, `T`, or `TiB`; short suffixes are binary.
- The manifest must be written after `safe_prepare_install_dir` and after `generate_agent_config`, before `openshift-install agent create pxe-files`.
- Tests must not touch real disks; use stubs or sourced helper calls.

---

## File Structure

- Modify `hetzner-sno-prepare-pxe.sh`: add CLI flags, parsing helpers, CSI calculation, resolved-config/replay output, MachineConfig writer, and main-flow integration.
- Modify `tests/test-hetzner-sno-prepare-pxe.sh`: add isolated tests for parsing, validation, calculation, manifest generation, dry-run behavior, replay output, and integration order.
- Modify `README.md`: document the CSI reservation feature, serial-backed targeting requirement, raw partition path, and validation caveats.

---

### Task 1: Add CSI CLI Flags and Basic Validators

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh`
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: existing `parse_args`, `print_usage`, and `die`.
- Produces:
  - Global `CSI_RESERVE_SIZE_RAW` string, empty when disabled.
  - Global `CSI_MIN_ROOT_SIZE_RAW` string, default `120GiB`.
  - Global `CSI_MIN_ROOT_SIZE_SET` integer flag, `1` only when `--csi-min-root-size` was supplied.
  - Global `CSI_PART_LABEL` string, default `openshift-csi`.
  - Global `CSI_PART_LABEL_SET` integer flag, `1` only when `--csi-part-label` was supplied.
  - Function `csi_reservation_enabled()`.
  - Function `parse_csi_size_mib <raw> <flag_name>` prints integer MiB on stdout.
  - Function `validate_csi_part_label <label>` returns zero for valid labels.

- [ ] **Step 1: Write failing parser and validator tests**

Add these test functions near the existing `parse_args` tests in `tests/test-hetzner-sno-prepare-pxe.sh`:

```bash
test_parse_args_accepts_csi_flags() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    parse_args --csi-reserve-size 800G --csi-min-root-size 160GiB --csi-part-label lvms-pv 4.22.1 /tmp/pull-secret.json example.com sno
    [[ "${CSI_RESERVE_SIZE_RAW}" == "800G" ]]
    [[ "${CSI_MIN_ROOT_SIZE_RAW}" == "160GiB" ]]
    [[ "${CSI_MIN_ROOT_SIZE_SET}" == "1" ]]
    [[ "${CSI_PART_LABEL}" == "lvms-pv" ]]
    [[ "${CSI_PART_LABEL_SET}" == "1" ]]
    csi_reservation_enabled
  '
}

test_parse_args_rejects_orphan_csi_min_root() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ! parse_args --csi-min-root-size 160GiB 4.22.1 /tmp/pull-secret.json example.com sno
  ' 2>/dev/null
}

test_parse_args_rejects_orphan_csi_label() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ! parse_args --csi-part-label lvms-pv 4.22.1 /tmp/pull-secret.json example.com sno
  ' 2>/dev/null
}

test_parse_csi_size_mib_accepts_binary_suffixes() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    [[ "$(parse_csi_size_mib 800G --csi-reserve-size)" == "819200" ]]
    [[ "$(parse_csi_size_mib 800GiB --csi-reserve-size)" == "819200" ]]
    [[ "$(parse_csi_size_mib 1T --csi-reserve-size)" == "1048576" ]]
    [[ "$(parse_csi_size_mib 102400MiB --csi-reserve-size)" == "102400" ]]
  '
}

test_parse_csi_size_mib_rejects_invalid_values() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ! parse_csi_size_mib 800 --csi-reserve-size
    ! parse_csi_size_mib 1GB --csi-reserve-size
    ! parse_csi_size_mib 0G --csi-reserve-size
    ! parse_csi_size_mib 1.5T --csi-reserve-size
  ' 2>/dev/null
}

test_validate_csi_part_label() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    validate_csi_part_label openshift-csi
    validate_csi_part_label lvms.pv_01
    ! validate_csi_part_label ""
    ! validate_csi_part_label "bad/label"
    ! validate_csi_part_label "bad label"
    ! validate_csi_part_label "abcdefghijklmnopqrstuvwxyz01234567890"
  ' 2>/dev/null
}
```

Register the tests with the other `run_test` entries near the parser tests:

```bash
run_test "parse_args accepts CSI flags" test_parse_args_accepts_csi_flags
run_test "parse_args rejects orphan CSI min-root flag" test_parse_args_rejects_orphan_csi_min_root
run_test "parse_args rejects orphan CSI label flag" test_parse_args_rejects_orphan_csi_label
run_test "parse_csi_size_mib accepts binary suffixes" test_parse_csi_size_mib_accepts_binary_suffixes
run_test "parse_csi_size_mib rejects invalid values" test_parse_csi_size_mib_rejects_invalid_values
run_test "validate_csi_part_label accepts and rejects labels" test_validate_csi_part_label
```

- [ ] **Step 2: Run tests to verify the new tests fail**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the new CSI parser/helper tests report `not ok` because the options and functions do not exist.

- [ ] **Step 3: Add usage text and option parsing**

In `print_usage`, add these option lines after `--disk-serial`:

```text
  --csi-reserve-size <size> Reserve a raw boot-disk partition for CSI/LVMS, e.g. 800G
  --csi-min-root-size <size> Minimum OpenShift OS/root allowance after reservation (default: 120GiB)
  --csi-part-label <label>  PARTLABEL for the raw partition (default: openshift-csi)
```

Add an example near the existing examples:

```bash
  ${SCRIPT_NAME} --disk-serial S63CNF0X212063 --csi-reserve-size 800G 4.22.1 /root/pull-secret.json example.com sno
```

In `parse_args`, initialize CSI globals after the disk globals:

```bash
  CSI_RESERVE_SIZE_RAW=""
  CSI_MIN_ROOT_SIZE_RAW="120GiB"
  CSI_MIN_ROOT_SIZE_SET=0
  CSI_PART_LABEL="openshift-csi"
  CSI_PART_LABEL_SET=0
  CSI_RESERVE_MIB=""
  CSI_MIN_ROOT_MIB=""
  CSI_DISK_MIB=""
  CSI_START_MIB=""
  CSI_SPLIT_DEFERRED=0
  CSI_SPLIT_DEFER_REASON=""
```

Add these `case` arms before `--artifact-dir)`:

```bash
      --csi-reserve-size)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --csi-reserve-size requires a size such as 800G." >&2
          print_usage
          return 1
        fi
        CSI_RESERVE_SIZE_RAW="$2"
        shift 2
        ;;
      --csi-min-root-size)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --csi-min-root-size requires a size such as 120GiB." >&2
          print_usage
          return 1
        fi
        CSI_MIN_ROOT_SIZE_RAW="$2"
        CSI_MIN_ROOT_SIZE_SET=1
        shift 2
        ;;
      --csi-part-label)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --csi-part-label requires a partition label." >&2
          print_usage
          return 1
        fi
        CSI_PART_LABEL="$2"
        CSI_PART_LABEL_SET=1
        shift 2
        ;;
```

After the positional argument count check in `parse_args`, add orphan flag validation:

```bash
  if [[ -z "$CSI_RESERVE_SIZE_RAW" ]]; then
    if [[ "$CSI_MIN_ROOT_SIZE_SET" == "1" ]]; then
      echo "ERROR: --csi-min-root-size requires --csi-reserve-size." >&2
      print_usage
      return 1
    fi
    if [[ "$CSI_PART_LABEL_SET" == "1" ]]; then
      echo "ERROR: --csi-part-label requires --csi-reserve-size." >&2
      print_usage
      return 1
    fi
  fi
```

- [ ] **Step 4: Add helper functions**

Add these functions after `validate_ip_family_value`:

```bash
csi_reservation_enabled() {
  [[ -n "${CSI_RESERVE_SIZE_RAW:-}" ]]
}

parse_csi_size_mib() {
  local raw="$1"
  local flag_name="$2"
  local number suffix

  if [[ ! "$raw" =~ ^([0-9]+)([A-Za-z]+)$ ]]; then
    die "${flag_name} must be an integer with suffix M, MiB, G, GiB, T, or TiB (got '${raw}')."
    return 1
  fi

  number="${BASH_REMATCH[1]}"
  suffix="${BASH_REMATCH[2],,}"

  if (( number <= 0 )); then
    die "${flag_name} must be greater than zero."
    return 1
  fi

  case "$suffix" in
    m|mib)
      printf '%s\n' "$number"
      ;;
    g|gib)
      printf '%s\n' "$((number * 1024))"
      ;;
    t|tib)
      printf '%s\n' "$((number * 1024 * 1024))"
      ;;
    *)
      die "${flag_name} uses unsupported suffix '${suffix}'. Use M, MiB, G, GiB, T, or TiB."
      return 1
      ;;
  esac
}

validate_csi_part_label() {
  local label="$1"
  if [[ ! "$label" =~ ^[A-Za-z0-9._-]{1,36}$ ]]; then
    die "--csi-part-label must match ^[A-Za-z0-9._-]{1,36}$."
    return 1
  fi
}
```

- [ ] **Step 5: Run parser/helper tests**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the six CSI parser/helper tests pass. Existing tests must still pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Add CSI reservation CLI parsing"
```

---

### Task 2: Compute and Validate the CSI Reservation Plan

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh`
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `CSI_RESERVE_SIZE_RAW`, `CSI_MIN_ROOT_SIZE_RAW`, `CSI_PART_LABEL`, `INSTALL_DISK`, `INSTALL_DISK_SERIAL`, `DRY_RUN`.
- Produces:
  - Function `read_install_disk_size_mib <device>` prints integer MiB on stdout.
  - Function `defer_csi_split_validation <reason>` marks dry-run validation as deferred.
  - Function `prepare_csi_reservation_plan()` fills `CSI_RESERVE_MIB`, `CSI_MIN_ROOT_MIB`, `CSI_DISK_MIB`, `CSI_START_MIB`, `CSI_SPLIT_DEFERRED`, and `CSI_SPLIT_DEFER_REASON`.
  - `print_resolved_config` shows CSI reservation details when enabled.

- [ ] **Step 1: Write failing calculation and validation tests**

Add these test functions near the disk/replay tests:

```bash
test_prepare_csi_reservation_plan_computes_start() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    lsblk() {
      [[ "$*" == "-bndo SIZE /dev/nvme0n1" ]] && printf "2199023255552\n"
    }
    DRY_RUN=0
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL="S63CNF0X212063"
    CSI_RESERVE_SIZE_RAW="800G"
    CSI_MIN_ROOT_SIZE_RAW="120GiB"
    CSI_PART_LABEL="openshift-csi"
    prepare_csi_reservation_plan
    [[ "${CSI_DISK_MIB}" == "2097152" ]]
    [[ "${CSI_RESERVE_MIB}" == "819200" ]]
    [[ "${CSI_MIN_ROOT_MIB}" == "122880" ]]
    [[ "${CSI_START_MIB}" == "1277952" ]]
    [[ "${CSI_SPLIT_DEFERRED}" == "0" ]]
  '
}

test_prepare_csi_reservation_plan_rejects_small_root_side() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    lsblk() {
      [[ "$*" == "-bndo SIZE /dev/nvme0n1" ]] && printf "214748364800\n"
    }
    DRY_RUN=0
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL="S63CNF0X212063"
    CSI_RESERVE_SIZE_RAW="100G"
    CSI_MIN_ROOT_SIZE_RAW="120GiB"
    CSI_PART_LABEL="openshift-csi"
    ! prepare_csi_reservation_plan
  ' 2>/dev/null
}

test_prepare_csi_reservation_plan_rejects_real_run_without_serial() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DRY_RUN=0
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL=""
    CSI_RESERVE_SIZE_RAW="800G"
    CSI_MIN_ROOT_SIZE_RAW="120GiB"
    CSI_PART_LABEL="openshift-csi"
    ! prepare_csi_reservation_plan
  ' 2>/dev/null
}

test_prepare_csi_reservation_plan_defers_dry_run_without_serial() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DRY_RUN=1
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL=""
    CSI_RESERVE_SIZE_RAW="800G"
    CSI_MIN_ROOT_SIZE_RAW="120GiB"
    CSI_PART_LABEL="openshift-csi"
    prepare_csi_reservation_plan
    [[ "${CSI_SPLIT_DEFERRED}" == "1" ]]
    [[ "${CSI_SPLIT_DEFER_REASON}" == *"install disk serial"* ]]
    [[ -z "${CSI_START_MIB}" ]]
  '
}

test_print_resolved_config_includes_csi_split() {
  local output
  output="$(HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    OCP_VERSION="4.22.1"
    PULL_SECRET_FILE="/root/pull-secret.json"
    BASE_DOMAIN="example.com"
    CLUSTER_NAME="sno"
    DEFAULT_IFACE="eth0"
    ACTIVE_V4=1
    ACTIVE_V6=0
    IP_WITH_PREFIX="192.0.2.10/24"
    GATEWAY="192.0.2.1"
    MAC_ADDR="00:11:22:33:44:55"
    MACHINE_NETWORK="192.0.2.0/24"
    RENDEZVOUS_IP="192.0.2.10"
    NODE_HOSTNAME="node.example.com"
    DNS_DISPLAY="192.0.2.53 "
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL="S63CNF0X212063"
    SSH_PUBLIC_KEY_FILE="/root/id.pub"
    ARTIFACT_DIR="/root"
    BIN_DIR="/usr/local/bin"
    CSI_RESERVE_SIZE_RAW="800G"
    CSI_MIN_ROOT_SIZE_RAW="120GiB"
    CSI_PART_LABEL="openshift-csi"
    CSI_DISK_MIB="2097152"
    CSI_RESERVE_MIB="819200"
    CSI_MIN_ROOT_MIB="122880"
    CSI_START_MIB="1277952"
    CSI_SPLIT_DEFERRED=0
    print_resolved_config
  ')"
  [[ "$output" == *"CSI reserve size:"* ]] || return 1
  [[ "$output" == *"800G (819200 MiB)"* ]] || return 1
  [[ "$output" == *"CSI partition start: 1277952 MiB"* ]] || return 1
  [[ "$output" == *"/dev/disk/by-partlabel/openshift-csi"* ]] || return 1
}
```

Register the tests:

```bash
run_test "prepare_csi_reservation_plan computes start" test_prepare_csi_reservation_plan_computes_start
run_test "prepare_csi_reservation_plan rejects small root side" test_prepare_csi_reservation_plan_rejects_small_root_side
run_test "prepare_csi_reservation_plan rejects real run without serial" test_prepare_csi_reservation_plan_rejects_real_run_without_serial
run_test "prepare_csi_reservation_plan defers dry-run without serial" test_prepare_csi_reservation_plan_defers_dry_run_without_serial
run_test "print_resolved_config includes CSI split" test_print_resolved_config_includes_csi_split
```

- [ ] **Step 2: Run tests to verify the new tests fail**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the new calculation/output tests report `not ok` because the functions and output fields do not exist.

- [ ] **Step 3: Add disk-size and planning functions**

Add these functions after `validate_csi_part_label`:

```bash
read_install_disk_size_mib() {
  local disk="$1"
  local bytes

  bytes="$(lsblk -bndo SIZE "$disk" 2>/dev/null | awk 'NR==1 {print $1; exit}' || true)"
  if [[ ! "$bytes" =~ ^[0-9]+$ || "$bytes" -le 0 ]]; then
    return 1
  fi

  printf '%s\n' "$((bytes / 1048576))"
}

defer_csi_split_validation() {
  CSI_SPLIT_DEFERRED=1
  CSI_SPLIT_DEFER_REASON="$1"
  CSI_DISK_MIB=""
  CSI_START_MIB=""
}

prepare_csi_reservation_plan() {
  local disk_mib

  CSI_RESERVE_MIB=""
  CSI_MIN_ROOT_MIB=""
  CSI_DISK_MIB=""
  CSI_START_MIB=""
  CSI_SPLIT_DEFERRED=0
  CSI_SPLIT_DEFER_REASON=""

  csi_reservation_enabled || return 0

  CSI_RESERVE_MIB="$(parse_csi_size_mib "$CSI_RESERVE_SIZE_RAW" "--csi-reserve-size")" || return 1
  CSI_MIN_ROOT_MIB="$(parse_csi_size_mib "$CSI_MIN_ROOT_SIZE_RAW" "--csi-min-root-size")" || return 1
  validate_csi_part_label "$CSI_PART_LABEL" || return 1

  if [[ -z "${INSTALL_DISK_SERIAL:-}" ]]; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      defer_csi_split_validation "install disk serial is unavailable"
      return 0
    fi
    die "CSI reservation requires a serial-backed install disk. Use --disk-serial <serial> or a disk that exposes a serial."
    return 1
  fi

  if ! disk_mib="$(read_install_disk_size_mib "$INSTALL_DISK")"; then
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      defer_csi_split_validation "install disk size is unavailable"
      return 0
    fi
    die "Cannot determine size for install disk ${INSTALL_DISK}; disable CSI reservation or retry on the rescue host."
    return 1
  fi

  CSI_DISK_MIB="$disk_mib"
  CSI_START_MIB="$((CSI_DISK_MIB - CSI_RESERVE_MIB))"

  if (( CSI_START_MIB <= 0 )); then
    die "--csi-reserve-size ${CSI_RESERVE_SIZE_RAW} is larger than install disk ${INSTALL_DISK}."
    return 1
  fi

  if (( CSI_START_MIB < CSI_MIN_ROOT_MIB )); then
    die "CSI reservation leaves ${CSI_START_MIB} MiB before the partition, below --csi-min-root-size ${CSI_MIN_ROOT_MIB} MiB."
    return 1
  fi
}
```

- [ ] **Step 4: Call planning before resolved-config output**

In `main`, after the `INSTALL_DISK_SERIAL` override block and before `print_resolved_config`, add:

```bash
  prepare_csi_reservation_plan
```

The surrounding block should remain:

```bash
  INSTALL_DISK="$(resolve_install_disk)"
  INSTALL_DISK_SERIAL="$(lsblk -ndo SERIAL "$INSTALL_DISK" 2>/dev/null | awk 'NR==1 { sub(/^[[:space:]]+/, "", $0); sub(/[[:space:]]+$/, "", $0); print; exit }' || true)"
  if [[ -n "${DISK_SERIAL_OVERRIDE:-}" ]]; then
    INSTALL_DISK_SERIAL="$DISK_SERIAL_OVERRIDE"
  fi
  prepare_csi_reservation_plan
  print_resolved_config
```

- [ ] **Step 5: Add resolved-config CSI output**

In `print_resolved_config`, after the install disk serial line, add:

```bash
  if csi_reservation_enabled; then
    echo "  CSI reserve size:  ${CSI_RESERVE_SIZE_RAW} (${CSI_RESERVE_MIB:-unknown} MiB)"
    echo "  CSI min root size: ${CSI_MIN_ROOT_SIZE_RAW} (${CSI_MIN_ROOT_MIB:-unknown} MiB)"
    echo "  CSI part label:    ${CSI_PART_LABEL}"
    echo "  CSI device path:   /dev/disk/by-partlabel/${CSI_PART_LABEL}"
    if [[ "${CSI_SPLIT_DEFERRED:-0}" == "1" ]]; then
      echo "  CSI split:         deferred (${CSI_SPLIT_DEFER_REASON})"
    else
      echo "  Install disk size: ${CSI_DISK_MIB} MiB"
      echo "  CSI partition start: ${CSI_START_MIB} MiB"
    fi
  fi
```

- [ ] **Step 6: Run calculation/output tests**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the five new calculation/output tests pass. Existing tests must still pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Validate CSI boot disk reservation"
```

---

### Task 3: Generate the Day-1 MachineConfig and Integrate Main Flow

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh`
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `CSI_PART_LABEL`, `CSI_START_MIB`, `INSTALL_DIR`, `csi_reservation_enabled`.
- Produces:
  - Function `generate_csi_raw_partition_machine_config()` writes `${INSTALL_DIR}/openshift/98-master-csi-raw-partition.yaml`.
  - Main flow calls the writer after `generate_agent_config` and before `openshift-install agent create pxe-files`.

- [ ] **Step 1: Write failing MachineConfig tests**

Add these test functions near the existing generated-config tests:

```bash
test_generate_csi_raw_partition_machine_config() {
  local temp_dir config status
  temp_dir="$(mktemp -d)"

  INSTALL_DIR="${temp_dir}/install" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    CSI_RESERVE_SIZE_RAW="800G"
    CSI_PART_LABEL="openshift-csi"
    CSI_START_MIB="1277952"
    generate_csi_raw_partition_machine_config
  '
  status=$?
  config="$(<"${temp_dir}/install/openshift/98-master-csi-raw-partition.yaml")"

  local ret=0
  [[ "${status}" -eq 0 ]] || ret=1
  [[ "${config}" == *"apiVersion: machineconfiguration.openshift.io/v1"* ]] || ret=1
  [[ "${config}" == *"kind: MachineConfig"* ]] || ret=1
  [[ "${config}" == *"name: 98-master-csi-raw-partition"* ]] || ret=1
  [[ "${config}" == *"machineconfiguration.openshift.io/role: master"* ]] || ret=1
  [[ "${config}" == *"version: 3.4.0"* ]] || ret=1
  [[ "${config}" == *"device: /dev/disk/by-id/coreos-boot-disk"* ]] || ret=1
  [[ "${config}" == *"label: openshift-csi"* ]] || ret=1
  [[ "${config}" == *"number: 0"* ]] || ret=1
  [[ "${config}" == *"startMiB: 1277952"* ]] || ret=1
  [[ "${config}" != *"sizeMiB"* ]] || ret=1
  [[ "${config}" != *"wipePartitionEntry"* ]] || ret=1
  [[ "${config}" != *"wipeTable"* ]] || ret=1
  [[ "${config}" != *"filesystems"* ]] || ret=1

  rm -rf "${temp_dir}"
  return "${ret}"
}

test_generate_csi_raw_partition_machine_config_skips_when_disabled() {
  local temp_dir status
  temp_dir="$(mktemp -d)"

  INSTALL_DIR="${temp_dir}/install" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    CSI_RESERVE_SIZE_RAW=""
    generate_csi_raw_partition_machine_config
    [[ ! -e "'"${temp_dir}"'/install/openshift/98-master-csi-raw-partition.yaml" ]]
  '
  status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}
```

Register the tests:

```bash
run_test "generate_csi_raw_partition_machine_config writes manifest" test_generate_csi_raw_partition_machine_config
run_test "generate_csi_raw_partition_machine_config skips when disabled" test_generate_csi_raw_partition_machine_config_skips_when_disabled
```

- [ ] **Step 2: Run tests to verify the new tests fail**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the new MachineConfig tests report `not ok` because the function does not exist.

- [ ] **Step 3: Add the MachineConfig writer**

Add this function after `generate_agent_config`:

```bash
generate_csi_raw_partition_machine_config() {
  local manifest_path

  csi_reservation_enabled || return 0

  if [[ -z "${CSI_START_MIB:-}" || "${CSI_SPLIT_DEFERRED:-0}" == "1" ]]; then
    die "CSI reservation plan is not fully resolved; refusing to write MachineConfig."
    return 1
  fi

  mkdir -p "${INSTALL_DIR}/openshift"
  manifest_path="${INSTALL_DIR}/openshift/98-master-csi-raw-partition.yaml"

  cat > "$manifest_path" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 98-master-csi-raw-partition
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      disks:
      - device: /dev/disk/by-id/coreos-boot-disk
        partitions:
        - label: ${CSI_PART_LABEL}
          number: 0
          startMiB: ${CSI_START_MIB}
EOF

  chmod 600 "$manifest_path"
  echo "  Written: ${manifest_path}"
}
```

- [ ] **Step 4: Integrate the writer before PXE generation**

In `main`, after `generate_agent_config`, insert the conditional manifest step and renumber following step labels:

```bash
  log_step "Step 4: Generating agent-config.yaml"
  generate_agent_config

  if csi_reservation_enabled; then
    log_step "Step 5: Generating CSI raw partition MachineConfig"
    generate_csi_raw_partition_machine_config
  fi

  log_step "Step 6: Running openshift-install agent create pxe-files"
```

Update later log labels in the same function to keep the sequence consistent:

```bash
  log_step "Step 7: Copying boot artifacts to ${ARTIFACT_DIR}"
```

```bash
  log_step "Step 8: Cluster credentials"
```

- [ ] **Step 5: Write and run an integration-order test**

Add this test near the main dry-run tests:

```bash
test_main_writes_csi_manifest_before_pxe_generation() {
  local temp_dir status
  temp_dir="$(mktemp -d)"
  printf '{}\n' > "${temp_dir}/pull-secret.json"

  WORKDIR="${temp_dir}/work" INSTALL_DIR="${temp_dir}/work/install" SNO_CONFIG_FILE="${temp_dir}/config" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    prompt_for_missing_config() { :; }
    validate_required_inputs() { :; }
    require_arch() { :; }
    warn_if_not_debian_12() { :; }
    require_commands() { :; }
    validate_network_overrides() { :; }
    validate_pull_secret() { :; }
    resolve_ssh_public_key() { SSH_PUB_KEY="ssh-ed25519 AAAATEST"; }
    resolve_network_config() {
      ACTIVE_V4=1
      ACTIVE_V6=0
      DEFAULT_IFACE="eth0"
      IP_WITH_PREFIX="192.0.2.10/24"
      IP_ADDR="192.0.2.10"
      PREFIX_LEN="24"
      GATEWAY="192.0.2.1"
      MACHINE_NETWORK="192.0.2.0/24"
      RENDEZVOUS_IP="192.0.2.10"
      NODE_HOSTNAME="node.example.com"
      MAC_ADDR="00:11:22:33:44:55"
      DNS_SERVERS=("192.0.2.53")
      DNS_SERVERS_RAW="192.0.2.53"
      DNS_DISPLAY="192.0.2.53 "
      NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"}]"
    }
    resolve_install_disk() { printf "/dev/nvme0n1\n"; }
    lsblk() {
      case "$*" in
        "-ndo SERIAL /dev/nvme0n1") printf "S63CNF0X212063\n" ;;
        "-bndo SIZE /dev/nvme0n1") printf "2199023255552\n" ;;
      esac
    }
    save_config() { :; }
    require_root() { :; }
    confirm_or_die() { :; }
    ensure_cargo_available() { :; }
    ensure_nmstatectl() { :; }
    nmstatectl() { printf "nmstatectl 2.2.60\n"; }
    install_ocp_tool() { :; }
    oc() { printf "Client Version: 4.22.1\n"; }
    openshift-install() {
      [[ -f "${INSTALL_DIR}/openshift/98-master-csi-raw-partition.yaml" ]] || exit 42
      mkdir -p "${INSTALL_DIR}/boot-artifacts"
      : > "${INSTALL_DIR}/boot-artifacts/agent.x86_64-vmlinuz"
      : > "${INSTALL_DIR}/boot-artifacts/agent.x86_64-initrd.img"
      : > "${INSTALL_DIR}/boot-artifacts/agent.x86_64-rootfs.img"
    }
    print_cluster_credentials() { :; }
    print_next_step_hint() { :; }

    main --yes --csi-reserve-size 800G --hostname node.example.com --ssh-public-key-file /root/id.pub 4.22.1 "'"${temp_dir}"'/pull-secret.json" example.com sno
  ' >/dev/null
  status=$?

  [[ -f "${temp_dir}/work/install/openshift/98-master-csi-raw-partition.yaml" ]] || status=1
  rm -rf "${temp_dir}"
  return "${status}"
}
```

Register it:

```bash
run_test "main writes CSI manifest before PXE generation" test_main_writes_csi_manifest_before_pxe_generation
```

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: the MachineConfig and integration-order tests pass. Existing tests must still pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Generate CSI raw partition MachineConfig"
```

---

### Task 4: Add Replay Output and README Documentation

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh`
- Modify: `README.md`
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `CSI_RESERVE_SIZE_RAW`, `CSI_MIN_ROOT_SIZE_RAW`, `CSI_PART_LABEL`, `csi_reservation_enabled`.
- Produces: replay command includes CSI flags only when CSI reservation is enabled.

- [ ] **Step 1: Write failing replay tests**

Add these tests near the existing replay tests:

```bash
test_replay_emits_csi_flags_when_enabled() {
  local output
  output="$(HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_NAME="hetzner-sno-prepare-pxe.sh"
    OCP_VERSION="4.22.1"
    PULL_SECRET_FILE="/root/pull-secret.json"
    BASE_DOMAIN="example.com"
    CLUSTER_NAME="sno"
    NODE_HOSTNAME="node.example.com"
    SSH_PUBLIC_KEY_FILE="/root/id.pub"
    DEFAULT_IFACE="eth0"
    ACTIVE_V4=1
    ACTIVE_V6=0
    IP_WITH_PREFIX="192.0.2.10/24"
    GATEWAY="192.0.2.1"
    RENDEZVOUS_IP="192.0.2.10"
    DNS_SERVERS=("192.0.2.53")
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL="S63CNF0X212063"
    ARTIFACT_DIR="/root"
    BIN_DIR="/usr/local/bin"
    CLUSTER_NETWORKS=()
    SERVICE_NETWORKS=()
    CSI_RESERVE_SIZE_RAW="800G"
    CSI_MIN_ROOT_SIZE_RAW="120GiB"
    CSI_PART_LABEL="openshift-csi"
    print_replay_command
  ')"
  [[ "$output" == *"--csi-reserve-size 800G"* ]] || return 1
  [[ "$output" == *"--csi-min-root-size 120GiB"* ]] || return 1
  [[ "$output" == *"--csi-part-label openshift-csi"* ]] || return 1
}

test_replay_omits_csi_flags_when_disabled() {
  local output
  output="$(HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_NAME="hetzner-sno-prepare-pxe.sh"
    OCP_VERSION="4.22.1"
    PULL_SECRET_FILE="/root/pull-secret.json"
    BASE_DOMAIN="example.com"
    CLUSTER_NAME="sno"
    NODE_HOSTNAME="node.example.com"
    SSH_PUBLIC_KEY_FILE="/root/id.pub"
    DEFAULT_IFACE="eth0"
    ACTIVE_V4=1
    ACTIVE_V6=0
    IP_WITH_PREFIX="192.0.2.10/24"
    GATEWAY="192.0.2.1"
    RENDEZVOUS_IP="192.0.2.10"
    DNS_SERVERS=("192.0.2.53")
    INSTALL_DISK="/dev/nvme0n1"
    INSTALL_DISK_SERIAL="S63CNF0X212063"
    ARTIFACT_DIR="/root"
    BIN_DIR="/usr/local/bin"
    CLUSTER_NETWORKS=()
    SERVICE_NETWORKS=()
    CSI_RESERVE_SIZE_RAW=""
    print_replay_command
  ')"
  [[ "$output" != *"--csi-reserve-size"* ]] || return 1
  [[ "$output" != *"--csi-min-root-size"* ]] || return 1
  [[ "$output" != *"--csi-part-label"* ]] || return 1
}
```

Register them:

```bash
run_test "replay emits CSI flags when enabled" test_replay_emits_csi_flags_when_enabled
run_test "replay omits CSI flags when disabled" test_replay_omits_csi_flags_when_disabled
```

- [ ] **Step 2: Run tests to verify replay test failure**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: `replay emits CSI flags when enabled` reports `not ok`.

- [ ] **Step 3: Add CSI flags to replay command**

In `print_replay_command`, after the disk selector block and before artifact/bin dir blocks, add:

```bash
  if csi_reservation_enabled; then
    lines+=("  --csi-reserve-size $(printf '%q' "$CSI_RESERVE_SIZE_RAW") \\")
    lines+=("  --csi-min-root-size $(printf '%q' "$CSI_MIN_ROOT_SIZE_RAW") \\")
    lines+=("  --csi-part-label $(printf '%q' "$CSI_PART_LABEL") \\")
  fi
```

- [ ] **Step 4: Update README**

In `README.md`, extend the prepare-script flag section after the disk-selection bullets with:

```markdown
For OpenShift 4.14-or-newer direct agent PXE installs, the prepare script can
also reserve part of the selected boot disk as one raw, unformatted partition
for LVMS or another CSI operator:

- `--csi-reserve-size <size>` — Enable the reservation and request the raw
  partition size, for example `800G`.
- `--csi-min-root-size <size>` — Minimum OpenShift-side disk offset before the
  raw partition. The default is `120GiB`.
- `--csi-part-label <label>` — GPT PARTLABEL for the raw partition. The default
  is `openshift-csi`, exposed after installation as
  `/dev/disk/by-partlabel/openshift-csi`.

The script writes a day-1 MachineConfig under the install directory before
`openshift-install agent create pxe-files` runs. It does not format the
partition, install LVMS, generate an `LVMCluster`, or create a StorageClass.
Point the storage operator at the labeled block device explicitly. Real runs
with CSI reservation require a serial-backed install disk; use
`--disk-serial <serial>` for automation.
```

In the agent-based workflow examples, add a CSI example after the disk-pinning example:

```bash
# Reserve the tail of the boot disk for LVMS/CSI as /dev/disk/by-partlabel/openshift-csi:
# ./hetzner-sno-prepare-pxe.sh --disk-serial S63CNF0X212063 --csi-reserve-size 800G \
#   --hostname sno.example.com --ssh-public-key-file /root/.ssh/id_rsa.pub \
#   4.22.1 /root/pull-secret.json example.com sno
```

In the warnings list near the end, add:

```markdown
- `--csi-reserve-size` is an install-time partitioning feature. Validate it on
  the target OpenShift minor release and target server class before relying on
  it. Editing the generated MachineConfig after installation is not a supported
  way to repartition a running node.
```

- [ ] **Step 5: Run replay tests and docs sanity checks**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
rg -n -- "--csi-reserve-size|openshift-csi|LVMCluster|4.14" README.md
```

Expected: replay tests pass, all existing tests pass, and `rg` shows the new README section and example.

- [ ] **Step 6: Commit Task 4**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh README.md
git commit -m "Document CSI boot disk reservation"
```

---

### Task 5: Final Verification and Review Preparation

**Files:**
- Verify: `hetzner-sno-prepare-pxe.sh`
- Verify: `tests/test-hetzner-sno-prepare-pxe.sh`
- Verify: `tests/test-hetzner-sno-hardening.sh`
- Verify: `README.md`

**Interfaces:**
- Consumes: all previous tasks.
- Produces: clean final branch ready for code review.

- [ ] **Step 1: Run shell syntax checks**

Run:

```bash
bash -n hetzner-sno-prepare-pxe.sh hetzner-sno-provision-host-agentbased.sh hetzner-sno-provision-host.sh tests/test-hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-hardening.sh scripts/test-debian12-container.sh
```

Expected: command exits `0` with no output.

- [ ] **Step 2: Run focused prepare-script tests**

Run:

```bash
./tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: all tests print `ok - ...` and the command exits `0`.

- [ ] **Step 3: Run hardening regression tests**

Run:

```bash
./tests/test-hetzner-sno-hardening.sh
```

Expected: all tests print `ok - ...` and the command exits `0`.

- [ ] **Step 4: Check for whitespace and stale forbidden manifest fields**

Run:

```bash
git diff --check
rg -n "wipePartitionEntry:|sizeMiB:|wipeTable: true|filesystems:" hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh README.md
```

Expected: `git diff --check` exits `0`; the `rg` command exits `1` with no matches.

- [ ] **Step 5: Inspect final diff**

Run:

```bash
git diff --stat HEAD~4..HEAD
git diff HEAD~4..HEAD -- hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh README.md
```

Expected: diff contains only CSI reservation implementation, tests, and README documentation.

- [ ] **Step 6: Commit verification note if a tracked doc changed during verification**

If verification required no file edits, do not create a commit. If a file was edited to fix verification findings, run:

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh README.md
git commit -m "Fix CSI reservation verification findings"
```

Expected: branch contains focused task commits and `git status -sb` reports no unstaged changes.

---

## Self-Review

Spec coverage:

- Explicit-only enablement is covered by Task 1 parser tests and orphan-flag failures.
- Size suffix parsing and label validation are covered by Task 1.
- Disk size calculation, 2 TiB/800 GiB `startMiB: 1277952`, min-root guard, serial requirement, and dry-run deferral are covered by Task 2.
- User-visible resolved configuration is covered by Task 2.
- MachineConfig shape, `/dev/disk/by-id/coreos-boot-disk`, `number: 0`, omitted `sizeMiB`, omitted `wipePartitionEntry`, omitted `wipeTable`, and omitted `filesystems` are covered by Task 3.
- Manifest write ordering after `safe_prepare_install_dir` and before PXE generation is covered by Task 3 integration test.
- Replay command behavior is covered by Task 4.
- README documentation, OpenShift 4.14+ scope, raw unformatted partition, LVMS non-generation, serial-backed targeting, and day-1-only warning are covered by Task 4.
- Full syntax, test, and stale-field verification are covered by Task 5.

Red-flag scan:

- No red-flag markers or unspecified implementation steps remain.
- Every task includes exact file paths, function names, commands, and expected results.

Type and name consistency:

- `CSI_RESERVE_SIZE_RAW`, `CSI_MIN_ROOT_SIZE_RAW`, `CSI_MIN_ROOT_SIZE_SET`, `CSI_PART_LABEL`, `CSI_PART_LABEL_SET`, `CSI_RESERVE_MIB`, `CSI_MIN_ROOT_MIB`, `CSI_DISK_MIB`, `CSI_START_MIB`, `CSI_SPLIT_DEFERRED`, and `CSI_SPLIT_DEFER_REASON` are initialized in Task 1 and consumed consistently in Tasks 2-4.
- `prepare_csi_reservation_plan` produces the values consumed by `print_resolved_config` and `generate_csi_raw_partition_machine_config`.
- `generate_csi_raw_partition_machine_config` is called only after the install directory has been recreated and after `generate_agent_config`.
