#!/bin/bash

# Prepare PXE files for agent-based OpenShift SNO installation on a Hetzner
# rescue environment (Debian 12).
#
# Usage:
#   ./hetzner-sno-prepare-pxe.sh [options] <ocp_version> <pull_secret_file> <base_domain> [cluster_name] [rendezvous_ip]

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly NMSTATECTL_VERSION="2.2.60"
readonly WORKDIR="${WORKDIR:-/root/ocp-prepare}"
readonly INSTALL_DIR="${INSTALL_DIR:-${WORKDIR}/install}"

die() {
  echo "ERROR: $*" >&2
  return 1
}

log_step() {
  echo "=== $* ==="
}

can_prompt() {
  [[ "${HSPPXE_ALLOW_NON_TTY_INTERACTIVE:-0}" == "1" ]] && return 0
  [[ -t 0 && -t 1 && -z "${CI:-}" ]]
}

confirm_or_die() {
  local prompt="$1"
  local answer

  if [[ "${DRY_RUN}" == "1" || "${YES}" == "1" ]]; then
    return 0
  fi

  if ! can_prompt; then
    die "Confirmation required before ${prompt}; rerun with --yes for automation."
    return 1
  fi

  read -r -p "Proceed with ${prompt}? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]] || die "Declined confirmation for ${prompt}."
}

prompt_value() {
  local variable_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local value

  if [[ -n "${!variable_name:-}" ]]; then
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " value
    printf -v "$variable_name" '%s' "${value:-$default_value}"
  else
    read -r -p "${label}: " value
    printf -v "$variable_name" '%s' "$value"
  fi
}

prompt_optional_value() {
  local variable_name="$1"
  local label="$2"
  local value

  if [[ -n "${!variable_name:-}" ]]; then
    return 0
  fi

  read -r -p "${label} (leave blank to auto-detect): " value
  printf -v "$variable_name" '%s' "$value"
}

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options] <ocp_version> <pull_secret_file> <base_domain> [cluster_name] [rendezvous_ip]

Options:
  --disk-device <path>       Block device for AgentConfig rootDeviceHints
  --artifact-dir <dir>       Directory for generated boot artifacts (default: /root)
  --bin-dir <dir>            Directory for oc and openshift-install (default: /usr/local/bin)
  --network-interface <name> Network interface to configure
  --ip-with-prefix <cidr>    IPv4 address with prefix, for example 192.0.2.10/24
  --gateway <ip>             Default IPv4 gateway
  --dns-server <ip>          DNS server; repeat for multiple values
  --hostname <name>          Node hostname for agent-config.yaml
  --ssh-key-file <path>      Private SSH key path; .pub is used/generated
  --dry-run                  Validate and print planned actions without writes/downloads
  --interactive              Prompt for missing values on a TTY
  --yes                      Skip confirmation prompts
  -h, --help                 Show this help

Examples:
  ${SCRIPT_NAME} 4.16.15 /root/pull-secret.json example.com sno
  ${SCRIPT_NAME} --disk-device /dev/nvme0n1 4.16.15 /root/pull-secret.json example.com sno
  ${SCRIPT_NAME} --dry-run --disk-device /dev/nvme0n1 4.16.15 ./pull-secret.json example.com sno
EOF
}

