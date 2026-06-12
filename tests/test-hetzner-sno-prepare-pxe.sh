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
    declare -F detect_install_disk >/dev/null
    declare -F ocp_archive_name >/dev/null
    declare -F version_matches_requested >/dev/null
    declare -F fetch_ocp_checksums >/dev/null
    declare -F verify_download_checksum >/dev/null
  '
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

run_test "can source helper functions" test_can_source_helper_functions
run_test "parse_args accepts disk override" test_parse_args_accepts_disk_device_override
run_test "detect_install_disk normalizes root partition" test_detect_install_disk_normalizes_root_partition
run_test "archive names are versioned" test_ocp_archive_name_uses_versioned_mirror_filenames
run_test "version check rejects mismatched versions" test_version_matches_requested_rejects_mismatch
run_test "fetch_ocp_checksums returns path only" test_fetch_ocp_checksums_returns_path_only
run_test "checksum verification rejects mismatched payloads" test_verify_download_checksum_detects_mismatch

if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
