#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/hetzner-sno-prepare-pxe.sh"
FAILURES=0

run_test() {
  local name="$1"
  shift

  if "$@"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name"
    FAILURES=$((FAILURES + 1))
  fi
}

test_can_source_helper_functions() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    declare -F main >/dev/null
    declare -F parse_args >/dev/null
    declare -F normalize_disk_device >/dev/null
    declare -F list_install_disk_candidates >/dev/null
    declare -F format_disk_candidate_table >/dev/null
    declare -F prompt_install_disk_choice >/dev/null
    declare -F detect_install_disk >/dev/null
    declare -F resolve_install_disk >/dev/null
    declare -F ocp_archive_name >/dev/null
    declare -F version_matches_requested >/dev/null
    declare -F fetch_ocp_checksums >/dev/null
    declare -F verify_download_checksum >/dev/null
  '
}

test_print_cluster_credentials_outputs_auth_files() {
  local temp_dir
  local output_file
  local status
  local output

  temp_dir="$(mktemp -d)"
  output_file="$(mktemp)"
  mkdir -p "${temp_dir}/install/auth"

  printf 'super-secret-password\n' > "${temp_dir}/install/auth/kubeadmin-password"
  cat > "${temp_dir}/install/auth/kubeconfig" <<'EOF'
apiVersion: v1
clusters:
- cluster:
    server: https://api.example.com:6443
  name: example
EOF

  WORKDIR="${temp_dir}/work" INSTALL_DIR="${temp_dir}/install" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    print_cluster_credentials
  ' > "${output_file}"
  status=$?
  output="$(<"${output_file}")"

  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"kubeadmin password: super-secret-password"* ]] || return 1
  [[ "${output}" == *"Save the content of ${temp_dir}/install/auth/kubeconfig before rebooting"* ]] || return 1
  [[ "${output}" == *"--- kubeconfig start ---"* ]] || return 1
  [[ "${output}" == *"server: https://api.example.com:6443"* ]] || return 1
  [[ "${output}" == *"--- kubeconfig end ---"* ]] || return 1

  rm -rf "${temp_dir}" "${output_file}"
}

test_parse_args_accepts_disk_device_override() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    parse_args --disk-device /dev/nvme0n1 4.16.15 /tmp/pull-secret.json example.com sno 192.0.2.10
    [[ "${DISK_DEVICE_OVERRIDE}" == "/dev/nvme0n1" ]]
    [[ "${OCP_VERSION}" == "4.16.15" ]]
    [[ "${PULL_SECRET_FILE}" == "/tmp/pull-secret.json" ]]
    [[ "${BASE_DOMAIN}" == "example.com" ]]
    [[ "${CLUSTER_NAME}" == "sno" ]]
    [[ "${OVERRIDE_IP}" == "192.0.2.10" ]]
  '
}

test_detect_install_disk_normalizes_root_partition() {
  local stub_dir
  local status
  stub_dir="$(mktemp -d)"

  cat > "${stub_dir}/findmnt" <<'EOF'
#!/bin/bash
echo "/dev/nvme0n1p1"
EOF

  cat > "${stub_dir}/lsblk" <<'EOF'
#!/bin/bash
case "$*" in
  *"TYPE /dev/nvme0n1p1"*)
    echo "part"
    ;;
  *"PKNAME /dev/nvme0n1p1"*)
    echo "nvme0n1"
    ;;
  *"TYPE /dev/nvme0n1"*)
    echo "disk"
    ;;
  *)
    exit 1
    ;;
esac
EOF

  chmod +x "${stub_dir}/findmnt" "${stub_dir}/lsblk"

  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    [[ "$(detect_install_disk)" == "/dev/nvme0n1" ]]
  '
  status=$?

  rm -rf "${stub_dir}"
  return "${status}"
}

test_detect_install_disk_prompts_for_multi_disk_selection() {
  local stub_dir
  local status
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
  *"SIZE /dev/nvme0n1"*|*"SIZE /dev/nvme1n1"*|*"SIZE /dev/nvme2n1"*)
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

