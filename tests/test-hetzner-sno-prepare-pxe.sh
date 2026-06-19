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

test_parse_args_accepts_ipv6_and_family_flags() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    parse_args \
      --ipv6-with-prefix 2a01:4f8:abcd:1234::1/64 \
      --ipv6-gateway fe80::1 \
      --ip-family dual \
      --cluster-network fd01::/48,64 \
      --service-network fd02::/112 \
      4.16.15 /tmp/pull-secret.json example.com sno
    [[ "${IPV6_WITH_PREFIX_OVERRIDE}" == "2a01:4f8:abcd:1234::1/64" ]] || { echo "v6 prefix: ${IPV6_WITH_PREFIX_OVERRIDE}"; exit 1; }
    [[ "${IPV6_GATEWAY_OVERRIDE}" == "fe80::1" ]] || { echo "v6 gw"; exit 1; }
    [[ "${IP_FAMILY_OVERRIDE}" == "dual" ]] || { echo "family"; exit 1; }
    [[ "${#CLUSTER_NETWORKS[@]}" -eq 1 && "${CLUSTER_NETWORKS[0]}" == "fd01::/48,64" ]] || { echo "cluster: ${CLUSTER_NETWORKS[*]}"; exit 1; }
    [[ "${#SERVICE_NETWORKS[@]}" -eq 1 && "${SERVICE_NETWORKS[0]}" == "fd02::/112" ]] || { echo "service: ${SERVICE_NETWORKS[*]}"; exit 1; }
  '
}

test_validate_ip_family_rejects_dual_with_one_address() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    IP_FAMILY_OVERRIDE="dual"
    IP_WITH_PREFIX_OVERRIDE="192.0.2.10/24"
    IPV6_WITH_PREFIX_OVERRIDE=""
    ! validate_ip_family
  ' 2>/dev/null
}

test_validate_ip_family_rejects_v6_with_v4_address() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    IP_FAMILY_OVERRIDE="v6"
    IP_WITH_PREFIX_OVERRIDE="192.0.2.10/24"
    ! validate_ip_family
  ' 2>/dev/null
}

test_validate_ip_family_accepts_consistent_dual() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    IP_FAMILY_OVERRIDE="dual"
    IP_WITH_PREFIX_OVERRIDE="192.0.2.10/24"
    IPV6_WITH_PREFIX_OVERRIDE="2a01:db8::1/64"
    validate_ip_family
  '
}

test_validate_ip_family_rejects_unknown_value() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    IP_FAMILY_OVERRIDE="ipv6"
    IP_WITH_PREFIX_OVERRIDE=""
    IPV6_WITH_PREFIX_OVERRIDE=""
    ! validate_ip_family
  ' 2>/dev/null
}

run_test "parse_args accepts ipv6 and family flags" test_parse_args_accepts_ipv6_and_family_flags
run_test "validate_ip_family rejects dual with one address" test_validate_ip_family_rejects_dual_with_one_address
run_test "validate_ip_family rejects v6 family with v4 address" test_validate_ip_family_rejects_v6_with_v4_address
run_test "validate_ip_family accepts consistent dual" test_validate_ip_family_accepts_consistent_dual
run_test "validate_ip_family rejects unknown value (interactive guard)" test_validate_ip_family_rejects_unknown_value
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

test_filter_dns_by_active_families_keeps_both_in_dual() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ACTIVE_V4=1; ACTIVE_V6=1
    mapfile -t kept < <(filter_dns_by_active_families 8.8.8.8 2001:4860:4860::8888 1.1.1.1)
    [[ "${#kept[@]}" -eq 3 ]] || { echo "got ${#kept[@]}: ${kept[*]}"; exit 1; }
  '
}

test_filter_dns_by_active_families_drops_v6_when_v4_only() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ACTIVE_V4=1; ACTIVE_V6=0
    mapfile -t kept < <(filter_dns_by_active_families 8.8.8.8 2001:4860:4860::8888)
    [[ "${#kept[@]}" -eq 1 && "${kept[0]}" == "8.8.8.8" ]] || { echo "got: ${kept[*]}"; exit 1; }
  '
}

test_propose_ipv6_host_returns_first_address() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    [[ "$(propose_ipv6_host 2a01:4f8:abcd:1234::/64)" == "2a01:4f8:abcd:1234::1/64" ]]
  '
}

