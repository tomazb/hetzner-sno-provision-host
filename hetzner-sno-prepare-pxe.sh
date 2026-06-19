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
readonly CONFIG_FILE="${SNO_CONFIG_FILE:-/root/.sno-prepare.conf}"

cleanup_on_signal() {
  if [[ -n "${PARTIAL_DOWNLOAD:-}" && -f "$PARTIAL_DOWNLOAD" ]]; then
    rm -f "$PARTIAL_DOWNLOAD"
  fi
  exit 1
}

cleanup_on_exit() {
  if [[ -n "${PARTIAL_DOWNLOAD:-}" && -f "$PARTIAL_DOWNLOAD" ]]; then
    rm -f "$PARTIAL_DOWNLOAD"
  fi
}
trap cleanup_on_signal INT TERM
trap cleanup_on_exit EXIT

die() {
  echo "ERROR: $*" >&2
  return 1
}

log_step() {
  echo "=== $* ==="
}

can_prompt() {
  [[ "${HSPPXE_ALLOW_NON_TTY_INTERACTIVE:-0}" == "1" ]] && return 0
  # Disk selection is resolved via command substitution in main(), so only stdin
  # is guaranteed to remain attached to the operator's TTY at that point.
  [[ -t 0 && -z "${CI:-}" ]]
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
  local default_value="${3:-}"
  local value

  if [[ -n "${!variable_name:-}" ]]; then
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " value
    printf -v "$variable_name" '%s' "${value:-$default_value}"
  else
    read -r -p "${label} (leave blank to auto-detect): " value
    printf -v "$variable_name" '%s' "$value"
  fi
}

find_pull_secret_candidates() {
  local search_root="${1:-$HOME}"
  find "$search_root" -maxdepth 3 -name 'pull-secret.*' -type f 2>/dev/null | sort
}

find_ssh_pub_candidates() {
  local search_root="${1:-$HOME}"
  find "$search_root" -maxdepth 3 -name '*.pub' -type f 2>/dev/null \
    | while IFS= read -r f; do
        head -1 "$f" | grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-)' && printf '%s\n' "$f"
      done \
    | sort
}

prompt_file_choice() {
  local label="$1"
  shift
  local -a candidates=("$@")
  local selection

  while true; do
    echo "Found ${label} files:" >&2
    local index=1
    for f in "${candidates[@]}"; do
      printf '  [%d] %s\n' "$index" "$f" >&2
      index=$((index + 1))
    done
    if ! read -r -p "Select ${label} [1-${#candidates[@]}]: " selection; then
      die "Input closed while selecting ${label}."
      return 1
    fi
    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#candidates[@]} )); then
      printf '%s\n' "${candidates[$((selection - 1))]}"
      return 0
    fi
    echo "ERROR: Invalid selection '${selection}'. Enter a number from 1 to ${#candidates[@]}." >&2
  done
}

declare -A _SAVED=()

load_saved_config() {
  _SAVED=()
  if [[ ! -r "$CONFIG_FILE" ]]; then
    return 0
  fi
  local key val
  while IFS='=' read -r key val; do
    key="${key#"${key%%[![:space:]]*}"}"
    [[ -z "$key" || "$key" == "#"* ]] && continue
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    _SAVED["$key"]="$val"
  done < "$CONFIG_FILE"
}

