#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARE_SCRIPT="${REPO_ROOT}/hetzner-sno-prepare-pxe.sh"
ASSISTED_SCRIPT="${REPO_ROOT}/hetzner-sno-provision-host.sh"
AGENT_SCRIPT="${REPO_ROOT}/hetzner-sno-provision-host-agentbased.sh"
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

make_stub_dir() {
  local stub_dir="$1"

  mkdir -p "$stub_dir"
  for command_name in apt-get debconf-set-selections kexec curl cargo oc openshift-install ip lsblk findmnt hostname ssh-keygen install tar sha256sum uname; do
    cat > "${stub_dir}/${command_name}" <<'EOF'
#!/bin/bash
printf '%s\n' "$0 $*" >> "${STUB_LOG:?}"
case "$(basename "$0")" in
  uname)
    printf 'x86_64\n'
    ;;
  hostname)
    printf 'node.example.com\n'
    ;;
  ip)
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
    esac
    ;;
  findmnt)
    printf '/dev/nvme0n1p1\n'
    ;;
  lsblk)
    case "$*" in
      *"TYPE /dev/nvme0n1p1"*)
        printf 'part\n'
        ;;
      *"PKNAME /dev/nvme0n1p1"*)
        printf 'nvme0n1\n'
        ;;
      *"TYPE /dev/nvme0n1"*)
        printf 'disk\n'
        ;;
      *)
        printf '/dev/nvme0n1 disk 0\n'
        ;;
    esac
    ;;
  oc)
    printf 'Client Version: 4.16.15\n'
    ;;
  openshift-install)
    printf 'openshift-install 4.16.15\n'
    ;;
  cargo)
    if [[ "${1:-}" == "--version" ]]; then
      printf 'cargo 1.80.0\n'
    fi
    ;;
  curl)
    exit 1
    ;;
esac
EOF
    chmod +x "${stub_dir}/${command_name}"
  done
}

test_prepare_parse_args_accepts_hardening_flags() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${PREPARE_SCRIPT}"'"
    parse_args --dry-run --yes --artifact-dir /tmp/artifacts --bin-dir /tmp/bin \
      --network-interface eth9 --ip-with-prefix 198.51.100.10/25 --gateway 198.51.100.1 \
      --dns-server 1.1.1.1 --dns-server 9.9.9.9 --hostname "node:one" \
      --ssh-key-file /tmp/id_rsa --disk-device /dev/nvme0n1 \
      4.16.15 /tmp/pull-secret.json example.com sno 198.51.100.10
    [[ "${DRY_RUN}" == "1" ]]
    [[ "${YES}" == "1" ]]
    [[ "${ARTIFACT_DIR}" == "/tmp/artifacts" ]]
    [[ "${BIN_DIR}" == "/tmp/bin" ]]
    [[ "${NETWORK_INTERFACE_OVERRIDE}" == "eth9" ]]
    [[ "${IP_WITH_PREFIX_OVERRIDE}" == "198.51.100.10/25" ]]
    [[ "${GATEWAY_OVERRIDE}" == "198.51.100.1" ]]
    [[ "${DNS_SERVERS_OVERRIDE[*]}" == "1.1.1.1 9.9.9.9" ]]
    [[ "${HOSTNAME_OVERRIDE}" == "node:one" ]]
    [[ "${SSH_KEY_FILE}" == "/tmp/id_rsa" ]]
  '
}

