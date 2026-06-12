#!/bin/bash

# Prepare PXE files for agent-based OpenShift SNO installation on a Hetzner
# rescue environment (Debian 12).
#
# This script:
#   1. Installs Rust/Cargo and nmstatectl (required by openshift-install to
#      validate the NMState YAML schema in agent-config.yaml).
#   2. Downloads version-matched OpenShift CLI tools with checksum validation.
#   3. Inspects the rescue machine's network and generates install-config.yaml
#      and agent-config.yaml.
#   4. Runs "openshift-install agent create pxe-files".
#   5. Copies the resulting boot artifacts to /root so that
#      hetzner-sno-provision-host-agentbased.sh can boot them with kexec.
#
# Usage:
#   ./hetzner-sno-prepare-pxe.sh [--disk-device <device_path>] <ocp_version> <pull_secret_file> <base_domain> [cluster_name] [rendezvous_ip]
#
# Arguments:
#   --disk-device   - (optional) Block device to use for AgentConfig rootDeviceHints
#   ocp_version     - OpenShift version to install, e.g. 4.16.15
#   pull_secret_file- Path to a file containing your Red Hat pull secret JSON
#   base_domain     - Base DNS domain for the cluster, e.g. example.com
#   cluster_name    - (optional) Cluster name, defaults to "sno"
#   rendezvous_ip   - (optional) IP to use as rendezvousIP; auto-detected if omitted
#
# After this script completes, run hetzner-sno-provision-host-agentbased.sh to
# kexec into the agent installer kernel.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly NMSTATECTL_VERSION="2.2.60"
readonly WORKDIR="${WORKDIR:-/root/ocp-prepare}"
readonly INSTALL_DIR="${INSTALL_DIR:-${WORKDIR}/install}"

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [--disk-device <device_path>] <ocp_version> <pull_secret_file> <base_domain> [cluster_name] [rendezvous_ip]
Example: ${SCRIPT_NAME} 4.16.15 /root/pull-secret.json example.com sno
Example: ${SCRIPT_NAME} --disk-device /dev/nvme0n1 4.16.15 /root/pull-secret.json example.com sno
EOF
}

parse_args() {
  DISK_DEVICE_OVERRIDE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk-device)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --disk-device requires a block device path." >&2
          print_usage
          return 1
        fi
        DISK_DEVICE_OVERRIDE="$2"
        shift 2
        ;;
      --help|-h)
        return 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "ERROR: Unknown option: $1" >&2
        print_usage
        return 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -lt 3 || $# -gt 5 ]]; then
    print_usage
    return 1
  fi

  OCP_VERSION="$1"
  PULL_SECRET_FILE="$2"
  BASE_DOMAIN="$3"
  CLUSTER_NAME="${4:-sno}"
  OVERRIDE_IP="${5:-}"
}

validate_pull_secret() {
  if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    echo "ERROR: Pull secret file not found: $PULL_SECRET_FILE" >&2
    return 1
  fi

  if ! python3 - "$PULL_SECRET_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    json.load(handle)
PY
  then
    echo "ERROR: Pull secret file does not contain valid JSON: $PULL_SECRET_FILE" >&2
    return 1
  fi
}

version_matches_requested() {
  local requested_version="$1"
  local version_output="$2"
  local escaped_version="${requested_version//./\\.}"

  [[ "$version_output" =~ (^|[^0-9])${escaped_version}([^0-9]|$) ]]
}