test_detect_install_disk_lists_candidates_when_prompting_is_unavailable() {
  local stub_dir
  local err_file
  local status
  local err_output
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

test_detect_install_disk_autopicks_single_candidate() {
  local stub_dir
  local status
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
  local stub_dir
  local status
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

test_prompt_install_disk_choice_aborts_on_eof() {
  local err_file
  local status
  local err_output
  err_file="$(mktemp)"

  timeout 2 bash -c '
    source "'"${SCRIPT}"'"
    prompt_install_disk_choice /dev/nvme0n1 /dev/nvme1n1 </dev/null
  ' > /dev/null 2>"${err_file}"
  status=$?
  err_output="$(<"${err_file}")"

  [[ "${status}" -eq 1 ]]
  [[ "${err_output}" == *"Input closed while selecting install disk."* ]]

  rm -f "${err_file}"
}

test_detect_install_disk_propagates_prompt_failure() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    findmnt() { printf "overlay\n"; }
    can_prompt() { return 0; }
    list_install_disk_candidates() { printf "/dev/nvme0n1\n/dev/nvme1n1\n"; }
    prompt_called=0
    prompt_install_disk_choice() { prompt_called=1; return 1; }
    ! detect_install_disk
    [[ "${prompt_called}" -eq 1 ]]
  '
}

test_main_allows_interactive_multi_disk_selection() {
  local stub_dir
  local temp_dir
  local output_file
  local status
  stub_dir="$(mktemp -d)"
  temp_dir="$(mktemp -d)"
  output_file="${temp_dir}/script-output.log"

  printf '{}\n' > "${temp_dir}/pull-secret.json"

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

  cat > "${stub_dir}/ip" <<'EOF'
#!/bin/bash
case "$*" in
  "route show default")
    printf 'default via 192.0.2.1 dev eth0 proto static\n'
    ;;
  "-4 addr show dev eth0")
    printf '    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0\n'
    ;;
  "link show eth0")
    printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500\n'
    printf '    link/ether 00:11:22:33:44:55 brd ff:ff:ff:ff:ff:ff\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF

  cat > "${stub_dir}/hostname" <<'EOF'
#!/bin/bash
printf 'node.example.com\n'
EOF

  chmod +x "${stub_dir}/findmnt" "${stub_dir}/lsblk" "${stub_dir}/ip" "${stub_dir}/hostname"

  printf '2\n' | PATH="${stub_dir}:${PATH}" HOME="${temp_dir}" script -qfec \
    "bash \"${SCRIPT}\" --dry-run 4.16.15 \"${temp_dir}/pull-secret.json\" example.com sno" \
    /dev/null > "${output_file}" 2>&1
  status=$?

  [[ "${status}" -eq 0 ]]
  [[ "$(<"${output_file}")" == *"Install disk:      /dev/nvme1n1"* ]]

  rm -rf "${stub_dir}" "${temp_dir}"
}

test_ocp_archive_name_uses_versioned_mirror_filenames() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    OCP_VERSION="4.16.15"
    [[ "$(ocp_archive_name oc)" == "openshift-client-linux-4.16.15.tar.gz" ]]
    [[ "$(ocp_archive_name openshift-install)" == "openshift-install-linux-4.16.15.tar.gz" ]]
  '
}

test_version_matches_requested_rejects_mismatch() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    declare -F version_matches_requested >/dev/null
    ! version_matches_requested "4.16.15" "Client Version: 4.16.14"
  '
}