test_prepare_dry_run_avoids_downloads_and_writes_artifacts() {
  local temp_dir stub_dir pull_secret log_file status

  temp_dir="$(mktemp -d)"
  stub_dir="${temp_dir}/stubs"
  pull_secret="${temp_dir}/pull-secret.json"
  log_file="${temp_dir}/stub.log"
  printf '{"auths":{"example.com":{"auth":"abc"}}}\n' > "$pull_secret"
  : > "$log_file"
  make_stub_dir "$stub_dir"

  PATH="${stub_dir}:${PATH}" STUB_LOG="$log_file" HOME="$temp_dir" WORKDIR="${temp_dir}/work" \
    bash "${PREPARE_SCRIPT}" --dry-run --artifact-dir "${temp_dir}/artifacts" --bin-dir "${temp_dir}/bin" \
      --network-interface eth0 --ip-with-prefix 192.0.2.10/24 --gateway 192.0.2.1 \
      --dns-server 203.0.113.53 --hostname node.example.com --disk-device /dev/nvme0n1 \
      4.16.15 "$pull_secret" example.com sno >/dev/null
  status=$?

  if grep -Eq 'apt-get|curl|cargo install|openshift-install agent|kexec|/install ' "$log_file"; then
    rm -rf "$temp_dir"
    return 1
  fi
  if [[ -e "${temp_dir}/artifacts" || -e "${temp_dir}/bin" ]]; then
    rm -rf "$temp_dir"
    return 1
  fi

  rm -rf "$temp_dir"
  return "$status"
}

test_generate_yaml_uses_safe_quoted_scalars() {
  local temp_dir pull_secret status

  temp_dir="$(mktemp -d)"
  pull_secret="${temp_dir}/pull-secret.json"
  printf '{"auths":{"registry.example.com":{"auth":"abc'\''def"}}}\n' > "$pull_secret"

  HSPPXE_TEST_MODE=1 PULL_SECRET_FILE="$pull_secret" INSTALL_DIR="$temp_dir" BASE_DOMAIN="example.com" \
    CLUSTER_NAME="sno:prod" MACHINE_NETWORK="192.0.2.0/24" SSH_PUB_KEY="ssh-rsa AAAA user'@host" \
    bash -c '
      source "'"${PREPARE_SCRIPT}"'"
      generate_install_config
      grep -F "baseDomain: \"example.com\"" "'"${temp_dir}/install-config.yaml"'" >/dev/null
      grep -F "name: \"sno:prod\"" "'"${temp_dir}/install-config.yaml"'" >/dev/null
      grep -F "sshKey: \"ssh-rsa AAAA user'\''@host\"" "'"${temp_dir}/install-config.yaml"'" >/dev/null
    '
  status=$?

  rm -rf "$temp_dir"
  return "$status"
}

test_assisted_rejects_invalid_ipxe_before_download_or_kexec() {
  local temp_dir stub_dir log_file ipxe_file status

  temp_dir="$(mktemp -d)"
  stub_dir="${temp_dir}/stubs"
  log_file="${temp_dir}/stub.log"
  ipxe_file="${temp_dir}/bad.ipxe"
  : > "$log_file"
  printf '#!ipxe\ninitrd https://example.com/initrd.img\n' > "$ipxe_file"
  make_stub_dir "$stub_dir"

  PATH="${stub_dir}:${PATH}" STUB_LOG="$log_file" HSPHOST_TEST_MODE=1 bash -c '
    source "'"${ASSISTED_SCRIPT}"'"
    ! parse_ipxe_script "'"${ipxe_file}"'"
  ' >/dev/null 2>&1
  status=$?

  if grep -Eq 'curl|kexec' "$log_file"; then
    rm -rf "$temp_dir"
    return 1
  fi
  rm -rf "$temp_dir"
  return "$status"
}

test_assisted_dry_run_avoids_downloads_and_kexec() {
  local temp_dir stub_dir log_file status

  temp_dir="$(mktemp -d)"
  stub_dir="${temp_dir}/stubs"
  log_file="${temp_dir}/stub.log"
  : > "$log_file"
  make_stub_dir "$stub_dir"

  PATH="${stub_dir}:${PATH}" STUB_LOG="$log_file" \
    bash "${ASSISTED_SCRIPT}" --dry-run --artifact-dir "${temp_dir}/artifacts" \
      "https://example.invalid/discovery.ipxe" >/dev/null
  status=$?

  if grep -Eq 'curl|kexec|apt-get' "$log_file"; then
    rm -rf "$temp_dir"
    return 1
  fi
  if [[ -e "${temp_dir}/artifacts" ]]; then
    rm -rf "$temp_dir"
    return 1
  fi

  rm -rf "$temp_dir"
  return "$status"
}

test_prepare_interactive_refuses_non_tty() {
  ! bash "${PREPARE_SCRIPT}" --interactive >/dev/null 2>&1
}