normalize_disk_device() {
  local device="$1"
  local device_type
  local parent_device

  if [[ "$device" != /dev/* ]]; then
    echo "ERROR: Disk device must be a /dev path: $device" >&2
    return 1
  fi

  device_type="$(lsblk -ndo TYPE "$device" 2>/dev/null | head -1 || true)"

  case "$device_type" in
    disk)
      printf '%s\n' "$device"
      ;;
    part)
      parent_device="$(lsblk -ndo PKNAME "$device" 2>/dev/null | head -1 || true)"
      if [[ -z "$parent_device" ]]; then
        echo "ERROR: Could not determine the parent disk for partition ${device}." >&2
        return 1
      fi
      printf '/dev/%s\n' "$parent_device"
      ;;
    *)
      echo "ERROR: ${device} is not a usable disk or partition device." >&2
      return 1
      ;;
  esac
}

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

  mapfile -t candidate_disks < <(lsblk -dnpo NAME,TYPE,RM 2>/dev/null | awk '$2 == "disk" && $3 == "0" {print $1}')

  if [[ "${#candidate_disks[@]}" -eq 1 ]]; then
    printf '%s\n' "${candidate_disks[0]}"
    return 0
  fi

  if [[ "${#candidate_disks[@]}" -eq 0 ]]; then
    echo "ERROR: Could not autodetect an install disk. Use --disk-device <path>." >&2
  else
    echo "ERROR: Multiple candidate install disks detected: ${candidate_disks[*]}" >&2
    echo "Use --disk-device <path> to choose one explicitly." >&2
  fi

  return 1
}

resolve_install_disk() {
  if [[ -n "${DISK_DEVICE_OVERRIDE}" ]]; then
    normalize_disk_device "$DISK_DEVICE_OVERRIDE"
  else
    detect_install_disk
  fi
}

verify_download_checksum() {
  local artifact_path="$1"
  local checksum_file="$2"
  local artifact_name
  local checksum_line

  artifact_name="$(basename "$artifact_path")"
  checksum_line="$(awk -v target="$artifact_name" '$2 == target || $2 == "*" target {print; exit}' "$checksum_file")"

  if [[ -z "$checksum_line" ]]; then
    echo "ERROR: No checksum entry found for ${artifact_name} in ${checksum_file}." >&2
    return 1
  fi

  if ! (
    cd "$(dirname "$artifact_path")"
    printf '%s\n' "$checksum_line" | sha256sum -c - >/dev/null 2>&1
  ); then
    echo "ERROR: SHA256 verification failed for ${artifact_name}." >&2
    return 1
  fi
}

ensure_cargo_available() {
  local cargo_env="${HOME}/.cargo/env"

  if ! command -v cargo &>/dev/null; then
    echo "  Installing Rust toolchain..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  fi

  if [[ -r "$cargo_env" ]]; then
    # shellcheck source=/dev/null
    source "$cargo_env"
  fi

  export PATH="${HOME}/.cargo/bin:${PATH}"

  if ! command -v cargo &>/dev/null; then
    echo "ERROR: cargo is not available after Rust installation." >&2
    return 1
  fi
}

ensure_nmstatectl() {
  local current_version_output=""

  if command -v nmstatectl &>/dev/null; then
    current_version_output="$(nmstatectl --version 2>/dev/null | head -1 || true)"
    if version_matches_requested "$NMSTATECTL_VERSION" "$current_version_output"; then
      echo "  Reusing nmstatectl: ${current_version_output}"
      return 0
    fi
    echo "  Existing nmstatectl version does not match ${NMSTATECTL_VERSION}; replacing it."
  fi

  echo "  Installing nmstatectl ${NMSTATECTL_VERSION} via cargo..."
  cargo install --locked --force --version "$NMSTATECTL_VERSION" nmstatectl
}

get_ocp_tool_version_output() {
  case "$1" in
    oc)
      oc version --client 2>/dev/null | head -1 || true
      ;;
    openshift-install)
      openshift-install version 2>/dev/null | head -1 || true
      ;;
    *)
      return 1
      ;;
  esac
}

ocp_archive_name() {
  local binary_name="$1"

  case "$binary_name" in
    oc)
      printf 'openshift-client-linux-%s.tar.gz\n' "$OCP_VERSION"
      ;;
    openshift-install)
      printf 'openshift-install-linux-%s.tar.gz\n' "$OCP_VERSION"
      ;;
    *)
      echo "ERROR: Unsupported OpenShift tool: ${binary_name}" >&2
      return 1
      ;;
  esac
}

fetch_ocp_checksums() {
  local checksum_file="${WORKDIR}/sha256sum.txt"

  if [[ ! -f "$checksum_file" ]]; then
    echo "  Downloading OpenShift checksums for ${OCP_VERSION}..." >&2
    curl -L -f -o "$checksum_file" "${OCP_MIRROR}/sha256sum.txt"
  fi

  printf '%s\n' "$checksum_file"
}

install_ocp_tool() {
  local binary_name="$1"
  local current_version_output=""
  local checksum_file
  local archive_name
  local archive_path

  if command -v "$binary_name" &>/dev/null; then
    current_version_output="$(get_ocp_tool_version_output "$binary_name")"
    if version_matches_requested "$OCP_VERSION" "$current_version_output"; then
      echo "  Reusing ${binary_name}: ${current_version_output}"
      return 0
    fi
    echo "  Existing ${binary_name} version does not match ${OCP_VERSION}; replacing it."
  fi

  archive_name="$(ocp_archive_name "$binary_name")"
  archive_path="${WORKDIR}/${archive_name}"
  checksum_file="$(fetch_ocp_checksums)"
  echo "  Downloading ${binary_name} ${OCP_VERSION}..."
  curl -L -f -o "$archive_path" "${OCP_MIRROR}/${archive_name}"
  verify_download_checksum "$archive_path" "$checksum_file"
  tar -xzf "$archive_path" -C "$WORKDIR" "$binary_name"
  install -m 0755 "${WORKDIR}/${binary_name}" "/usr/local/bin/${binary_name}"
  rm -f "$archive_path" "${WORKDIR}/${binary_name}"
}

generate_install_config() {
  PULL_SECRET_FILE="$PULL_SECRET_FILE" \
  INSTALL_DIR="$INSTALL_DIR" \
  BASE_DOMAIN="$BASE_DOMAIN" \
  CLUSTER_NAME="$CLUSTER_NAME" \
  MACHINE_NETWORK="$MACHINE_NETWORK" \
  SSH_PUB_KEY="$SSH_PUB_KEY" \
  python3 - <<'PY'
import json
import os

with open(os.environ["PULL_SECRET_FILE"], encoding="utf-8") as handle:
    pull_secret = json.dumps(json.load(handle))

path = os.path.join(os.environ["INSTALL_DIR"], "install-config.yaml")
with open(path, "w", encoding="utf-8") as handle:
    handle.write("apiVersion: v1\n")
    handle.write(f"baseDomain: {os.environ['BASE_DOMAIN']}\n")
    handle.write("metadata:\n")
    handle.write(f"  name: {os.environ['CLUSTER_NAME']}\n")
    handle.write("networking:\n")
    handle.write("  networkType: OVNKubernetes\n")
    handle.write("  machineNetwork:\n")
    handle.write(f"  - cidr: {os.environ['MACHINE_NETWORK']}\n")
    handle.write("compute:\n")
    handle.write("- name: worker\n")
    handle.write("  replicas: 0\n")
    handle.write("controlPlane:\n")
    handle.write("  name: master\n")
    handle.write("  replicas: 1\n")
    handle.write("platform:\n")
    handle.write("  none: {}\n")
    handle.write(f"pullSecret: '{pull_secret}'\n")
    handle.write(f"sshKey: '{os.environ['SSH_PUB_KEY']}'\n")
PY

  echo "  Written: ${INSTALL_DIR}/install-config.yaml"
}

generate_agent_config() {
  DNS_SERVERS_RAW="$DNS_SERVERS_RAW" \
  INSTALL_DIR="$INSTALL_DIR" \
  CLUSTER_NAME="$CLUSTER_NAME" \
  RENDEZVOUS_IP="$RENDEZVOUS_IP" \
  NODE_HOSTNAME="$NODE_HOSTNAME" \
  DEFAULT_IFACE="$DEFAULT_IFACE" \
  MAC_ADDR="$MAC_ADDR" \
  INSTALL_DISK="$INSTALL_DISK" \
  IP_ADDR="$IP_ADDR" \
  PREFIX_LEN="$PREFIX_LEN" \
  GATEWAY="$GATEWAY" \
  python3 - <<'PY'
import os

dns_servers = [line.strip() for line in os.environ["DNS_SERVERS_RAW"].splitlines() if line.strip()]
path = os.path.join(os.environ["INSTALL_DIR"], "agent-config.yaml")

with open(path, "w", encoding="utf-8") as handle:
    handle.write("apiVersion: v1alpha1\n")
    handle.write("kind: AgentConfig\n")
    handle.write("metadata:\n")
    handle.write(f"  name: {os.environ['CLUSTER_NAME']}\n")
    handle.write(f"rendezvousIP: {os.environ['RENDEZVOUS_IP']}\n")
    handle.write("hosts:\n")
    handle.write(f"  - hostname: {os.environ['NODE_HOSTNAME']}\n")
    handle.write("    interfaces:\n")
    handle.write(f"      - name: {os.environ['DEFAULT_IFACE']}\n")
    handle.write(f"        macAddress: {os.environ['MAC_ADDR']}\n")
    handle.write("    rootDeviceHints:\n")
    handle.write(f"      deviceName: {os.environ['INSTALL_DISK']}\n")
    handle.write("    networkConfig:\n")
    handle.write("      interfaces:\n")
    handle.write(f"        - name: {os.environ['DEFAULT_IFACE']}\n")
    handle.write("          type: ethernet\n")
    handle.write("          state: up\n")
    handle.write(f"          mac-address: {os.environ['MAC_ADDR']}\n")
    handle.write("          ipv4:\n")
    handle.write("            enabled: true\n")
    handle.write("            address:\n")
    handle.write(f"              - ip: {os.environ['IP_ADDR']}\n")
    handle.write(f"                prefix-length: {os.environ['PREFIX_LEN']}\n")
    handle.write("            dhcp: false\n")
    handle.write("      dns-resolver:\n")
    handle.write("        config:\n")
    handle.write("          server:\n")
    for server in dns_servers:
        handle.write(f"            - {server}\n")
    handle.write("      routes:\n")
    handle.write("        config:\n")
    handle.write("          - destination: 0.0.0.0/0\n")
    handle.write(f"            next-hop-address: {os.environ['GATEWAY']}\n")
    handle.write(f"            next-hop-interface: {os.environ['DEFAULT_IFACE']}\n")
    handle.write("            table-id: 254\n")
PY

  echo "  Written: ${INSTALL_DIR}/agent-config.yaml"
}

main() {
  local parse_status

  if parse_args "$@"; then
    parse_status=0
  else
    parse_status=$?
  fi
  case "$parse_status" in
    0)
      ;;
    2)
      print_usage
      return 0
      ;;
    *)
      return "$parse_status"
      ;;
  esac

  validate_pull_secret

  mkdir -p "$WORKDIR"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"

  echo "=== Step 1: Installing Rust/Cargo and nmstatectl ==="
  ensure_cargo_available
  ensure_nmstatectl
  echo "  nmstatectl: $(nmstatectl --version)"

  echo "=== Step 2: Downloading OpenShift tools ==="
  OCP_MIRROR="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}"
  rm -f "${WORKDIR}/sha256sum.txt"
  install_ocp_tool oc
  install_ocp_tool openshift-install
  echo "  oc:                 $(oc version --client 2>/dev/null | head -1)"
  echo "  openshift-install:  $(openshift-install version 2>/dev/null | head -1)"

  echo "=== Step 3: Inspecting machine network ==="
  DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5}' | head -1)"
  if [[ -z "$DEFAULT_IFACE" ]]; then
    echo "ERROR: Could not determine the default network interface." >&2
    return 1
  fi

  IP_WITH_PREFIX="$(ip -4 addr show dev "$DEFAULT_IFACE" | awk '/inet / {print $2}' | head -1)"
  if [[ -z "$IP_WITH_PREFIX" ]]; then
    echo "ERROR: Could not determine the IPv4 address on ${DEFAULT_IFACE}." >&2
    return 1
  fi
  IP_ADDR="${IP_WITH_PREFIX%/*}"
  PREFIX_LEN="${IP_WITH_PREFIX#*/}"

  GATEWAY="$(ip route show default | awk '/default/ {print $3}' | head -1)"
  if [[ -z "$GATEWAY" ]]; then
    echo "ERROR: Could not determine the default gateway." >&2
    return 1
  fi

  MAC_ADDR="$(ip link show "$DEFAULT_IFACE" | awk '/link\/ether/ {print $2}')"
  MACHINE_NETWORK="$(python3 - "$IP_WITH_PREFIX" <<'PY'
import ipaddress
import sys

print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
  RENDEZVOUS_IP="${OVERRIDE_IP:-${IP_ADDR}}"
  NODE_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
  mapfile -t DNS_SERVERS < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf | head -3)
  if [[ "${#DNS_SERVERS[@]}" -eq 0 ]]; then
    DNS_SERVERS=("8.8.8.8" "8.8.4.4")
  fi
  DNS_SERVERS_RAW="$(printf '%s\n' "${DNS_SERVERS[@]}")"
  DNS_DISPLAY="$(printf '%s ' "${DNS_SERVERS[@]}")"
  INSTALL_DISK="$(resolve_install_disk)"

  echo "  Interface:       ${DEFAULT_IFACE}"
  echo "  IP/prefix:       ${IP_WITH_PREFIX}"
  echo "  Gateway:         ${GATEWAY}"
  echo "  MAC:             ${MAC_ADDR}"
  echo "  Machine network: ${MACHINE_NETWORK}"
  echo "  Rendezvous IP:   ${RENDEZVOUS_IP}"
  echo "  Hostname:        ${NODE_HOSTNAME}"
  echo "  DNS servers:     ${DNS_DISPLAY% }"
  echo "  Install disk:    ${INSTALL_DISK}"

  SSH_KEY_FILE="${HOME}/.ssh/id_rsa"
  if [[ ! -f "${SSH_KEY_FILE}" ]]; then
    echo "=== Generating SSH key ==="
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_FILE}" -N "" -C "root@$(hostname)"
  fi
  SSH_PUB_KEY="$(cat "${SSH_KEY_FILE}.pub")"

  echo "=== Step 4: Generating install-config.yaml ==="
  generate_install_config

  echo "=== Step 5: Generating agent-config.yaml ==="
  generate_agent_config

  echo "=== Step 6: Running openshift-install agent create pxe-files ==="
  cp "${INSTALL_DIR}/install-config.yaml" "${WORKDIR}/install-config.yaml.bak"
  cp "${INSTALL_DIR}/agent-config.yaml" "${WORKDIR}/agent-config.yaml.bak"
  openshift-install agent create pxe-files --dir "${INSTALL_DIR}" --log-level info

  echo "=== Step 7: Copying boot artifacts to /root ==="
  BOOT_ARTIFACTS_DIR="${INSTALL_DIR}/boot-artifacts"
  if [[ ! -d "$BOOT_ARTIFACTS_DIR" ]]; then
    echo "ERROR: boot-artifacts directory not found at ${BOOT_ARTIFACTS_DIR}" >&2
    echo "  openshift-install may have placed them elsewhere. Check ${INSTALL_DIR}:" >&2
    ls -la "${INSTALL_DIR}"
    return 1
  fi

  cp "${BOOT_ARTIFACTS_DIR}/"* /root/
  echo "  Copied files to /root:"
  ls -lh /root/agent.x86_64-* 2>/dev/null || ls -lh /root/

  echo ""
  echo "=== Done! ==="
  echo "Boot artifacts are in /root. You can now run:"
  echo "  ./hetzner-sno-provision-host-agentbased.sh"
  echo "to kexec into the agent installer."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