test_fetch_ocp_checksums_returns_path_only() {
  local stub_dir
  local temp_dir
  local status

  stub_dir="$(mktemp -d)"
  temp_dir="$(mktemp -d)"

  cat > "${stub_dir}/curl" <<'EOF'
#!/bin/bash
output=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -o|--output)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$output" ]] || exit 1
printf 'sha256 sentinel\n' > "$output"
exit 0
EOF

  chmod +x "${stub_dir}/curl"

  PATH="${stub_dir}:${PATH}" WORKDIR="${temp_dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    OCP_VERSION="4.16.15"
    OCP_MIRROR="https://mirror.example.invalid"
    [[ "$(fetch_ocp_checksums)" == "'"${temp_dir}"'/sha256sum.txt" ]]
    [[ -f "'"${temp_dir}"'/sha256sum.txt" ]]
  ' 2>/dev/null
  status=$?

  rm -rf "${stub_dir}" "${temp_dir}"
  return "${status}"
}

test_verify_download_checksum_detects_mismatch() {
  local temp_dir
  local status
  temp_dir="$(mktemp -d)"

  printf 'test payload\n' > "${temp_dir}/payload.tar.gz"
  printf '0000000000000000000000000000000000000000000000000000000000000000  payload.tar.gz\n' > "${temp_dir}/sha256sum.txt"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    declare -F verify_download_checksum >/dev/null
    ! verify_download_checksum "'"${temp_dir}/payload.tar.gz"'" "'"${temp_dir}/sha256sum.txt"'"
  ' 2>/dev/null
  status=$?

  rm -rf "${temp_dir}"
  return "${status}"
}

test_parse_args_leaves_cluster_name_empty_when_omitted() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    parse_args 4.16.15 /tmp/pull-secret.json example.com
    [[ -z "${CLUSTER_NAME}" ]]
  '
}