parse_args() {
  DRY_RUN=0
  INTERACTIVE=0
  YES=0
  DISK_DEVICE_OVERRIDE=""
  ARTIFACT_DIR="${ARTIFACT_DIR:-/root}"
  BIN_DIR="${BIN_DIR:-/usr/local/bin}"
  NETWORK_INTERFACE_OVERRIDE=""
  IP_WITH_PREFIX_OVERRIDE=""
  GATEWAY_OVERRIDE=""
  DNS_SERVERS_OVERRIDE=()
  HOSTNAME_OVERRIDE=""
  SSH_KEY_FILE="${SSH_KEY_FILE:-${HOME}/.ssh/id_rsa}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk-device)
        [[ $# -ge 2 ]] || { die "--disk-device requires a block device path."; print_usage; return 1; }
        DISK_DEVICE_OVERRIDE="$2"
        shift 2
        ;;
      --artifact-dir)
        [[ $# -ge 2 ]] || { die "--artifact-dir requires a directory path."; print_usage; return 1; }
        ARTIFACT_DIR="$2"
        shift 2
        ;;
      --bin-dir)
        [[ $# -ge 2 ]] || { die "--bin-dir requires a directory path."; print_usage; return 1; }
        BIN_DIR="$2"
        shift 2
        ;;
      --network-interface)
        [[ $# -ge 2 ]] || { die "--network-interface requires an interface name."; print_usage; return 1; }
        NETWORK_INTERFACE_OVERRIDE="$2"
        shift 2
        ;;
      --ip-with-prefix)
        [[ $# -ge 2 ]] || { die "--ip-with-prefix requires an IPv4 CIDR value."; print_usage; return 1; }
        IP_WITH_PREFIX_OVERRIDE="$2"
        shift 2
        ;;
      --gateway)
        [[ $# -ge 2 ]] || { die "--gateway requires an IPv4 address."; print_usage; return 1; }
        GATEWAY_OVERRIDE="$2"
        shift 2
        ;;
      --dns-server)
        [[ $# -ge 2 ]] || { die "--dns-server requires an IPv4 address."; print_usage; return 1; }
        DNS_SERVERS_OVERRIDE+=("$2")
        shift 2
        ;;
      --hostname)
        [[ $# -ge 2 ]] || { die "--hostname requires a hostname."; print_usage; return 1; }
        HOSTNAME_OVERRIDE="$2"
        shift 2
        ;;
      --ssh-key-file)
        [[ $# -ge 2 ]] || { die "--ssh-key-file requires a path."; print_usage; return 1; }
        SSH_KEY_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --help|-h)
        return 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        print_usage
        return 1
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -gt 5 ]] || [[ $# -lt 3 && "$INTERACTIVE" != "1" ]]; then
    print_usage
    return 1
  fi

  OCP_VERSION="${1:-}"
  PULL_SECRET_FILE="${2:-}"
  BASE_DOMAIN="${3:-}"
  CLUSTER_NAME="${4:-sno}"
  OVERRIDE_IP="${5:-}"
}

prompt_for_missing_config() {
  if [[ "$INTERACTIVE" != "1" ]]; then
    return 0
  fi

  if ! can_prompt; then
    die "--interactive requires a TTY; pass all required values explicitly in non-interactive shells."
    return 1
  fi

  prompt_value OCP_VERSION "OpenShift version"
  prompt_value PULL_SECRET_FILE "Pull secret file"
  prompt_value BASE_DOMAIN "Base domain"
  prompt_value CLUSTER_NAME "Cluster name" "sno"
  prompt_optional_value OVERRIDE_IP "Rendezvous IP"
  prompt_optional_value DISK_DEVICE_OVERRIDE "Install disk"
  prompt_optional_value NETWORK_INTERFACE_OVERRIDE "Network interface"
  prompt_optional_value IP_WITH_PREFIX_OVERRIDE "IPv4 address with prefix"
  prompt_optional_value GATEWAY_OVERRIDE "Gateway"
  prompt_optional_value HOSTNAME_OVERRIDE "Hostname"
  prompt_value SSH_KEY_FILE "SSH private key path" "$SSH_KEY_FILE"
  prompt_value ARTIFACT_DIR "Artifact directory" "$ARTIFACT_DIR"
  prompt_value BIN_DIR "Binary install directory" "$BIN_DIR"

  if [[ "${#DNS_SERVERS_OVERRIDE[@]}" -eq 0 ]]; then
    local dns_line
    read -r -p "DNS servers, comma-separated (leave blank to auto-detect): " dns_line
    if [[ -n "$dns_line" ]]; then
      IFS=',' read -r -a DNS_SERVERS_OVERRIDE <<< "$dns_line"
    fi
  fi
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "This script must run as root in the Hetzner rescue environment. Use --dry-run for workstation validation."
  fi
}

require_arch() {
  local arch
  arch="$(uname -m)"
  [[ "$arch" == "x86_64" ]] || die "Unsupported architecture ${arch}; only x86_64 is supported."
}

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

require_commands() {
  local missing=()
  local command_name

  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "Missing required command(s): ${missing[*]}"
  fi
}

curl_retry() {
  curl --location --fail --show-error --retry 5 --retry-delay 2 --connect-timeout 20 --max-time 600 "$@"
}

validate_required_inputs() {
  [[ -n "$OCP_VERSION" ]] || die "Missing OpenShift version."
  [[ -n "$PULL_SECRET_FILE" ]] || die "Missing pull secret file."
  [[ -n "$BASE_DOMAIN" ]] || die "Missing base domain."
  [[ -n "$CLUSTER_NAME" ]] || die "Missing cluster name."
  [[ -n "$ARTIFACT_DIR" ]] || die "Missing artifact directory."
  [[ -n "$BIN_DIR" ]] || die "Missing binary install directory."
  [[ -n "$SSH_KEY_FILE" ]] || die "Missing SSH key file path."
}

validate_pull_secret() {
  if [[ ! -f "$PULL_SECRET_FILE" ]]; then
    die "Pull secret file not found: $PULL_SECRET_FILE"
    return 1
  fi

  if ! python3 - "$PULL_SECRET_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    json.load(handle)
PY
  then
    die "Pull secret file does not contain valid JSON: $PULL_SECRET_FILE"
  fi
}

validate_ip_values() {
  local dns_raw
  dns_raw="$(printf '%s\n' "${DNS_SERVERS[@]:-}")"
  IP_WITH_PREFIX="$IP_WITH_PREFIX" GATEWAY="$GATEWAY" DNS_SERVERS_RAW="$dns_raw" python3 - <<'PY'
import ipaddress
import os
import sys

try:
    ipaddress.ip_interface(os.environ["IP_WITH_PREFIX"])
    ipaddress.ip_address(os.environ["GATEWAY"])
    for server in os.environ["DNS_SERVERS_RAW"].splitlines():
        if server.strip():
            ipaddress.ip_address(server.strip())
except ValueError as exc:
    print(f"ERROR: Invalid network value: {exc}", file=sys.stderr)
    sys.exit(1)
PY
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
    die "Disk device must be a /dev path: $device"
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
        die "Could not determine the parent disk for partition ${device}."
        return 1
      fi
      printf '/dev/%s\n' "$parent_device"
      ;;
    *)
      die "${device} is not a usable disk or partition device."
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
    die "Could not autodetect an install disk. Use --disk-device <path>."
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
    die "No checksum entry found for ${artifact_name} in ${checksum_file}."
    return 1
  fi

  if ! (
    cd "$(dirname "$artifact_path")"
    printf '%s\n' "$checksum_line" | sha256sum -c - >/dev/null 2>&1
  ); then
    die "SHA256 verification failed for ${artifact_name}."
    return 1
  fi
}

ensure_cargo_available() {
  local cargo_env="${HOME}/.cargo/env"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  DRY-RUN: would ensure Rust/Cargo is available."
    return 0
  fi

  if ! command -v cargo >/dev/null 2>&1; then
    echo "  Installing Rust toolchain..."
    curl_retry --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  fi

  if [[ -r "$cargo_env" ]]; then
    # shellcheck source=/dev/null
    source "$cargo_env"
  fi

  export PATH="${HOME}/.cargo/bin:${PATH}"

  if ! command -v cargo >/dev/null 2>&1; then
    die "cargo is not available after Rust installation."
  fi
}

ensure_nmstatectl() {
  local current_version_output=""

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  DRY-RUN: would install nmstatectl ${NMSTATECTL_VERSION} if needed."
    return 0
  fi

  if command -v nmstatectl >/dev/null 2>&1; then
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
      die "Unsupported OpenShift tool: ${binary_name}"
      return 1
      ;;
  esac
}

fetch_ocp_checksums() {
  local checksum_file="${WORKDIR}/sha256sum.txt"

  if [[ ! -f "$checksum_file" ]]; then
    echo "  Downloading OpenShift checksums for ${OCP_VERSION}..." >&2
    curl_retry -o "$checksum_file" "${OCP_MIRROR}/sha256sum.txt"
  fi

  printf '%s\n' "$checksum_file"
}

install_ocp_tool() {
  local binary_name="$1"
  local current_version_output=""
  local checksum_file
  local archive_name
  local archive_path

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  DRY-RUN: would ensure ${binary_name} ${OCP_VERSION} is installed in ${BIN_DIR}."
    return 0
  fi

  if command -v "$binary_name" >/dev/null 2>&1; then
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
  curl_retry -o "$archive_path" "${OCP_MIRROR}/${archive_name}"
  verify_download_checksum "$archive_path" "$checksum_file"
  tar -xzf "$archive_path" -C "$WORKDIR" "$binary_name"
  mkdir -p "$BIN_DIR"
  install -m 0755 "${WORKDIR}/${binary_name}" "${BIN_DIR}/${binary_name}"
  rm -f "$archive_path" "${WORKDIR:?}/${binary_name}"
}

resolve_network_config() {
  DEFAULT_IFACE="${NETWORK_INTERFACE_OVERRIDE:-}"
  if [[ -z "$DEFAULT_IFACE" ]]; then
    DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5}' | head -1)"
  fi
  [[ -n "$DEFAULT_IFACE" ]] || die "Could not determine the default network interface. Use --network-interface."

  IP_WITH_PREFIX="${IP_WITH_PREFIX_OVERRIDE:-}"
  if [[ -z "$IP_WITH_PREFIX" ]]; then
    IP_WITH_PREFIX="$(ip -4 addr show dev "$DEFAULT_IFACE" | awk '/inet / {print $2}' | head -1)"
  fi
  [[ -n "$IP_WITH_PREFIX" ]] || die "Could not determine the IPv4 address on ${DEFAULT_IFACE}. Use --ip-with-prefix."
  IP_ADDR="${IP_WITH_PREFIX%/*}"
  PREFIX_LEN="${IP_WITH_PREFIX#*/}"

  GATEWAY="${GATEWAY_OVERRIDE:-}"
  if [[ -z "$GATEWAY" ]]; then
    GATEWAY="$(ip route show default | awk '/default/ {print $3}' | head -1)"
  fi
  [[ -n "$GATEWAY" ]] || die "Could not determine the default gateway. Use --gateway."

  MAC_ADDR="$(ip link show "$DEFAULT_IFACE" | awk '/link\/ether/ {print $2}' | head -1)"
  [[ -n "$MAC_ADDR" ]] || die "Could not determine MAC address for ${DEFAULT_IFACE}."

  MACHINE_NETWORK="$(python3 - "$IP_WITH_PREFIX" <<'PY'
import ipaddress
import sys

print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"

  RENDEZVOUS_IP="${OVERRIDE_IP:-${IP_ADDR}}"
  NODE_HOSTNAME="${HOSTNAME_OVERRIDE:-}"
  if [[ -z "$NODE_HOSTNAME" ]]; then
    NODE_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
  fi

  if [[ "${#DNS_SERVERS_OVERRIDE[@]}" -gt 0 ]]; then
    DNS_SERVERS=("${DNS_SERVERS_OVERRIDE[@]}")
  else
    mapfile -t DNS_SERVERS < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf | head -3)
    if [[ "${#DNS_SERVERS[@]}" -eq 0 ]]; then
      DNS_SERVERS=("8.8.8.8" "8.8.4.4")
    fi
  fi

  validate_ip_values
  DNS_SERVERS_RAW="$(printf '%s\n' "${DNS_SERVERS[@]}")"
  DNS_DISPLAY="$(printf '%s ' "${DNS_SERVERS[@]}")"
}

ensure_ssh_public_key() {
  if [[ -f "${SSH_KEY_FILE}.pub" ]]; then
    SSH_PUB_KEY="$(cat "${SSH_KEY_FILE}.pub")"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    SSH_PUB_KEY="DRY-RUN-SSH-PUBLIC-KEY"
    echo "  DRY-RUN: would generate SSH key ${SSH_KEY_FILE}."
    return 0
  fi

  echo "  Generating SSH key ${SSH_KEY_FILE}..."
  mkdir -p "$(dirname "$SSH_KEY_FILE")"
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_FILE" -N "" -C "root@$(hostname)"
  SSH_PUB_KEY="$(cat "${SSH_KEY_FILE}.pub")"
}

generate_install_config() {
  HSP_PULL_SECRET_FILE="$PULL_SECRET_FILE" \
  HSP_INSTALL_DIR="$INSTALL_DIR" \
  HSP_BASE_DOMAIN="$BASE_DOMAIN" \
  HSP_CLUSTER_NAME="$CLUSTER_NAME" \
  HSP_MACHINE_NETWORK="$MACHINE_NETWORK" \
  HSP_SSH_PUB_KEY="$SSH_PUB_KEY" \
  python3 - <<'PY'
import json
import os

def q(value):
    return json.dumps(value)

with open(os.environ["HSP_PULL_SECRET_FILE"], encoding="utf-8") as handle:
    pull_secret = json.dumps(json.load(handle))

path = os.path.join(os.environ["HSP_INSTALL_DIR"], "install-config.yaml")
with open(path, "w", encoding="utf-8") as handle:
    handle.write("apiVersion: v1\n")
    handle.write(f"baseDomain: {q(os.environ['HSP_BASE_DOMAIN'])}\n")
    handle.write("metadata:\n")
    handle.write(f"  name: {q(os.environ['HSP_CLUSTER_NAME'])}\n")
    handle.write("networking:\n")
    handle.write("  networkType: OVNKubernetes\n")
    handle.write("  machineNetwork:\n")
    handle.write(f"  - cidr: {q(os.environ['HSP_MACHINE_NETWORK'])}\n")
    handle.write("compute:\n")
    handle.write("- name: worker\n")
    handle.write("  replicas: 0\n")
    handle.write("controlPlane:\n")
    handle.write("  name: master\n")
    handle.write("  replicas: 1\n")
    handle.write("platform:\n")
    handle.write("  none: {}\n")
    handle.write(f"pullSecret: {q(pull_secret)}\n")
    handle.write(f"sshKey: {q(os.environ['HSP_SSH_PUB_KEY'])}\n")
PY

  echo "  Written: ${INSTALL_DIR}/install-config.yaml"
}

generate_agent_config() {
  HSP_DNS_SERVERS_RAW="$DNS_SERVERS_RAW" \
  HSP_INSTALL_DIR="$INSTALL_DIR" \
  HSP_CLUSTER_NAME="$CLUSTER_NAME" \
  HSP_RENDEZVOUS_IP="$RENDEZVOUS_IP" \
  HSP_NODE_HOSTNAME="$NODE_HOSTNAME" \
  HSP_DEFAULT_IFACE="$DEFAULT_IFACE" \
  HSP_MAC_ADDR="$MAC_ADDR" \
  HSP_INSTALL_DISK="$INSTALL_DISK" \
  HSP_IP_ADDR="$IP_ADDR" \
  HSP_PREFIX_LEN="$PREFIX_LEN" \
  HSP_GATEWAY="$GATEWAY" \
  python3 - <<'PY'
import json
import os

def q(value):
    return json.dumps(value)

dns_servers = [line.strip() for line in os.environ["HSP_DNS_SERVERS_RAW"].splitlines() if line.strip()]
path = os.path.join(os.environ["HSP_INSTALL_DIR"], "agent-config.yaml")

with open(path, "w", encoding="utf-8") as handle:
    handle.write("apiVersion: v1alpha1\n")
    handle.write("kind: AgentConfig\n")
    handle.write("metadata:\n")
    handle.write(f"  name: {q(os.environ['HSP_CLUSTER_NAME'])}\n")
    handle.write(f"rendezvousIP: {q(os.environ['HSP_RENDEZVOUS_IP'])}\n")
    handle.write("hosts:\n")
    handle.write(f"  - hostname: {q(os.environ['HSP_NODE_HOSTNAME'])}\n")
    handle.write("    interfaces:\n")
    handle.write(f"      - name: {q(os.environ['HSP_DEFAULT_IFACE'])}\n")
    handle.write(f"        macAddress: {q(os.environ['HSP_MAC_ADDR'])}\n")
    handle.write("    rootDeviceHints:\n")
    handle.write(f"      deviceName: {q(os.environ['HSP_INSTALL_DISK'])}\n")
    handle.write("    networkConfig:\n")
    handle.write("      interfaces:\n")
    handle.write(f"        - name: {q(os.environ['HSP_DEFAULT_IFACE'])}\n")
    handle.write("          type: ethernet\n")
    handle.write("          state: up\n")
    handle.write(f"          mac-address: {q(os.environ['HSP_MAC_ADDR'])}\n")
    handle.write("          ipv4:\n")
    handle.write("            enabled: true\n")
    handle.write("            address:\n")
    handle.write(f"              - ip: {q(os.environ['HSP_IP_ADDR'])}\n")
    handle.write(f"                prefix-length: {int(os.environ['HSP_PREFIX_LEN'])}\n")
    handle.write("            dhcp: false\n")
    handle.write("      dns-resolver:\n")
    handle.write("        config:\n")
    handle.write("          server:\n")
    for server in dns_servers:
        handle.write(f"            - {q(server)}\n")
    handle.write("      routes:\n")
    handle.write("        config:\n")
    handle.write("          - destination: 0.0.0.0/0\n")
    handle.write(f"            next-hop-address: {q(os.environ['HSP_GATEWAY'])}\n")
    handle.write(f"            next-hop-interface: {q(os.environ['HSP_DEFAULT_IFACE'])}\n")
    handle.write("            table-id: 254\n")
PY

  echo "  Written: ${INSTALL_DIR}/agent-config.yaml"
}

safe_prepare_install_dir() {
  if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" == "/" || "$INSTALL_DIR" != "${WORKDIR}/"* ]]; then
    die "Refusing to clean unsafe install directory: ${INSTALL_DIR}"
    return 1
  fi

  mkdir -p "$WORKDIR"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
}

validate_boot_artifacts() {
  local boot_artifacts_dir="$1"
  local artifact

  [[ -d "$boot_artifacts_dir" ]] || die "boot-artifacts directory not found at ${boot_artifacts_dir}"
  for artifact in agent.x86_64-vmlinuz agent.x86_64-initrd.img agent.x86_64-rootfs.img; do
    [[ -s "${boot_artifacts_dir}/${artifact}" ]] || die "Missing generated boot artifact: ${boot_artifacts_dir}/${artifact}"
  done
}

print_resolved_config() {
  echo "Resolved configuration:"
  echo "  OpenShift version: ${OCP_VERSION}"
  echo "  Pull secret:       ${PULL_SECRET_FILE}"
  echo "  Base domain:       ${BASE_DOMAIN}"
  echo "  Cluster name:      ${CLUSTER_NAME}"
  echo "  Interface:         ${DEFAULT_IFACE}"
  echo "  IP/prefix:         ${IP_WITH_PREFIX}"
  echo "  Gateway:           ${GATEWAY}"
  echo "  MAC:               ${MAC_ADDR}"
  echo "  Machine network:   ${MACHINE_NETWORK}"
  echo "  Rendezvous IP:     ${RENDEZVOUS_IP}"
  echo "  Hostname:          ${NODE_HOSTNAME}"
  echo "  DNS servers:       ${DNS_DISPLAY% }"
  echo "  Install disk:      ${INSTALL_DISK}"
  echo "  SSH key file:      ${SSH_KEY_FILE}"
  echo "  Work directory:    ${WORKDIR}"
  echo "  Artifact dir:      ${ARTIFACT_DIR}"
  echo "  Binary dir:        ${BIN_DIR}"
}

main() {
  local parse_status
  local boot_artifacts_dir

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

  prompt_for_missing_config
  validate_required_inputs
  require_arch
  warn_if_not_debian_12
  require_commands python3 awk head lsblk findmnt ip hostname
  validate_pull_secret
  resolve_network_config
  INSTALL_DISK="$(resolve_install_disk)"
  ensure_ssh_public_key
  print_resolved_config

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: would install dependencies, download OpenShift tools, generate configs, create PXE files, and copy artifacts."
    return 0
  fi

  require_root
  require_commands curl tar install sha256sum ssh-keygen
  confirm_or_die "package installation, artifact generation, and writes to ${ARTIFACT_DIR}"

  safe_prepare_install_dir

  log_step "Step 1: Installing Rust/Cargo and nmstatectl"
  ensure_cargo_available
  ensure_nmstatectl
  echo "  nmstatectl: $(nmstatectl --version)"

  log_step "Step 2: Downloading OpenShift tools"
  OCP_MIRROR="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}"
  rm -f "${WORKDIR}/sha256sum.txt"
  install_ocp_tool oc
  install_ocp_tool openshift-install
  echo "  oc:                 $(oc version --client 2>/dev/null | head -1)"
  echo "  openshift-install:  $(openshift-install version 2>/dev/null | head -1)"

  log_step "Step 3: Generating install-config.yaml"
  generate_install_config

  log_step "Step 4: Generating agent-config.yaml"
  generate_agent_config

  log_step "Step 5: Running openshift-install agent create pxe-files"
  cp "${INSTALL_DIR}/install-config.yaml" "${WORKDIR}/install-config.yaml.bak"
  cp "${INSTALL_DIR}/agent-config.yaml" "${WORKDIR}/agent-config.yaml.bak"
  openshift-install agent create pxe-files --dir "${INSTALL_DIR}" --log-level info

  log_step "Step 6: Copying boot artifacts to ${ARTIFACT_DIR}"
  boot_artifacts_dir="${INSTALL_DIR}/boot-artifacts"
  validate_boot_artifacts "$boot_artifacts_dir"
  mkdir -p "$ARTIFACT_DIR"
  cp "${boot_artifacts_dir}/agent.x86_64-"* "$ARTIFACT_DIR/"
  echo "  Copied files to ${ARTIFACT_DIR}:"
  ls -lh "${ARTIFACT_DIR}/agent.x86_64-"*

  echo ""
  log_step "Done"
  echo "Boot artifacts are in ${ARTIFACT_DIR}. You can now run:"
  echo "  ./hetzner-sno-provision-host-agentbased.sh --artifact-dir ${ARTIFACT_DIR}"
  echo "to kexec into the agent installer."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