save_config() {
  local dns_joined=""
  local hostname="${NODE_HOSTNAME:-${HOSTNAME_OVERRIDE:-}}"
  local iface="${DEFAULT_IFACE:-${NETWORK_INTERFACE_OVERRIDE:-}}"
  local ip="${IP_WITH_PREFIX:-${IP_WITH_PREFIX_OVERRIDE:-}}"
  local gw="${GATEWAY:-${GATEWAY_OVERRIDE:-}}"
  local rendezvous="${RENDEZVOUS_IP:-${OVERRIDE_IP:-}}"

  if [[ "${#DNS_SERVERS_OVERRIDE[@]}" -gt 0 ]]; then
    dns_joined="$(IFS=','; echo "${DNS_SERVERS_OVERRIDE[*]}")"
  elif [[ -n "${DNS_SERVERS+set}" && ${#DNS_SERVERS[@]} -gt 0 ]]; then
    dns_joined="$(IFS=','; echo "${DNS_SERVERS[*]}")"
  fi

  cat > "$CONFIG_FILE" <<EOF
OCP_VERSION=${OCP_VERSION}
PULL_SECRET_FILE=${PULL_SECRET_FILE}
BASE_DOMAIN=${BASE_DOMAIN}
CLUSTER_NAME=${CLUSTER_NAME}
HOSTNAME_OVERRIDE=${hostname}
SSH_PUBLIC_KEY_FILE=${SSH_PUBLIC_KEY_FILE:-}
SSH_PUB_KEY=${SSH_PUB_KEY:-}
ARTIFACT_DIR=${ARTIFACT_DIR:-/root}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
NETWORK_INTERFACE_OVERRIDE=${iface}
IP_WITH_PREFIX_OVERRIDE=${ip}
GATEWAY_OVERRIDE=${gw}
OVERRIDE_IP=${rendezvous}
DNS_SERVERS_OVERRIDE=${dns_joined}
EOF
  chmod 600 "$CONFIG_FILE"
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
  --ipv6-with-prefix <cidr>  IPv6 address with prefix, for example 2a01:db8::1/64
  --ipv6-gateway <ip>        Default IPv6 gateway (may be link-local, e.g. fe80::1)
  --ip-family <v4|v6|dual>   Force/validate the configured IP family set
  --cluster-network <cidr[,hostPrefix]>  Override clusterNetwork (repeatable)
  --service-network <cidr>   Override serviceNetwork (repeatable)
  --dns-server <ip>          DNS server; repeat for multiple values
  --hostname <name>          Node hostname for agent-config.yaml
  --ssh-public-key-file <path> SSH public key file path
  --ssh-key-file <path>      Alias for --ssh-public-key-file
  --dry-run                  Validate and print planned actions without writes/downloads
  --interactive              Prompt for missing values on a TTY
  --yes                      Skip confirmation prompts
  -h, --help                 Show this help

Examples:
  ${SCRIPT_NAME} 4.22.1 /root/pull-secret.json example.com sno
  ${SCRIPT_NAME} --disk-device /dev/nvme0n1 4.22.1 /root/pull-secret.json example.com sno
  ${SCRIPT_NAME} --dry-run --disk-device /dev/nvme0n1 4.22.1 ./pull-secret.json example.com sno
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
  IPV6_WITH_PREFIX_OVERRIDE=""
  IPV6_GATEWAY_OVERRIDE=""
  IP_FAMILY_OVERRIDE=""
  CLUSTER_NETWORKS=()
  SERVICE_NETWORKS=()
  DNS_SERVERS_OVERRIDE=()
  DNS_SERVERS=()
  HOSTNAME_OVERRIDE=""
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-}"
  SSH_PUB_KEY="${SSH_PUB_KEY:-}"

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
      --artifact-dir)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --artifact-dir requires a directory path." >&2
          print_usage
          return 1
        fi
        ARTIFACT_DIR="$2"
        shift 2
        ;;
      --bin-dir)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --bin-dir requires a directory path." >&2
          print_usage
          return 1
        fi
        BIN_DIR="$2"
        shift 2
        ;;
      --network-interface)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --network-interface requires an interface name." >&2
          print_usage
          return 1
        fi
        NETWORK_INTERFACE_OVERRIDE="$2"
        shift 2
        ;;
      --ip-with-prefix)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --ip-with-prefix requires an IPv4 CIDR value." >&2
          print_usage
          return 1
        fi
        IP_WITH_PREFIX_OVERRIDE="$2"
        shift 2
        ;;
      --gateway)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --gateway requires an IPv4 address." >&2
          print_usage
          return 1
        fi
        GATEWAY_OVERRIDE="$2"
        shift 2
        ;;
      --ipv6-with-prefix)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --ipv6-with-prefix requires an IPv6 CIDR value." >&2
          print_usage
          return 1
        fi
        IPV6_WITH_PREFIX_OVERRIDE="$2"
        shift 2
        ;;
      --ipv6-gateway)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --ipv6-gateway requires an IPv6 address." >&2
          print_usage
          return 1
        fi
        IPV6_GATEWAY_OVERRIDE="$2"
        shift 2
        ;;
      --ip-family)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --ip-family requires one of: v4, v6, dual." >&2
          print_usage
          return 1
        fi
        case "$2" in
          v4|v6|dual) IP_FAMILY_OVERRIDE="$2" ;;
          *)
            echo "ERROR: --ip-family must be v4, v6, or dual (got '$2')." >&2
            print_usage
            return 1
            ;;
        esac
        shift 2
        ;;
      --cluster-network)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --cluster-network requires a CIDR value." >&2
          print_usage
          return 1
        fi
        CLUSTER_NETWORKS+=("$2")
        shift 2
        ;;
      --service-network)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --service-network requires a CIDR value." >&2
          print_usage
          return 1
        fi
        SERVICE_NETWORKS+=("$2")
        shift 2
        ;;
      --dns-server)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --dns-server requires an IPv4 address." >&2
          print_usage
          return 1
        fi
        DNS_SERVERS_OVERRIDE+=("$2")
        shift 2
        ;;
      --hostname)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --hostname requires a hostname." >&2
          print_usage
          return 1
        fi
        HOSTNAME_OVERRIDE="$2"
        shift 2
        ;;
      --ssh-public-key-file|--ssh-key-file)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: $1 requires a path." >&2
          print_usage
          return 1
        fi
        SSH_PUBLIC_KEY_FILE="$2"
        SSH_PUB_KEY=""
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
        echo "ERROR: Unknown option: $1" >&2
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
  CLUSTER_NAME="${4:-}"
  OVERRIDE_IP="${5:-}"
}