test_discover_ipv6_uses_ra_prefix_and_default_gateway() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/ip" <<'EOF'
#!/bin/bash
case "$*" in
  "-6 route show dev eth0")
    printf 'fe80::/64 dev eth0 proto kernel metric 256\n'
    printf '2a01:4f8:abcd:1234::/64 dev eth0 proto ra metric 100\n'
    ;;
  "-6 route show default")
    printf 'default via fe80::1 dev eth0 proto ra metric 100\n'
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${stub_dir}/ip"
  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DEFAULT_IFACE="eth0"
    IPV6_WITH_PREFIX_OVERRIDE=""
    IPV6_GATEWAY_OVERRIDE=""
    discover_ipv6
    [[ "${IPV6_WITH_PREFIX}" == "2a01:4f8:abcd:1234::1/64" ]] || { echo "ip: ${IPV6_WITH_PREFIX}"; exit 1; }
    [[ "${IPV6_GATEWAY}" == "fe80::1" ]] || { echo "gw: ${IPV6_GATEWAY}"; exit 1; }
  '
  status=$?
  rm -rf "${stub_dir}"
  return "${status}"
}

test_discover_ipv6_honors_overrides() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DEFAULT_IFACE="eth0"
    IPV6_WITH_PREFIX_OVERRIDE="2a01:db8::5/64"
    IPV6_GATEWAY_OVERRIDE="2a01:db8::1"
    discover_ipv6
    [[ "${IPV6_WITH_PREFIX}" == "2a01:db8::5/64" ]] || { echo "ip: ${IPV6_WITH_PREFIX}"; exit 1; }
    [[ "${IPV6_GATEWAY}" == "2a01:db8::1" ]] || { echo "gw: ${IPV6_GATEWAY}"; exit 1; }
  '
}

test_discover_ipv6_dies_without_prefix() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/ip" <<'EOF'
#!/bin/bash
case "$*" in
  "-6 route show dev eth0") printf 'fe80::/64 dev eth0 proto kernel metric 256\n' ;;
  "-6 route show default") printf '' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${stub_dir}/ip"
  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DEFAULT_IFACE="eth0"
    IPV6_WITH_PREFIX_OVERRIDE=""
    IPV6_GATEWAY_OVERRIDE=""
    ! discover_ipv6
  ' 2>/dev/null
  status=$?
  rm -rf "${stub_dir}"
  return "${status}"
}