test_find_pull_secret_candidates_returns_matching_files() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "${temp_dir}/subdir"
  printf '{}' > "${temp_dir}/pull-secret.json"
  printf '{}' > "${temp_dir}/subdir/pull-secret.txt"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    mapfile -t results < <(find_pull_secret_candidates "'"${temp_dir}"'")
    [[ "${#results[@]}" -eq 2 ]] || { echo "expected 2, got ${#results[@]}"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_find_pull_secret_candidates_returns_nothing_when_absent() {
  local temp_dir
  temp_dir="$(mktemp -d)"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    mapfile -t results < <(find_pull_secret_candidates "'"${temp_dir}"'")
    [[ "${#results[@]}" -eq 0 ]] || { echo "expected 0, got ${#results[@]}"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_prompt_file_choice_selects_by_number() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    result="$(printf "2\n" | prompt_file_choice "pull secret" /root/pull-secret.json /root/sub/pull-secret.txt)"
    [[ "$result" == "/root/sub/pull-secret.txt" ]] || { echo "got: $result"; exit 1; }
  '
}

test_prompt_file_choice_aborts_on_eof() {
  local err_file
  local err_output
  err_file="$(mktemp)"

  timeout 2 bash -c '
    source "'"${SCRIPT}"'"
    prompt_file_choice "pull secret" /root/pull-secret.json /root/sub/pull-secret.txt </dev/null
  ' > /dev/null 2>"${err_file}"
  local status=$?
  err_output="$(<"${err_file}")"

  [[ "${status}" -eq 1 ]] || return 1
  [[ "${err_output}" == *"Input closed while selecting pull secret."* ]] || return 1

  rm -f "${err_file}"
}

test_parse_args_sets_disk_serial_override() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    parse_args --disk-serial S63CNF0X212063 4.16.15 /tmp/pull-secret.json example.com sno 192.0.2.10
    [[ "${DISK_SERIAL_OVERRIDE}" == "S63CNF0X212063" ]]
  '
}

run_test "can source helper functions" test_can_source_helper_functions
run_test "print_cluster_credentials outputs auth files" test_print_cluster_credentials_outputs_auth_files
run_test "parse_args accepts disk override" test_parse_args_accepts_disk_device_override
run_test "parse_args leaves cluster name empty when omitted" test_parse_args_leaves_cluster_name_empty_when_omitted
run_test "parse_args sets disk serial override" test_parse_args_sets_disk_serial_override
run_test "detect_install_disk normalizes root partition" test_detect_install_disk_normalizes_root_partition
run_test "detect_install_disk prompts for multi-disk selection" test_detect_install_disk_prompts_for_multi_disk_selection
run_test "detect_install_disk lists candidates when prompting is unavailable" test_detect_install_disk_lists_candidates_when_prompting_is_unavailable
run_test "detect_install_disk auto-picks a single candidate" test_detect_install_disk_autopicks_single_candidate
run_test "resolve_install_disk prefers explicit override" test_resolve_install_disk_prefers_explicit_override
run_test "find_disk_by_serial resolves device" test_find_disk_by_serial_resolves_device
run_test "find_disk_by_serial dies when absent" test_find_disk_by_serial_dies_when_absent
run_test "find_disk_by_serial dies when ambiguous" test_find_disk_by_serial_dies_when_ambiguous
run_test "resolve_install_disk prefers serial over device" test_resolve_install_disk_prefers_serial_over_device
run_test "prompt_install_disk_choice aborts on EOF" test_prompt_install_disk_choice_aborts_on_eof
run_test "detect_install_disk propagates prompt failure" test_detect_install_disk_propagates_prompt_failure
run_test "main allows interactive multi-disk selection" test_main_allows_interactive_multi_disk_selection
run_test "archive names are versioned" test_ocp_archive_name_uses_versioned_mirror_filenames
run_test "version check rejects mismatched versions" test_version_matches_requested_rejects_mismatch
run_test "fetch_ocp_checksums returns path only" test_fetch_ocp_checksums_returns_path_only
run_test "checksum verification rejects mismatched payloads" test_verify_download_checksum_detects_mismatch
test_find_ssh_pub_candidates_returns_valid_pub_files() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "${temp_dir}/.ssh"

  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG... user@host\n' > "${temp_dir}/.ssh/id_ed25519.pub"
  printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQAB... user@host\n' > "${temp_dir}/.ssh/id_rsa.pub"
  printf 'not an ssh key\n' > "${temp_dir}/.ssh/gpg-key.pub"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    mapfile -t results < <(find_ssh_pub_candidates "'"${temp_dir}"'")
    [[ "${#results[@]}" -eq 2 ]] || { echo "expected 2, got ${#results[@]}: ${results[*]}"; exit 1; }
    for f in "${results[@]}"; do
      [[ "$f" == *"id_ed25519.pub" || "$f" == *"id_rsa.pub" ]] || { echo "unexpected: $f"; exit 1; }
    done
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_find_ssh_pub_candidates_returns_nothing_when_absent() {
  local temp_dir
  temp_dir="$(mktemp -d)"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    mapfile -t results < <(find_ssh_pub_candidates "'"${temp_dir}"'")
    [[ "${#results[@]}" -eq 0 ]] || { echo "expected 0, got ${#results[@]}"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_find_ssh_pub_candidates_filters_non_ssh_pub_files() {
  local temp_dir
  temp_dir="$(mktemp -d)"

  printf 'ecdsa-sha2-nistp256 AAAAE2VjZHNh... user@host\n' > "${temp_dir}/valid.pub"
  printf 'some random binary content\n' > "${temp_dir}/random.pub"
  printf 'PGP PUBLIC KEY BLOCK\n' > "${temp_dir}/gpg.pub"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    mapfile -t results < <(find_ssh_pub_candidates "'"${temp_dir}"'")
    [[ "${#results[@]}" -eq 1 ]] || { echo "expected 1, got ${#results[@]}: ${results[*]}"; exit 1; }
    [[ "${results[0]}" == *"valid.pub" ]] || { echo "unexpected: ${results[0]}"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

run_test "find_pull_secret_candidates returns matching files" test_find_pull_secret_candidates_returns_matching_files
run_test "find_pull_secret_candidates returns nothing when absent" test_find_pull_secret_candidates_returns_nothing_when_absent
run_test "prompt_file_choice selects by number" test_prompt_file_choice_selects_by_number
run_test "prompt_file_choice aborts on EOF" test_prompt_file_choice_aborts_on_eof
run_test "find_ssh_pub_candidates returns valid pub files" test_find_ssh_pub_candidates_returns_valid_pub_files
run_test "find_ssh_pub_candidates returns nothing when absent" test_find_ssh_pub_candidates_returns_nothing_when_absent
run_test "find_ssh_pub_candidates filters non-SSH pub files" test_find_ssh_pub_candidates_filters_non_ssh_pub_files

test_report_credential_presence_reports_missing() {
  local temp_dir
  temp_dir="$(mktemp -d)"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    HOME="'"${temp_dir}"'"
    output="$(report_credential_presence 2>&1)"
    [[ "$output" == *"Pull secret:"*"NOT FOUND"* ]] || { echo "pull secret line: $output"; exit 1; }
    [[ "$output" == *"SSH public key:"*"NOT FOUND"* ]] || { echo "ssh line: $output"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_report_credential_presence_reports_found() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "${temp_dir}/.ssh"
  printf '{}' > "${temp_dir}/pull-secret.json"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@host\n' > "${temp_dir}/.ssh/id_ed25519.pub"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    HOME="'"${temp_dir}"'"
    output="$(report_credential_presence 2>&1)"
    [[ "$output" == *"Pull secret:"*"found "*"pull-secret.json"* ]] || { echo "pull secret line: $output"; exit 1; }
    [[ "$output" == *"SSH public key:"*"found "*"id_ed25519.pub"* ]] || { echo "ssh line: $output"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_report_credential_presence_reports_explicit_missing_path() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    PULL_SECRET_FILE="/nonexistent/pull-secret.json"
    SSH_PUBLIC_KEY_FILE="/nonexistent/id.pub"
    output="$(report_credential_presence 2>&1)"
    [[ "$output" == *"Pull secret:"*"NOT FOUND at /nonexistent/pull-secret.json"* ]] || { echo "pull secret line: $output"; exit 1; }
    [[ "$output" == *"SSH public key:"*"NOT FOUND at /nonexistent/id.pub"* ]] || { echo "ssh line: $output"; exit 1; }
  '
}

test_report_credential_presence_expands_tilde_for_ssh() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  mkdir -p "${temp_dir}/.ssh"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 user@host\n' > "${temp_dir}/.ssh/id_ed25519.pub"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    HOME="'"${temp_dir}"'"
    SSH_PUBLIC_KEY_FILE="~/.ssh/id_ed25519.pub"
    output="$(report_credential_presence 2>&1)"
    [[ "$output" == *"SSH public key:"*"found ~/.ssh/id_ed25519.pub"* ]] || { echo "ssh line: $output"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_report_credential_presence_ignores_stale_saved_path() {
  local temp_dir
  temp_dir="$(mktemp -d)"
  printf '{}' > "${temp_dir}/pull-secret.json"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    HOME="'"${temp_dir}"'"
    _SAVED[PULL_SECRET_FILE]="/gone/pull-secret.json"
    output="$(report_credential_presence 2>&1)"
    # Stale saved path must be ignored in favour of the discovered file.
    [[ "$output" == *"Pull secret:"*"found "*"pull-secret.json"* ]] || { echo "pull secret line: $output"; exit 1; }
    [[ "$output" != *"/gone/pull-secret.json"* ]] || { echo "stale path leaked: $output"; exit 1; }
  '
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}

test_filter_dns_by_family_keeps_ipv4_for_ipv4_host() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    mapfile -t kept < <(filter_dns_by_family "192.0.2.10" "185.12.64.1" "2a01:4ff:ff00::add:1" "185.12.64.2")
    [[ "${#kept[@]}" -eq 2 ]] || { echo "expected 2, got ${#kept[@]}: ${kept[*]}"; exit 1; }
    [[ "${kept[0]}" == "185.12.64.1" && "${kept[1]}" == "185.12.64.2" ]] || { echo "unexpected: ${kept[*]}"; exit 1; }
  '
}

test_filter_dns_by_family_keeps_ipv6_for_ipv6_host() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    mapfile -t kept < <(filter_dns_by_family "2a01:4ff::1" "185.12.64.1" "2a01:4ff:ff00::add:1")
    [[ "${#kept[@]}" -eq 1 ]] || { echo "expected 1, got ${#kept[@]}: ${kept[*]}"; exit 1; }
    [[ "${kept[0]}" == "2a01:4ff:ff00::add:1" ]] || { echo "unexpected: ${kept[*]}"; exit 1; }
  '
}

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

  local ret=0
  [[ "${status}" -eq 0 ]] || ret=1
  [[ "${config}" == *"serialNumber: \"S63CNF0X212059\""* ]] || ret=1
  [[ "${config}" != *"deviceName:"* ]] || ret=1

  rm -rf "${temp_dir}"
  return "${ret}"
}

test_generate_agent_config_falls_back_to_device_name() {
  local temp_dir
  local config
  local stderr
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
  ' 2>"${temp_dir}/stderr"
  status=$?

  config="$(<"${temp_dir}/install/agent-config.yaml")"
  stderr="$(<"${temp_dir}/stderr")"

  local ret=0
  [[ "${status}" -eq 0 ]] || ret=1
  [[ "${config}" == *"deviceName: \"/dev/nvme1n1\""* ]] || ret=1
  [[ "${config}" != *"serialNumber:"* ]] || ret=1
  [[ "${stderr}" == *"WARNING: no serial for /dev/nvme1n1"* ]] || ret=1

  rm -rf "${temp_dir}"
  return "${ret}"
}

test_replay_emits_disk_serial_when_known() {
  local output ret=0
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
  # Check for --disk-serial in the command (not just the comment).
  grep -q "^  --disk-serial S63CNF0X212063" <<< "$output" || ret=1
  # Make sure --disk-device doesn't appear as a command argument (OK in comments).
  grep "^  --disk-device" <<< "$output" >/dev/null && ret=1
  return "$ret"
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

run_test "filter_dns_by_family keeps IPv4 for IPv4 host" test_filter_dns_by_family_keeps_ipv4_for_ipv4_host
run_test "filter_dns_by_family keeps IPv6 for IPv6 host" test_filter_dns_by_family_keeps_ipv6_for_ipv6_host
run_test "generate_agent_config uses serialNumber when serial is known" test_generate_agent_config_uses_serial_number
run_test "generate_agent_config falls back to deviceName without serial" test_generate_agent_config_falls_back_to_device_name
run_test "replay emits --disk-serial when serial known" test_replay_emits_disk_serial_when_known
run_test "replay emits --disk-device when no serial" test_replay_emits_disk_device_when_no_serial
run_test "report_credential_presence reports missing credentials" test_report_credential_presence_reports_missing
run_test "report_credential_presence reports found credentials" test_report_credential_presence_reports_found
run_test "report_credential_presence reports explicit missing path" test_report_credential_presence_reports_explicit_missing_path
run_test "report_credential_presence expands tilde for ssh" test_report_credential_presence_expands_tilde_for_ssh
run_test "report_credential_presence ignores stale saved path" test_report_credential_presence_ignores_stale_saved_path

test_print_next_step_hint_uses_absolute_path() {
  local temp_dir output status
  temp_dir="$(mktemp -d)"
  touch "${temp_dir}/hetzner-sno-provision-host-agentbased.sh"

  output="$(HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_DIR="'"${temp_dir}"'"
    ARTIFACT_DIR="/root"
    print_next_step_hint
  ')"
  status=$?

  rm -rf "${temp_dir}"
  [[ "${status}" -eq 0 ]] || return 1
  [[ "${output}" == *"  ${temp_dir}/hetzner-sno-provision-host-agentbased.sh --artifact-dir /root"* ]]
}

run_test "print_next_step_hint uses absolute path" test_print_next_step_hint_uses_absolute_path

if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