# Expand a leading "~/" to ${HOME} the way the shell would for an unquoted path.
# Other forms (e.g. "~user/") are returned unchanged.
expand_tilde() {
  local path="$1"
  # shellcheck disable=SC2088
  if [[ "$path" == "~/"* ]]; then
    printf '%s\n' "${HOME}/${path#"~/"}"
  else
    printf '%s\n' "$path"
  fi
}

# Print a found/missing summary for the pull secret and SSH public key. This is
# report-only: discovery is re-run at prompt time so a file uploaded after this
# summary is still picked up as the prompt default.
report_credential_presence() {
  echo "Checking for required credentials under ${HOME} ..." >&2

  if [[ -n "${PULL_SECRET_FILE:-}" ]]; then
    if [[ -f "$PULL_SECRET_FILE" ]]; then
      echo "  Pull secret:    found ${PULL_SECRET_FILE}" >&2
    else
      echo "  Pull secret:    NOT FOUND at ${PULL_SECRET_FILE}" >&2
    fi
  else
    local ps_saved="${_SAVED[PULL_SECRET_FILE]:-}"
    local -a ps_candidates
    if [[ -n "$ps_saved" && -f "$ps_saved" ]]; then
      echo "  Pull secret:    found ${ps_saved} (from saved config)" >&2
    else
      mapfile -t ps_candidates < <(find_pull_secret_candidates)
      if [[ "${#ps_candidates[@]}" -eq 1 ]]; then
        echo "  Pull secret:    found ${ps_candidates[0]}" >&2
      elif [[ "${#ps_candidates[@]}" -gt 1 ]]; then
        echo "  Pull secret:    ${#ps_candidates[@]} candidates found (you will choose one)" >&2
      else
        echo "  Pull secret:    NOT FOUND under ${HOME} — you will be prompted to enter a path" >&2
      fi
    fi
  fi

  if [[ -n "${SSH_PUB_KEY:-}" ]]; then
    echo "  SSH public key: provided directly" >&2
  elif [[ -n "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
    if [[ -f "$(expand_tilde "$SSH_PUBLIC_KEY_FILE")" ]]; then
      echo "  SSH public key: found ${SSH_PUBLIC_KEY_FILE}" >&2
    else
      echo "  SSH public key: NOT FOUND at ${SSH_PUBLIC_KEY_FILE}" >&2
    fi
  else
    local ssh_saved_key="${_SAVED[SSH_PUB_KEY]:-}"
    local ssh_saved_file="${_SAVED[SSH_PUBLIC_KEY_FILE]:-}"
    local -a ssh_candidates
    if [[ -n "$ssh_saved_key" ]]; then
      echo "  SSH public key: provided directly (from saved config)" >&2
    elif [[ -n "$ssh_saved_file" && -f "$(expand_tilde "$ssh_saved_file")" ]]; then
      echo "  SSH public key: found ${ssh_saved_file} (from saved config)" >&2
    else
      mapfile -t ssh_candidates < <(find_ssh_pub_candidates)
      if [[ "${#ssh_candidates[@]}" -eq 1 ]]; then
        echo "  SSH public key: found ${ssh_candidates[0]}" >&2
      elif [[ "${#ssh_candidates[@]}" -gt 1 ]]; then
        echo "  SSH public key: ${#ssh_candidates[@]} candidates found (you will choose one)" >&2
      else
        echo "  SSH public key: NOT FOUND under ${HOME} — you will be prompted to enter one" >&2
      fi
    fi
  fi
}

prompt_for_missing_config() {
  if [[ "$INTERACTIVE" != "1" ]]; then
    return 0
  fi

  if ! can_prompt; then
    die "--interactive requires a TTY; pass all required values explicitly in non-interactive shells."
    return 1
  fi

  load_saved_config

  report_credential_presence

  prompt_value OCP_VERSION "OpenShift version" "${OCP_VERSION:-${_SAVED[OCP_VERSION]:-}}"

  if [[ -z "${PULL_SECRET_FILE:-}" ]]; then
    local ps_default="${_SAVED[PULL_SECRET_FILE]:-}"
    # Drop a stale saved path so discovery can offer a real default instead.
    [[ -n "$ps_default" && ! -f "$ps_default" ]] && ps_default=""
    if [[ -z "$ps_default" ]]; then
      local -a ps_candidates
      mapfile -t ps_candidates < <(find_pull_secret_candidates)
      if [[ "${#ps_candidates[@]}" -eq 1 ]]; then
        ps_default="${ps_candidates[0]}"
      elif [[ "${#ps_candidates[@]}" -gt 1 ]]; then
        PULL_SECRET_FILE="$(prompt_file_choice "pull secret" "${ps_candidates[@]}")"
      else
        echo "WARNING: No pull-secret.* file found under ${HOME}. You can paste a path or re-run after copying your pull secret." >&2
      fi
    fi
    if [[ -z "${PULL_SECRET_FILE:-}" ]]; then
      prompt_value PULL_SECRET_FILE "Pull secret file" "$ps_default"
    fi
  fi
  prompt_value BASE_DOMAIN "Base domain" "${BASE_DOMAIN:-${_SAVED[BASE_DOMAIN]:-}}"
  prompt_value CLUSTER_NAME "Cluster name" "${CLUSTER_NAME:-${_SAVED[CLUSTER_NAME]:-sno}}"
  prompt_optional_value OVERRIDE_IP "Rendezvous IP" "${_SAVED[OVERRIDE_IP]:-}"
  prompt_optional_value NETWORK_INTERFACE_OVERRIDE "Network interface" "${_SAVED[NETWORK_INTERFACE_OVERRIDE]:-}"
  prompt_optional_value IP_WITH_PREFIX_OVERRIDE "IPv4 address with prefix" "${_SAVED[IP_WITH_PREFIX_OVERRIDE]:-}"
  prompt_optional_value GATEWAY_OVERRIDE "Gateway" "${_SAVED[GATEWAY_OVERRIDE]:-}"
  prompt_value HOSTNAME_OVERRIDE "Node hostname" "${HOSTNAME_OVERRIDE:-${_SAVED[HOSTNAME_OVERRIDE]:-}}"

  local saved_ssh_file="${_SAVED[SSH_PUBLIC_KEY_FILE]:-}"
  local saved_ssh_key="${_SAVED[SSH_PUB_KEY]:-}"
  if [[ -z "${SSH_PUBLIC_KEY_FILE:-}" && -z "${SSH_PUB_KEY:-}" ]]; then
    local ssh_default=""
    # Use a saved file path only when it still exists, so a stale path falls
    # back to discovery instead of being offered as a dead default.
    [[ -n "$saved_ssh_file" && -f "$(expand_tilde "$saved_ssh_file")" ]] && ssh_default="$saved_ssh_file"
    [[ -z "$ssh_default" && -n "$saved_ssh_key" ]] && ssh_default="$saved_ssh_key"

    if [[ -z "$ssh_default" ]]; then
      local -a ssh_candidates
      mapfile -t ssh_candidates < <(find_ssh_pub_candidates)
      if [[ "${#ssh_candidates[@]}" -eq 1 ]]; then
        ssh_default="${ssh_candidates[0]}"
      elif [[ "${#ssh_candidates[@]}" -gt 1 ]]; then
        SSH_PUBLIC_KEY_FILE="$(prompt_file_choice "SSH public key" "${ssh_candidates[@]}")"
      else
        echo "WARNING: No *.pub SSH key file found under ${HOME}." >&2
      fi
    fi

    if [[ -z "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
      local ssh_input
      if [[ -n "$ssh_default" ]]; then
        read -r -p "SSH public key file or key [${ssh_default}]: " ssh_input
        ssh_input="${ssh_input:-$ssh_default}"
      else
        read -r -p "SSH public key file or key: " ssh_input
      fi
      if [[ "$ssh_input" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-) ]]; then
        SSH_PUB_KEY="$ssh_input"
      elif [[ -n "$ssh_input" ]]; then
        SSH_PUBLIC_KEY_FILE="$ssh_input"
      else
        die "SSH public key is required. Provide a file path or paste the key."
      fi
    fi
  fi
  prompt_value ARTIFACT_DIR "Artifact directory" "$ARTIFACT_DIR"
  prompt_value BIN_DIR "Binary install directory" "$BIN_DIR"

  if [[ "${#DNS_SERVERS_OVERRIDE[@]}" -eq 0 ]]; then
    local saved_dns="${_SAVED[DNS_SERVERS_OVERRIDE]:-}"
    local dns_line
    if [[ -n "$saved_dns" ]]; then
      read -r -p "DNS servers, comma-separated [${saved_dns}]: " dns_line
      dns_line="${dns_line:-$saved_dns}"
    else
      read -r -p "DNS servers, comma-separated (leave blank to auto-detect): " dns_line
    fi
    if [[ -n "$dns_line" ]]; then
      IFS=',' read -r -a DNS_SERVERS_OVERRIDE <<< "$dns_line"
      local i
      for i in "${!DNS_SERVERS_OVERRIDE[@]}"; do
        DNS_SERVERS_OVERRIDE[i]="${DNS_SERVERS_OVERRIDE[i]//[[:space:]]/}"
      done
    fi
  fi

  save_config || echo "WARNING: could not save config to ${CONFIG_FILE}" >&2
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
  [[ -n "$OCP_VERSION" ]] || { die "Missing OpenShift version."; return 1; }
  [[ -n "$PULL_SECRET_FILE" ]] || { die "Missing pull secret file."; return 1; }
  [[ -n "$BASE_DOMAIN" ]] || { die "Missing base domain."; return 1; }
  [[ -n "$CLUSTER_NAME" ]] || { die "Missing cluster name."; return 1; }
  [[ -n "$HOSTNAME_OVERRIDE" ]] || { die "Missing node hostname. Use --hostname <name>."; return 1; }
  [[ -n "$ARTIFACT_DIR" ]] || { die "Missing artifact directory."; return 1; }
  [[ -n "$BIN_DIR" ]] || { die "Missing binary install directory."; return 1; }
  [[ -n "${SSH_PUBLIC_KEY_FILE:-}" || -n "${SSH_PUB_KEY:-}" ]] || { die "Missing SSH public key. Use --ssh-public-key-file <path> or set SSH_PUB_KEY."; return 1; }

  if [[ ! "$OCP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._-][0-9A-Za-z._-]+)?$ ]]; then
    die "Invalid OCP_VERSION format '${OCP_VERSION}'. Expected semver like 4.22.1 or 4.22.1-rc.1."
    return 1
  fi
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

# Enforce --ip-family consistency against the explicitly supplied address flags.
# Auto-detected addresses are not treated as a conflict; only explicit flags are.
validate_ip_family() {
  local family="${IP_FAMILY_OVERRIDE:-}"
  [[ -z "$family" ]] && return 0

  local has_v4=0 has_v6=0
  [[ -n "${IP_WITH_PREFIX_OVERRIDE:-}" ]] && has_v4=1
  [[ -n "${IPV6_WITH_PREFIX_OVERRIDE:-}" ]] && has_v6=1

  case "$family" in
    v4)
      if [[ "$has_v6" -eq 1 ]]; then
        die "--ip-family v4 conflicts with --ipv6-with-prefix."
        return 1
      fi
      ;;
    v6)
      if [[ "$has_v4" -eq 1 ]]; then
        die "--ip-family v6 conflicts with --ip-with-prefix."
        return 1
      fi
      ;;
    dual)
      if [[ "$has_v4" -eq 1 && "$has_v6" -eq 0 ]]; then
        die "--ip-family dual requires --ipv6-with-prefix (or IPv6 autodiscovery) in addition to the IPv4 address."
        return 1
      fi
      if [[ "$has_v6" -eq 1 && "$has_v4" -eq 0 ]]; then
        die "--ip-family dual requires --ip-with-prefix in addition to the IPv6 address."
        return 1
      fi
      ;;
  esac
}

validate_ip_values() {
  local dns_raw
  dns_raw="$(printf '%s\n' "${DNS_SERVERS[@]:-}")"
  IP_WITH_PREFIX="${IP_WITH_PREFIX:-}" GATEWAY="${GATEWAY:-}" \
  IPV6_WITH_PREFIX="${IPV6_WITH_PREFIX:-}" IPV6_GATEWAY="${IPV6_GATEWAY:-}" \
  DNS_SERVERS_RAW="$dns_raw" python3 - <<'PY'
import ipaddress
import os
import sys

def check_pair(addr_with_prefix, gateway, want_v6):
    if not addr_with_prefix:
        return
    iface = ipaddress.ip_interface(addr_with_prefix)
    gw = ipaddress.ip_address(gateway)
    is_v6 = iface.version == 6
    if is_v6 != want_v6:
        raise ValueError(f"address {addr_with_prefix} is not the expected family")
    # A link-local IPv6 gateway (fe80::/10) is valid; only require family match.
    if gw.version != iface.version:
        raise ValueError(f"gateway {gateway} family does not match {addr_with_prefix}")

try:
    check_pair(os.environ["IP_WITH_PREFIX"], os.environ["GATEWAY"], want_v6=False)
    check_pair(os.environ["IPV6_WITH_PREFIX"], os.environ["IPV6_GATEWAY"], want_v6=True)
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
    if ! read -r -p "Select install disk [1-${#candidate_disks[@]}]: " selection; then
      die "Input closed while selecting install disk."
      return 1
    fi
    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#candidate_disks[@]} )); then
      printf '%s\n' "${candidate_disks[$((selection - 1))]}"
      return 0
    fi
    echo "ERROR: Invalid selection '${selection}'. Enter a number from 1 to ${#candidate_disks[@]}." >&2
  done
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
    return $?
  fi

  echo "ERROR: Multiple candidate install disks detected:" >&2
  format_disk_candidate_table "${candidate_disks[@]}" >&2
  echo "Use --disk-device <path> to choose one explicitly." >&2
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
  local need_install=0
  local rust_ver

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  DRY-RUN: would ensure Rust/Cargo is available via rustup."
    return 0
  fi

  if [[ -r "$cargo_env" ]]; then
    # shellcheck source=/dev/null
    source "$cargo_env"
  fi
  export PATH="${HOME}/.cargo/bin:${PATH}"

  if ! command -v rustc >/dev/null 2>&1; then
    need_install=1
  else
    rust_ver="$(rustc --version | awk '{print $2}')"
    local major minor
    major="${rust_ver%%.*}"
    minor="${rust_ver#*.}"; minor="${minor%%.*}"
    if [[ "$major" -lt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -lt 85 ]]; }; then
      echo "  Rust ${rust_ver} is too old (need >= 1.85 for edition 2024); upgrading via rustup..."
      need_install=1
    fi
  fi

  if [[ "$need_install" -eq 1 ]]; then
    echo "  Installing Rust/Cargo via rustup..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    # shellcheck source=/dev/null
    source "$cargo_env"
    export PATH="${HOME}/.cargo/bin:${PATH}"
  fi

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
  PARTIAL_DOWNLOAD="$archive_path"
  curl_retry -o "$archive_path" "${OCP_MIRROR}/${archive_name}"
  PARTIAL_DOWNLOAD=""
  verify_download_checksum "$archive_path" "$checksum_file"
  tar -xzf "$archive_path" -C "$WORKDIR" "$binary_name"
  mkdir -p "$BIN_DIR"
  install -m 0755 "${WORKDIR}/${binary_name}" "${BIN_DIR}/${binary_name}"
  rm -f "$archive_path" "${WORKDIR:?}/${binary_name}"
}

# Print only the DNS servers whose address family matches the configured IP.
# The generated agent-config enables a single (IPv4) family on the interface,
# and nmstate rejects a DNS server that has no IP-enabled interface of its
# family ("Failed to find suitable(IP enabled) interface for DNS server").
# An address containing ":" is treated as IPv6.
filter_dns_by_family() {
  local primary_ip="$1"
  shift
  local want_v6=0
  [[ "$primary_ip" == *:* ]] && want_v6=1
  local server is_v6
  for server in "$@"; do
    is_v6=0
    [[ "$server" == *:* ]] && is_v6=1
    [[ "$is_v6" -eq "$want_v6" ]] && printf '%s\n' "$server"
  done
}

# Given an IPv6 network CIDR, propose the first usable host address (network+1)
# with the same prefix length, e.g. 2a01:db8::/64 -> 2a01:db8::1/64. A stable,
# deterministic choice rather than the rotating SLAAC/temporary address.
propose_ipv6_host() {
  local network_cidr="$1"
  NETF_NET="$network_cidr" python3 - <<'PY'
import ipaddress
import os

net = ipaddress.ip_network(os.environ["NETF_NET"], strict=False)
print(f"{net.network_address + 1}/{net.prefixlen}")
PY
}

# Discover an IPv6 host address and gateway for DEFAULT_IFACE. Explicit
# --ipv6-with-prefix / --ipv6-gateway always win. Otherwise: take the first
# on-link global /64 from the route table (skipping fe80:: link-local) and
# propose <prefix>::1; take the default-route next-hop as the gateway.
discover_ipv6() {
  IPV6_WITH_PREFIX="${IPV6_WITH_PREFIX_OVERRIDE:-}"
  IPV6_GATEWAY="${IPV6_GATEWAY_OVERRIDE:-}"

  if [[ -z "$IPV6_WITH_PREFIX" ]]; then
    local prefix_cidr
    prefix_cidr="$(ip -6 route show dev "$DEFAULT_IFACE" 2>/dev/null \
      | awk '$1 ~ /\/64$/ && $1 !~ /^fe80:/ {print $1; exit}')"
    if [[ -z "$prefix_cidr" ]]; then
      prefix_cidr="$(ip -6 addr show dev "$DEFAULT_IFACE" scope global 2>/dev/null \
        | awk '/inet6 / {print $2; exit}')"
    fi
    [[ -n "$prefix_cidr" ]] || { die "Could not determine an IPv6 prefix on ${DEFAULT_IFACE}. Use --ipv6-with-prefix."; return 1; }
    IPV6_WITH_PREFIX="$(propose_ipv6_host "$prefix_cidr")"
  fi

  if [[ -z "$IPV6_GATEWAY" ]]; then
    IPV6_GATEWAY="$(ip -6 route show default 2>/dev/null \
      | awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')"
    # Hetzner's IPv6 gateway is the link-local fe80::1 when no explicit next-hop
    # is published but a default route exists.
    if [[ -z "$IPV6_GATEWAY" ]] && ip -6 route show default 2>/dev/null | grep -q default; then
      IPV6_GATEWAY="fe80::1"
    fi
    [[ -n "$IPV6_GATEWAY" ]] || { die "Could not determine the IPv6 gateway on ${DEFAULT_IFACE}. Use --ipv6-gateway."; return 1; }
  fi
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
  NODE_HOSTNAME="$HOSTNAME_OVERRIDE"

  if [[ "${#DNS_SERVERS_OVERRIDE[@]}" -gt 0 ]]; then
    DNS_SERVERS=("${DNS_SERVERS_OVERRIDE[@]}")
  else
    if command -v resolvectl >/dev/null 2>&1; then
      mapfile -t DNS_SERVERS < <(resolvectl dns 2>/dev/null \
        | awk '{for(i=2;i<=NF;i++) print $i}' \
        | grep -vE '^(127\.|::1$)' | head -3)
    fi
    if [[ "${#DNS_SERVERS[@]}" -eq 0 ]]; then
      mapfile -t DNS_SERVERS < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf \
        | grep -vE '^(127\.|::1$)' | head -3)
    fi
    if [[ "${#DNS_SERVERS[@]}" -eq 0 ]]; then
      DNS_SERVERS=("8.8.8.8" "8.8.4.4")
    fi
  fi

  # The interface is configured IPv4-only, so drop DNS servers of another
  # family; nmstate would otherwise fail to find a matching IP-enabled interface.
  local -a dns_in_family
  mapfile -t dns_in_family < <(filter_dns_by_family "$IP_ADDR" "${DNS_SERVERS[@]}")
  if [[ "${#dns_in_family[@]}" -ne "${#DNS_SERVERS[@]}" ]]; then
    local -a dns_dropped
    mapfile -t dns_dropped < <(comm -23 \
      <(printf '%s\n' "${DNS_SERVERS[@]}" | sort) \
      <(printf '%s\n' "${dns_in_family[@]}" | sort))
    echo "WARNING: Ignoring DNS server(s) that do not match the ${IP_ADDR} address family: ${dns_dropped[*]}" >&2
  fi
  DNS_SERVERS=("${dns_in_family[@]}")
  if [[ "${#DNS_SERVERS[@]}" -eq 0 ]]; then
    # Match the fallback resolvers to the configured IP family so filtering is
    # not immediately undone by a mismatched default.
    if [[ "$IP_ADDR" == *:* ]]; then
      DNS_SERVERS=("2001:4860:4860::8888" "2001:4860:4860::8844")
    else
      DNS_SERVERS=("8.8.8.8" "8.8.4.4")
    fi
  fi

  validate_ip_values
  DNS_SERVERS_RAW="$(printf '%s\n' "${DNS_SERVERS[@]}")"
  DNS_DISPLAY="$(printf '%s ' "${DNS_SERVERS[@]}")"
}

resolve_ssh_public_key() {
  if [[ -n "${SSH_PUB_KEY:-}" ]]; then
    :
  elif [[ -n "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
    SSH_PUBLIC_KEY_FILE="$(expand_tilde "$SSH_PUBLIC_KEY_FILE")"
    if [[ ! -f "$SSH_PUBLIC_KEY_FILE" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        SSH_PUB_KEY="DRY-RUN-SSH-PUBLIC-KEY"
        echo "  DRY-RUN: would read SSH public key from ${SSH_PUBLIC_KEY_FILE}."
        return 0
      fi
      die "SSH public key file not found: ${SSH_PUBLIC_KEY_FILE}"
      return 1
    fi
    SSH_PUB_KEY="$(cat "$SSH_PUBLIC_KEY_FILE")"
  else
    die "Missing SSH public key. Use --ssh-public-key-file <path> or set SSH_PUB_KEY."
    return 1
  fi

  SSH_PUB_KEY="${SSH_PUB_KEY#"${SSH_PUB_KEY%%[![:space:]]*}"}"
  SSH_PUB_KEY="${SSH_PUB_KEY%"${SSH_PUB_KEY##*[![:space:]]}"}"

  if [[ "$SSH_PUB_KEY" == *$'\n'* || "$SSH_PUB_KEY" == *$'\r'* ]]; then
    die "SSH public key must contain exactly one non-empty line."
    return 1
  fi

  if [[ ! "$SSH_PUB_KEY" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-) ]]; then
    die "SSH public key does not look valid. Expected ssh-rsa, ssh-ed25519, or ecdsa-sha2-* prefix."
    return 1
  fi
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

  chmod 600 "${INSTALL_DIR}/install-config.yaml"
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

print_cluster_credentials() {
  local kubeadmin_password_file="${INSTALL_DIR}/auth/kubeadmin-password"
  local kubeconfig_file="${INSTALL_DIR}/auth/kubeconfig"

  if [[ -f "$kubeadmin_password_file" ]]; then
    echo ""
    echo "  kubeadmin password: $(<"${kubeadmin_password_file}")"
    echo ""
  else
    echo "  WARNING: ${kubeadmin_password_file} not found"
  fi

  if [[ -f "$kubeconfig_file" ]]; then
    echo "  IMPORTANT: Save the content of ${kubeconfig_file} before rebooting."
    echo "  It will be lost after the kexec reboot into the agent installer."
    echo ""
    echo "--- kubeconfig start ---"
    cat "${kubeconfig_file}"
    echo "--- kubeconfig end ---"
    echo ""
  else
    echo "  WARNING: ${kubeconfig_file} not found"
  fi
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
  echo "  SSH public key:    ${SSH_PUBLIC_KEY_FILE:-(provided directly)}"
  echo "  Work directory:    ${WORKDIR}"
  echo "  Artifact dir:      ${ARTIFACT_DIR}"
  echo "  Binary dir:        ${BIN_DIR}"
}

print_replay_command() {
  local dns_server
  local env_prefix=""
  local -a lines=()
  local last_line

  if [[ -n "${SSH_PUB_KEY:-}" && -z "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
    env_prefix="SSH_PUB_KEY=$(printf '%q' "$SSH_PUB_KEY") "
  fi

  lines+=("./${SCRIPT_NAME} --yes \\")
  lines+=("  --hostname $(printf '%q' "$NODE_HOSTNAME") \\")

  if [[ -n "${SSH_PUBLIC_KEY_FILE:-}" ]]; then
    lines+=("  --ssh-public-key-file $(printf '%q' "$SSH_PUBLIC_KEY_FILE") \\")
  fi

  lines+=("  --network-interface $(printf '%q' "$DEFAULT_IFACE") \\")
  lines+=("  --ip-with-prefix $(printf '%q' "$IP_WITH_PREFIX") \\")
  lines+=("  --gateway $(printf '%q' "$GATEWAY") \\")

  for dns_server in "${DNS_SERVERS[@]}"; do
    lines+=("  --dns-server $(printf '%q' "$dns_server") \\")
  done

  lines+=("  --disk-device $(printf '%q' "$INSTALL_DISK") \\")

  if [[ "$ARTIFACT_DIR" != "/root" ]]; then
    lines+=("  --artifact-dir $(printf '%q' "$ARTIFACT_DIR") \\")
  fi

  if [[ "$BIN_DIR" != "/usr/local/bin" ]]; then
    lines+=("  --bin-dir $(printf '%q' "$BIN_DIR") \\")
  fi

  last_line="  $(printf '%q' "$OCP_VERSION") $(printf '%q' "$PULL_SECRET_FILE") $(printf '%q' "$BASE_DOMAIN") $(printf '%q' "$CLUSTER_NAME") $(printf '%q' "$RENDEZVOUS_IP")"
  lines+=("$last_line")

  echo ""
  echo "To replay this configuration without interactive prompts:"
  echo ""
  if [[ -n "$env_prefix" ]]; then
    printf '  %s' "$env_prefix"
  else
    printf '  '
  fi
  printf '%s\n' "${lines[0]}"
  local i
  for ((i = 1; i < ${#lines[@]}; i++)); do
    printf '%s\n' "${lines[i]}"
  done
  echo ""
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
  require_commands python3 awk head lsblk findmnt ip
  export PATH="${BIN_DIR}:${PATH}"
  validate_pull_secret
  resolve_ssh_public_key
  resolve_network_config
  INSTALL_DISK="$(resolve_install_disk)"
  print_resolved_config
  save_config || echo "WARNING: could not save config to ${CONFIG_FILE}" >&2

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: would install dependencies, download OpenShift tools, generate configs, create PXE files, and copy artifacts."
    return 0
  fi

  require_root
  require_commands curl tar install sha256sum
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
  chmod 600 "${WORKDIR}/install-config.yaml.bak" "${WORKDIR}/agent-config.yaml.bak"
  openshift-install agent create pxe-files --dir "${INSTALL_DIR}" --log-level info

  log_step "Step 6: Copying boot artifacts to ${ARTIFACT_DIR}"
  boot_artifacts_dir="${INSTALL_DIR}/boot-artifacts"
  validate_boot_artifacts "$boot_artifacts_dir"
  mkdir -p "$ARTIFACT_DIR"
  cp "${boot_artifacts_dir}/agent.x86_64-"* "$ARTIFACT_DIR/"
  echo "  Copied files to ${ARTIFACT_DIR}:"
  ls -lh "${ARTIFACT_DIR}/agent.x86_64-"*

  log_step "Step 7: Cluster credentials"
  print_cluster_credentials

  print_replay_command

  echo ""
  log_step "Done"
  echo "Boot artifacts are in ${ARTIFACT_DIR}. You can now run:"
  echo "  ./hetzner-sno-provision-host-agentbased.sh --artifact-dir ${ARTIFACT_DIR}"
  echo "to kexec into the agent installer."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