test_build_net_families_json_orders_v4_first() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    out="$(NETF_V4_IP=192.0.2.10 NETF_V4_PREFIX=24 NETF_V4_GW=192.0.2.1 \
           NETF_V6_IP=2a01:db8::1 NETF_V6_PREFIX=64 NETF_V6_GW=fe80::1 \
           build_net_families_json)"
    printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert [r[\"family\"] for r in d]==[\"v4\",\"v6\"], d
assert d[0][\"cidr\"]==\"192.0.2.0/24\", d[0]
assert d[1][\"cidr\"]==\"2a01:db8::/64\", d[1]
assert d[1][\"gateway\"]==\"fe80::1\", d[1]
"
  '
}

test_build_net_families_json_v6_only() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    out="$(NETF_V4_IP="" NETF_V4_PREFIX="" NETF_V4_GW="" \
           NETF_V6_IP=2a01:db8::1 NETF_V6_PREFIX=64 NETF_V6_GW=fe80::1 \
           build_net_families_json)"
    printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert [r[\"family\"] for r in d]==[\"v6\"], d
"
  '
}

test_generate_install_config_ipv4_only_omits_cluster_service() {
  local dir status
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=1; ACTIVE_V6=0
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    MACHINE_NETWORK="192.0.2.0/24"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"}]"
    generate_install_config >/dev/null
    f="'"${dir}"'/install-config.yaml"
    grep -q "machineNetwork" "$f" || { echo "no machineNetwork"; exit 1; }
    grep -q "cidr: \"192.0.2.0/24\"" "$f" || { echo "no v4 cidr"; exit 1; }
    ! grep -q "clusterNetwork" "$f" || { echo "clusterNetwork leaked"; exit 1; }
    ! grep -q "serviceNetwork" "$f" || { echo "serviceNetwork leaked"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_generate_install_config_dual_emits_both_networks() {
  local dir status
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=1; ACTIVE_V6=1
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    MACHINE_NETWORK="192.0.2.0/24"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"},{\"family\":\"v6\",\"ip\":\"2a01:db8::1\",\"prefix\":64,\"gateway\":\"fe80::1\",\"cidr\":\"2a01:db8::/64\"}]"
    generate_install_config >/dev/null
    f="'"${dir}"'/install-config.yaml"
    grep -q "cidr: \"192.0.2.0/24\"" "$f" || { echo "no v4 machine"; exit 1; }
    grep -q "cidr: \"2a01:db8::/64\"" "$f" || { echo "no v6 machine"; exit 1; }
    grep -q "cidr: \"10.128.0.0/14\"" "$f" || { echo "no v4 cluster"; exit 1; }
    grep -q "cidr: \"fd01::/48\"" "$f" || { echo "no v6 cluster default"; exit 1; }
    grep -q "172.30.0.0/16" "$f" || { echo "no v4 service"; exit 1; }
    grep -q "fd02::/112" "$f" || { echo "no v6 service default"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_generate_agent_config_dual_emits_both_blocks() {
  local dir status
  dir="$(mktemp -d)"
  INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    CLUSTER_NAME="sno"
    RENDEZVOUS_IP="192.0.2.10"; NODE_HOSTNAME="node.example.com"
    DEFAULT_IFACE="eth0"; MAC_ADDR="00:11:22:33:44:55"
    INSTALL_DISK="/dev/nvme0n1"; INSTALL_DISK_SERIAL="SN-A"
    DNS_SERVERS_RAW="$(printf "8.8.8.8\n2001:4860:4860::8888\n")"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"},{\"family\":\"v6\",\"ip\":\"2a01:db8::1\",\"prefix\":64,\"gateway\":\"fe80::1\",\"cidr\":\"2a01:db8::/64\"}]"
    generate_agent_config >/dev/null
    f="'"${dir}"'/agent-config.yaml"
    grep -q "rendezvousIP: \"192.0.2.10\"" "$f" || { echo "rendezvous"; exit 1; }
    grep -q "ipv4:" "$f" || { echo "no ipv4"; exit 1; }
    grep -q "ipv6:" "$f" || { echo "no ipv6"; exit 1; }
    grep -q "autoconf: false" "$f" || { echo "no autoconf false"; exit 1; }
    grep -q "destination: 0.0.0.0/0" "$f" || { echo "no v4 route"; exit 1; }
    grep -q "destination: ::/0" "$f" || { echo "no v6 route"; exit 1; }
    grep -q "next-hop-address: \"fe80::1\"" "$f" || { echo "no v6 gw"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_generate_agent_config_v6_only_has_no_ipv4_block() {
  local dir status
  dir="$(mktemp -d)"
  INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    CLUSTER_NAME="sno"
    RENDEZVOUS_IP="2a01:db8::1"; NODE_HOSTNAME="node.example.com"
    DEFAULT_IFACE="eth0"; MAC_ADDR="00:11:22:33:44:55"
    INSTALL_DISK="/dev/nvme0n1"; INSTALL_DISK_SERIAL="SN-A"
    DNS_SERVERS_RAW="$(printf "2001:4860:4860::8888\n")"
    NET_FAMILIES_JSON="[{\"family\":\"v6\",\"ip\":\"2a01:db8::1\",\"prefix\":64,\"gateway\":\"fe80::1\",\"cidr\":\"2a01:db8::/64\"}]"
    generate_agent_config >/dev/null
    f="'"${dir}"'/agent-config.yaml"
    grep -q "ipv6:" "$f" || { echo "no ipv6"; exit 1; }
    ! grep -q "ipv4:" "$f" || { echo "ipv4 leaked"; exit 1; }
    grep -q "destination: ::/0" "$f" || { echo "no v6 route"; exit 1; }
    ! grep -q "destination: 0.0.0.0/0" "$f" || { echo "v4 route leaked"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_resolve_network_config_iface_falls_back_to_ipv6_route() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/ip" <<'EOF'
#!/bin/bash
case "$*" in
  "route show default") printf '' ;;
  "-6 route show default") printf 'default via fe80::1 dev eth0 proto ra metric 100\n' ;;
  "link show eth0") printf '2: eth0: <BROADCAST> mtu 1500\n    link/ether 00:11:22:33:44:55 brd ff:ff:ff:ff:ff:ff\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${stub_dir}/ip"
  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    NETWORK_INTERFACE_OVERRIDE=""
    IP_FAMILY_OVERRIDE="v6"
    IPV6_WITH_PREFIX_OVERRIDE="2a01:db8::1/64"
    IPV6_GATEWAY_OVERRIDE="fe80::1"
    DNS_SERVERS_OVERRIDE=("2001:4860:4860::8888")
    HOSTNAME_OVERRIDE=""
    resolve_network_config
    [[ "${DEFAULT_IFACE}" == "eth0" ]] || { echo "iface: ${DEFAULT_IFACE}"; exit 1; }
    [[ "${ACTIVE_V6}" -eq 1 ]] || { echo "v6 inactive"; exit 1; }
  '
  status=$?
  rm -rf "${stub_dir}"
  return "${status}"
}

run_test "propose_ipv6_host returns first address" test_propose_ipv6_host_returns_first_address
run_test "discover_ipv6 uses RA prefix and default gateway" test_discover_ipv6_uses_ra_prefix_and_default_gateway
run_test "discover_ipv6 honors overrides" test_discover_ipv6_honors_overrides
run_test "discover_ipv6 dies without a usable prefix" test_discover_ipv6_dies_without_prefix
run_test "resolve_network_config iface falls back to IPv6 default route" test_resolve_network_config_iface_falls_back_to_ipv6_route
run_test "filter_dns_by_family keeps IPv4 for IPv4 host" test_filter_dns_by_family_keeps_ipv4_for_ipv4_host
run_test "filter_dns_by_family keeps IPv6 for IPv6 host" test_filter_dns_by_family_keeps_ipv6_for_ipv6_host
run_test "filter_dns_by_active_families keeps both in dual" test_filter_dns_by_active_families_keeps_both_in_dual
run_test "filter_dns_by_active_families drops v6 when v4 only" test_filter_dns_by_active_families_drops_v6_when_v4_only
run_test "build_net_families_json orders v4 first" test_build_net_families_json_orders_v4_first
run_test "build_net_families_json supports v6-only" test_build_net_families_json_v6_only

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
  NET_FAMILIES_JSON='[{"family":"v4","ip":"95.217.75.157","prefix":26,"gateway":"95.217.75.129","cidr":"95.217.75.128/26"}]' \
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
  NET_FAMILIES_JSON='[{"family":"v4","ip":"95.217.75.157","prefix":26,"gateway":"95.217.75.129","cidr":"95.217.75.128/26"}]' \
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

run_test "generate_agent_config uses serialNumber when serial is known" test_generate_agent_config_uses_serial_number
run_test "generate_agent_config falls back to deviceName without serial" test_generate_agent_config_falls_back_to_device_name
run_test "replay emits --disk-serial when serial known" test_replay_emits_disk_serial_when_known
run_test "replay emits --disk-device when no serial" test_replay_emits_disk_device_when_no_serial
run_test "report_credential_presence reports missing credentials" test_report_credential_presence_reports_missing
run_test "report_credential_presence reports found credentials" test_report_credential_presence_reports_found
run_test "report_credential_presence reports explicit missing path" test_report_credential_presence_reports_explicit_missing_path
run_test "report_credential_presence expands tilde for ssh" test_report_credential_presence_expands_tilde_for_ssh
run_test "report_credential_presence ignores stale saved path" test_report_credential_presence_ignores_stale_saved_path
run_test "generate_install_config IPv4-only omits cluster/service" test_generate_install_config_ipv4_only_omits_cluster_service
run_test "generate_install_config dual emits both networks" test_generate_install_config_dual_emits_both_networks
run_test "generate_agent_config dual emits both blocks" test_generate_agent_config_dual_emits_both_blocks
run_test "generate_agent_config v6-only has no ipv4 block" test_generate_agent_config_v6_only_has_no_ipv4_block

test_print_replay_command_includes_ipv6_flags() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_NAME="hetzner-sno-prepare-pxe.sh"
    NODE_HOSTNAME="node.example.com"; SSH_PUBLIC_KEY_FILE="/root/id.pub"
    DEFAULT_IFACE="eth0"
    IP_WITH_PREFIX="192.0.2.10/24"; GATEWAY="192.0.2.1"
    ACTIVE_V4=1; ACTIVE_V6=1
    IPV6_WITH_PREFIX="2a01:db8::1/64"; IPV6_GATEWAY="fe80::1"
    IP_FAMILY_OVERRIDE="dual"
    DNS_SERVERS=("8.8.8.8"); INSTALL_DISK="/dev/nvme0n1"
    ARTIFACT_DIR="/root"; BIN_DIR="/usr/local/bin"
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    out="$(print_replay_command)"
    [[ "$out" == *"--ipv6-with-prefix 2a01:db8::1/64"* ]] || { echo "no v6 prefix: $out"; exit 1; }
    [[ "$out" == *"--ipv6-gateway fe80::1"* ]] || { echo "no v6 gw"; exit 1; }
    [[ "$out" == *"--ip-family dual"* ]] || { echo "no family"; exit 1; }
  '
}

run_test "print_replay_command includes ipv6 flags" test_print_replay_command_includes_ipv6_flags

test_save_config_persists_ipv6_fields() {
  local dir status
  dir="$(mktemp -d)"
  SNO_CONFIG_FILE="${dir}/config" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    OCP_VERSION="4.16.15"; PULL_SECRET_FILE="/x"; BASE_DOMAIN="e"; CLUSTER_NAME="sno"
    DNS_SERVERS_OVERRIDE=(); DNS_SERVERS=()
    IPV6_WITH_PREFIX="2a01:db8::1/64"; IPV6_GATEWAY="fe80::1"; IP_FAMILY_OVERRIDE="dual"
    save_config
    grep -q "IPV6_WITH_PREFIX_OVERRIDE=2a01:db8::1/64" "'"${dir}"'/config" || { echo "no v6 prefix"; exit 1; }
    grep -q "IPV6_GATEWAY_OVERRIDE=fe80::1" "'"${dir}"'/config" || { echo "no v6 gw"; exit 1; }
    grep -q "IP_FAMILY_OVERRIDE=dual" "'"${dir}"'/config" || { echo "no family"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

run_test "save_config persists ipv6 fields" test_save_config_persists_ipv6_fields

test_ipv4_only_output_byte_identical_to_baseline() {
  local tmp old_dir new_dir status
  tmp="$(mktemp -d)"
  old_dir="${tmp}/old_install"
  new_dir="${tmp}/new_install"
  mkdir -p "${old_dir}" "${new_dir}"
  printf '{}' > "${tmp}/pull-secret.json"

  # Extract the pre-feature baseline script (commit 9c53635) into a temp file.
  local old_script="${tmp}/old.sh"
  git -C "${REPO_ROOT}" show 9c53635:hetzner-sno-prepare-pxe.sh > "${old_script}" 2>/dev/null || {
    echo "WARNING: baseline commit 9c53635 not available (shallow clone or non-git env); skipping byte-identical test. Run from a full clone to exercise this guard." >&2
    rm -rf "${tmp}"; return 0
  }

  # Common values used by both generators.
  local pull_secret="${tmp}/pull-secret.json"
  local ip_addr="192.0.2.10"
  local prefix="24"
  local gw="192.0.2.1"
  local machine_net="192.0.2.0/24"
  local hostname="node.example.com"
  local iface="eth0"
  local mac="00:11:22:33:44:55"
  local disk="/dev/nvme0n1"
  local dns_raw="8.8.8.8"
  local cluster="sno"
  local domain="example.com"
  local ssh_key="ssh-ed25519 AAAA"
  local rendezvous="192.0.2.10"

  # Run the OLD generator (commit 9c53635 variable contract; no serial logic).
  INSTALL_DIR="${old_dir}" WORKDIR="${tmp}/oldwork" HSPPXE_TEST_MODE=1 bash -c "
    source '${old_script}'
    BASE_DOMAIN='${domain}'
    CLUSTER_NAME='${cluster}'
    PULL_SECRET_FILE='${pull_secret}'
    SSH_PUB_KEY='${ssh_key}'
    IP_ADDR='${ip_addr}'
    PREFIX_LEN='${prefix}'
    GATEWAY='${gw}'
    MACHINE_NETWORK='${machine_net}'
    INSTALL_DISK='${disk}'
    DNS_SERVERS_RAW='${dns_raw}'
    RENDEZVOUS_IP='${rendezvous}'
    NODE_HOSTNAME='${hostname}'
    DEFAULT_IFACE='${iface}'
    MAC_ADDR='${mac}'
    generate_install_config >/dev/null 2>&1
    generate_agent_config >/dev/null 2>&1
  " || { rm -rf "${tmp}"; return 1; }

  # Run the NEW generator (IPv4-only, serial empty so it falls back to deviceName).
  local net_fam
  net_fam='[{"family":"v4","ip":"'"${ip_addr}"'","prefix":24,"gateway":"'"${gw}"'","cidr":"'"${machine_net}"'"}]'
  INSTALL_DIR="${new_dir}" WORKDIR="${tmp}/newwork" HSPPXE_TEST_MODE=1 bash -c "
    source '${SCRIPT}'
    BASE_DOMAIN='${domain}'
    CLUSTER_NAME='${cluster}'
    PULL_SECRET_FILE='${pull_secret}'
    SSH_PUB_KEY='${ssh_key}'
    ACTIVE_V4=1; ACTIVE_V6=0
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    MACHINE_NETWORK='${machine_net}'
    NET_FAMILIES_JSON='${net_fam}'
    INSTALL_DISK='${disk}'
    INSTALL_DISK_SERIAL=''
    DNS_SERVERS_RAW='${dns_raw}'
    RENDEZVOUS_IP='${rendezvous}'
    NODE_HOSTNAME='${hostname}'
    DEFAULT_IFACE='${iface}'
    MAC_ADDR='${mac}'
    generate_install_config >/dev/null 2>&1
    generate_agent_config >/dev/null 2>&1
  " || { rm -rf "${tmp}"; return 1; }

  local ic_diff ac_diff
  ic_diff="$(diff "${old_dir}/install-config.yaml" "${new_dir}/install-config.yaml")" || {
    echo "install-config.yaml differs:" >&2
    printf '%s\n' "${ic_diff}" >&2
    rm -rf "${tmp}"; return 1
  }
  ac_diff="$(diff "${old_dir}/agent-config.yaml" "${new_dir}/agent-config.yaml")" || {
    echo "agent-config.yaml differs:" >&2
    printf '%s\n' "${ac_diff}" >&2
    rm -rf "${tmp}"; return 1
  }

  rm -rf "${tmp}"
}

test_generate_install_config_cluster_network_override_hostprefix() {
  local dir status
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=0; ACTIVE_V6=1
    CLUSTER_NETWORKS=("fd01::/48,56"); SERVICE_NETWORKS=()
    MACHINE_NETWORK="fd01::/48"
    NET_FAMILIES_JSON="[{\"family\":\"v6\",\"ip\":\"fd01::1\",\"prefix\":48,\"gateway\":\"fe80::1\",\"cidr\":\"fd01::/48\"}]"
    generate_install_config >/dev/null
    f="'"${dir}"'/install-config.yaml"
    grep -q "clusterNetwork:" "$f" || { echo "no clusterNetwork"; exit 1; }
    grep -q "cidr: \"fd01::/48\"" "$f" || { echo "no fd01::/48 cidr"; exit 1; }
    grep -q "hostPrefix: 56" "$f" || { echo "no hostPrefix 56"; exit 1; }
    # Verify hostPrefix: 56 appears on the line immediately after the clusterNetwork cidr entry.
    # grep -A1 prints the matched line and the next line; pipe into grep to confirm hostPrefix 56 follows.
    grep -A1 "cidr: \"fd01::/48\"" "$f" | grep -q "hostPrefix: 56" || { echo "hostPrefix 56 not immediately after clusterNetwork cidr"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_generate_install_config_rejects_bad_cluster_network() {
  local dir out rc
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  out="$(INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=1; ACTIVE_V6=0
    CLUSTER_NETWORKS=("10.128.0.0/14,notanumber"); SERVICE_NETWORKS=()
    MACHINE_NETWORK="192.0.2.0/24"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"}]"
    generate_install_config
  ' 2>&1)"
  rc=$?
  rm -rf "${dir}"
  [[ "${rc}" -ne 0 ]] && grep -q -- "--cluster-network" <<<"${out}"
}

test_generate_install_config_rejects_bad_service_network() {
  local dir out rc
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  out="$(INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=1; ACTIVE_V6=0
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=("not-a-cidr")
    MACHINE_NETWORK="192.0.2.0/24"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"}]"
    generate_install_config
  ' 2>&1)"
  rc=$?
  rm -rf "${dir}"
  [[ "${rc}" -ne 0 ]] && grep -q -- "--service-network" <<<"${out}"
}

test_generate_install_config_orders_overrides_v4_first() {
  local dir status
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  INSTALL_DIR="${dir}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=1; ACTIVE_V6=1
    # Overrides intentionally given v6-first to prove the generator reorders v4-first.
    CLUSTER_NETWORKS=("fd01::/48,64" "10.128.0.0/14,23")
    SERVICE_NETWORKS=("fd02::/112" "172.30.0.0/16")
    MACHINE_NETWORK="192.0.2.0/24"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"},{\"family\":\"v6\",\"ip\":\"2a01:db8::1\",\"prefix\":64,\"gateway\":\"fe80::1\",\"cidr\":\"2a01:db8::/64\"}]"
    generate_install_config >/dev/null
    f="'"${dir}"'/install-config.yaml"
    cv4=$(grep -n "10.128.0.0/14" "$f" | head -1 | cut -d: -f1)
    cv6=$(grep -n "fd01::/48" "$f" | head -1 | cut -d: -f1)
    [[ -n "$cv4" && -n "$cv6" && "$cv4" -lt "$cv6" ]] || { echo "clusterNetwork not v4-first: v4=$cv4 v6=$cv6"; exit 1; }
    sv4=$(grep -n "172.30.0.0/16" "$f" | head -1 | cut -d: -f1)
    sv6=$(grep -n "fd02::/112" "$f" | head -1 | cut -d: -f1)
    [[ -n "$sv4" && -n "$sv6" && "$sv4" -lt "$sv6" ]] || { echo "serviceNetwork not v4-first: v4=$sv4 v6=$sv6"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_print_resolved_config_v6_only_shows_ipv6_lines() {
  WORKDIR="/root/ocp-prepare" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    OCP_VERSION="4.16.15"
    PULL_SECRET_FILE="/tmp/pull-secret.json"
    BASE_DOMAIN="example.com"
    CLUSTER_NAME="sno"
    DEFAULT_IFACE="eth0"
    ACTIVE_V4=0
    ACTIVE_V6=1
    IP_WITH_PREFIX=""
    GATEWAY=""
    IPV6_WITH_PREFIX="2a01:db8::1/64"
    IPV6_GATEWAY="fe80::1"
    IP_FAMILY_OVERRIDE="v6"
    MAC_ADDR="00:11:22:33:44:55"
    MACHINE_NETWORK="2a01:db8::/64"
    RENDEZVOUS_IP="2a01:db8::1"
    NODE_HOSTNAME="node.example.com"
    DNS_DISPLAY="2001:4860:4860::8888"
    INSTALL_DISK="/dev/nvme0n1"
    SSH_PUBLIC_KEY_FILE="/root/id.pub"
    ARTIFACT_DIR="/root"
    BIN_DIR="/usr/local/bin"
    out="$(print_resolved_config)"
    [[ "$out" == *"IPv6/prefix:"*"2a01:db8::1/64"* ]] || { echo "no ipv6 address line: $out"; exit 1; }
    [[ "$out" == *"IPv6 gateway:"*"fe80::1"* ]] || { echo "no ipv6 gateway line: $out"; exit 1; }
    # Must NOT print a blank IPv4 IP/prefix or Gateway line
    if echo "$out" | grep -vE "^  IPv6" | grep -qE "^  IP/prefix:[[:space:]]*$"; then
      echo "empty IP/prefix line present"; exit 1
    fi
    if echo "$out" | grep -vE "^  IPv6" | grep -qE "^  Gateway:[[:space:]]*$"; then
      echo "empty Gateway line present"; exit 1
    fi
  '
}

run_test "ipv4-only output byte-identical to baseline (9c53635)" test_ipv4_only_output_byte_identical_to_baseline
run_test "generate_install_config cluster-network override hostPrefix" test_generate_install_config_cluster_network_override_hostprefix
run_test "generate_install_config rejects bad cluster-network hostPrefix" test_generate_install_config_rejects_bad_cluster_network
run_test "generate_install_config rejects bad service-network cidr" test_generate_install_config_rejects_bad_service_network
run_test "generate_install_config orders overrides IPv4-first" test_generate_install_config_orders_overrides_v4_first
run_test "print_resolved_config v6-only shows ipv6 lines" test_print_resolved_config_v6_only_shows_ipv6_lines

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