test_prepare_derives_public_key_from_existing_private_key() {
  local temp_dir key_file status

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    return 0
  fi

  temp_dir="$(mktemp -d)"
  key_file="${temp_dir}/id_rsa"
  ssh-keygen -q -t rsa -b 2048 -f "$key_file" -N "" -C "test@example.com"
  rm -f "${key_file}.pub"

  HSPPXE_TEST_MODE=1 SSH_KEY_FILE="$key_file" DRY_RUN=0 bash -c '
    source "'"${PREPARE_SCRIPT}"'"
    ensure_ssh_public_key
    [[ -f "${SSH_KEY_FILE}.pub" ]]
    [[ -n "${SSH_PUB_KEY}" ]]
  '
  status=$?

  rm -rf "$temp_dir"
  return "$status"
}

test_prepare_dry_run_does_not_write_derived_public_key() {
  local temp_dir key_file status

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    return 0
  fi

  temp_dir="$(mktemp -d)"
  key_file="${temp_dir}/id_rsa"
  ssh-keygen -q -t rsa -b 2048 -f "$key_file" -N "" -C "test@example.com"
  rm -f "${key_file}.pub"

  HSPPXE_TEST_MODE=1 SSH_KEY_FILE="$key_file" DRY_RUN=1 bash -c '
    source "'"${PREPARE_SCRIPT}"'"
    ensure_ssh_public_key
    [[ ! -e "${SSH_KEY_FILE}.pub" ]]
    [[ -n "${SSH_PUB_KEY}" ]]
  ' >/dev/null
  status=$?

  rm -rf "$temp_dir"
  return "$status"
}

test_agent_dry_run_requires_existing_artifacts_without_cat_or_kexec() {
  local temp_dir stub_dir log_file status

  temp_dir="$(mktemp -d)"
  stub_dir="${temp_dir}/stubs"
  log_file="${temp_dir}/stub.log"
  : > "$log_file"
  make_stub_dir "$stub_dir"

  PATH="${stub_dir}:${PATH}" STUB_LOG="$log_file" bash "${AGENT_SCRIPT}" --dry-run --artifact-dir "$temp_dir" >/dev/null 2>&1
  status=$?

  [[ "$status" -eq 0 ]]
  if grep -Eq 'cat|kexec|apt-get' "$log_file"; then
    rm -rf "$temp_dir"
    return 1
  fi

  rm -rf "$temp_dir"
  return 0
}

test_agent_yes_skips_confirmation_and_invokes_kexec_with_valid_artifacts() {
  local temp_dir stub_dir log_file status combined

  temp_dir="$(mktemp -d)"
  stub_dir="${temp_dir}/stubs"
  log_file="${temp_dir}/stub.log"
  combined="${temp_dir}/agent.x86_64-combinedinitrd.img"
  : > "$log_file"
  make_stub_dir "$stub_dir"
  printf 'kernel\n' > "${temp_dir}/agent.x86_64-vmlinuz"
  printf 'initrd' > "${temp_dir}/agent.x86_64-initrd.img"
  printf 'rootfs' > "${temp_dir}/agent.x86_64-rootfs.img"

  PATH="${stub_dir}:${PATH}" STUB_LOG="$log_file" HSPAGENT_TEST_MODE=1 bash -c '
    source "'"${AGENT_SCRIPT}"'"
    require_root() { return 0; }
    main --yes --artifact-dir "'"${temp_dir}"'"
  ' >/dev/null
  status=$?

  grep -q 'kexec' "$log_file"
  [[ "$(cat "$combined")" == "initrdrootfs" ]]

  rm -rf "$temp_dir"
  return "$status"
}

test_agent_installs_kexec_before_requiring_binary() {
  local temp_dir stub_dir log_file status

  temp_dir="$(mktemp -d)"
  stub_dir="${temp_dir}/stubs"
  log_file="${temp_dir}/stub.log"
  mkdir -p "$stub_dir"
  : > "$log_file"
  printf 'kernel\n' > "${temp_dir}/agent.x86_64-vmlinuz"
  printf 'initrd' > "${temp_dir}/agent.x86_64-initrd.img"
  printf 'rootfs' > "${temp_dir}/agent.x86_64-rootfs.img"

  cat > "${stub_dir}/basename" <<'EOF'
#!/bin/bash
/usr/bin/basename "$@"
EOF
  cat > "${stub_dir}/uname" <<'EOF'
#!/bin/bash
printf 'x86_64\n'
EOF
  cat > "${stub_dir}/apt-get" <<'EOF'
#!/bin/bash
printf 'apt-get %s\n' "$*" >> "${STUB_LOG:?}"
EOF
  cat > "${stub_dir}/debconf-set-selections" <<'EOF'
#!/bin/bash
while IFS= read -r _line; do :; done
printf 'debconf-set-selections\n' >> "${STUB_LOG:?}"
EOF
  cat > "${stub_dir}/cat" <<'EOF'
#!/bin/bash
/usr/bin/cat "$@"
EOF
  chmod +x "${stub_dir}/basename" "${stub_dir}/uname" "${stub_dir}/apt-get" "${stub_dir}/debconf-set-selections" "${stub_dir}/cat"

  PATH="$stub_dir" STUB_LOG="$log_file" HSPAGENT_TEST_MODE=1 /bin/bash -c '
    source "'"${AGENT_SCRIPT}"'"
    require_root() { return 0; }
    install_kexec_tools() {
      printf "install_kexec_tools\n" >> "${STUB_LOG:?}"
      cat > "'"${stub_dir}/kexec"'" <<'"'"'EOF'"'"'
#!/bin/bash
printf "kexec %s\n" "$*" >> "${STUB_LOG:?}"
EOF
      /usr/bin/chmod +x "'"${stub_dir}/kexec"'"
    }
    main --yes --artifact-dir "'"${temp_dir}"'"
  ' >/dev/null
  status=$?

  grep -q 'install_kexec_tools' "$log_file"
  grep -q 'kexec ' "$log_file"

  rm -rf "$temp_dir"
  return "$status"
}

run_warn_if_not_debian_12() {
  local script_path="$1"
  local os_release="$2"

  case "$script_path" in
    "$PREPARE_SCRIPT")
      OS_RELEASE_FILE="$os_release" HSPPXE_TEST_MODE=1 bash -c '
        source "'"${script_path}"'"
        warn_if_not_debian_12
      '
      ;;
    "$ASSISTED_SCRIPT")
      OS_RELEASE_FILE="$os_release" HSPHOST_TEST_MODE=1 bash -c '
        source "'"${script_path}"'"
        warn_if_not_debian_12
      '
      ;;
    "$AGENT_SCRIPT")
      OS_RELEASE_FILE="$os_release" HSPAGENT_TEST_MODE=1 bash -c '
        source "'"${script_path}"'"
        warn_if_not_debian_12
      '
      ;;
    *)
      return 1
      ;;
  esac
}

test_debian12_metadata_does_not_warn() {
  local temp_dir os_release stderr_file script_path status

  temp_dir="$(mktemp -d)"
  os_release="${temp_dir}/os-release"
  stderr_file="${temp_dir}/stderr.log"
  printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' > "$os_release"

  for script_path in "$PREPARE_SCRIPT" "$ASSISTED_SCRIPT" "$AGENT_SCRIPT"; do
    : > "$stderr_file"
    run_warn_if_not_debian_12 "$script_path" "$os_release" 2>"$stderr_file"
    status=$?

    if [[ "$status" -ne 0 || -s "$stderr_file" ]]; then
      rm -rf "$temp_dir"
      return 1
    fi
  done

  rm -rf "$temp_dir"
}

test_non_debian12_metadata_warns_without_failing() {
  local temp_dir os_release stderr_file script_path status

  temp_dir="$(mktemp -d)"
  os_release="${temp_dir}/os-release"
  stderr_file="${temp_dir}/stderr.log"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$os_release"

  for script_path in "$PREPARE_SCRIPT" "$ASSISTED_SCRIPT" "$AGENT_SCRIPT"; do
    : > "$stderr_file"
    run_warn_if_not_debian_12 "$script_path" "$os_release" 2>"$stderr_file"
    status=$?

    if [[ "$status" -ne 0 ]] ||
      [[ "$(cat "$stderr_file")" != "WARNING: This script is tested for Debian 12 Hetzner Rescue. Detected Ubuntu 24.04 LTS; it may fail." ]]; then
      rm -rf "$temp_dir"
      return 1
    fi
  done

  rm -rf "$temp_dir"
}

test_missing_os_release_warns_without_failing() {
  local temp_dir os_release stderr_file script_path status

  temp_dir="$(mktemp -d)"
  os_release="${temp_dir}/missing-os-release"
  stderr_file="${temp_dir}/stderr.log"

  for script_path in "$PREPARE_SCRIPT" "$ASSISTED_SCRIPT" "$AGENT_SCRIPT"; do
    : > "$stderr_file"
    run_warn_if_not_debian_12 "$script_path" "$os_release" 2>"$stderr_file"
    status=$?

    if [[ "$status" -ne 0 ]] ||
      ! grep -F 'WARNING: Could not read' "$stderr_file" >/dev/null ||
      ! grep -F 'This script is tested for Debian 12 Hetzner Rescue and may fail on other systems.' "$stderr_file" >/dev/null; then
      rm -rf "$temp_dir"
      return 1
    fi
  done

  rm -rf "$temp_dir"
}

test_malformed_os_release_warns_without_failing() {
  local temp_dir os_release stderr_file script_path status

  temp_dir="$(mktemp -d)"
  os_release="${temp_dir}/os-release"
  stderr_file="${temp_dir}/stderr.log"
  printf 'ID=ubuntu\nVERSION_ID="24.04"\nMALFORMED LINE WITHOUT EQUALS\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$os_release"

  for script_path in "$PREPARE_SCRIPT" "$ASSISTED_SCRIPT" "$AGENT_SCRIPT"; do
    : > "$stderr_file"
    run_warn_if_not_debian_12 "$script_path" "$os_release" 2>"$stderr_file"
    status=$?

    if [[ "$status" -ne 0 ]] ||
      [[ "$(cat "$stderr_file")" != "WARNING: This script is tested for Debian 12 Hetzner Rescue. Detected Ubuntu 24.04 LTS; it may fail." ]]; then
      rm -rf "$temp_dir"
      return 1
    fi
  done

  rm -rf "$temp_dir"
}

test_debian12_container_script_exists() {
  [[ -x "${REPO_ROOT}/scripts/test-debian12-container.sh" ]]
}

run_test "prepare parser accepts hardening flags" test_prepare_parse_args_accepts_hardening_flags
run_test "prepare dry-run avoids downloads and artifact writes" test_prepare_dry_run_avoids_downloads_and_writes_artifacts
run_test "install-config YAML uses quoted scalars" test_generate_yaml_uses_safe_quoted_scalars
run_test "assisted iPXE validation rejects missing kernel before side effects" test_assisted_rejects_invalid_ipxe_before_download_or_kexec
run_test "assisted dry-run avoids downloads and kexec" test_assisted_dry_run_avoids_downloads_and_kexec
run_test "prepare interactive refuses non-TTY" test_prepare_interactive_refuses_non_tty
run_test "prepare derives public key from existing private key" test_prepare_derives_public_key_from_existing_private_key
run_test "prepare dry-run does not write derived public key" test_prepare_dry_run_does_not_write_derived_public_key
run_test "agent dry-run validates missing artifacts without side effects" test_agent_dry_run_requires_existing_artifacts_without_cat_or_kexec
run_test "agent --yes skips confirmation and invokes kexec with valid artifacts" test_agent_yes_skips_confirmation_and_invokes_kexec_with_valid_artifacts
run_test "agent installs kexec before requiring binary" test_agent_installs_kexec_before_requiring_binary
run_test "Debian 12 metadata does not warn" test_debian12_metadata_does_not_warn
run_test "non-Debian 12 metadata warns without failing" test_non_debian12_metadata_warns_without_failing
run_test "missing os-release warns without failing" test_missing_os_release_warns_without_failing
run_test "malformed os-release warns without failing" test_malformed_os_release_warns_without_failing
run_test "Debian 12 container test script exists" test_debian12_container_script_exists

if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
