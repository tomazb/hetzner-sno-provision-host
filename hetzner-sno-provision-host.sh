#!/bin/bash

# Boot a Hetzner rescue host into the assisted-installer discovery kernel via kexec.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
CLEANUP_FILES=()

cleanup() {
  local file
  for file in "${CLEANUP_FILES[@]}"; do
    rm -f "$file"
  done
  exit 1
}
trap cleanup INT TERM

die() {
  echo "ERROR: $*" >&2
  return 1
}

can_prompt() {
  [[ "${HSPHOST_ALLOW_NON_TTY_INTERACTIVE:-0}" == "1" ]] && return 0
  [[ -t 0 && -t 1 && -z "${CI:-}" ]]
}

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options] <iPXE script URL>

Options:
  --artifact-dir <dir>  Directory for iPXE, kernel, and initrd downloads (default: /root)
  --dry-run             Validate and print planned actions without downloads, installs, or kexec
  --interactive         Prompt for missing iPXE URL on a TTY
  --yes                 Skip confirmation prompts
  -h, --help            Show this help

Example:
  ${SCRIPT_NAME} --yes https://api.openshift.com/api/assisted-images/bytoken/.../ipxe-script
EOF
}

parse_args() {
  DRY_RUN=0
  INTERACTIVE=0
  YES=0
  ARTIFACT_DIR="${ARTIFACT_DIR:-/root}"
  IPXE_SCRIPT_URL=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --artifact-dir)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --artifact-dir requires a directory path." >&2
          print_usage
          return 1
        fi
        ARTIFACT_DIR="$2"
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

  if [[ $# -gt 1 ]] || [[ $# -lt 1 && "$INTERACTIVE" != "1" ]]; then
    print_usage
    return 1
  fi

  IPXE_SCRIPT_URL="${1:-}"
}

prompt_for_missing_config() {
  if [[ "$INTERACTIVE" != "1" ]]; then
    return 0
  fi

  if ! can_prompt; then
    die "--interactive requires a TTY; pass the iPXE URL explicitly in non-interactive shells."
    return 1
  fi

  if [[ -z "$IPXE_SCRIPT_URL" ]]; then
    read -r -p "iPXE script URL: " IPXE_SCRIPT_URL
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

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "This script must run as root in the Hetzner rescue environment. Use --dry-run for workstation validation."
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

confirm_or_die() {
  local prompt="$1"
  local answer

  if [[ "$DRY_RUN" == "1" || "$YES" == "1" ]]; then
    return 0
  fi

  if ! can_prompt; then
    die "Confirmation required before ${prompt}; rerun with --yes for automation."
    return 1
  fi

  read -r -p "Proceed with ${prompt}? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]] || die "Declined confirmation for ${prompt}."
}

validate_ipxe_url() {
  [[ -n "$IPXE_SCRIPT_URL" ]] || die "Missing iPXE script URL."
}

parse_ipxe_script() {
  local ipxe_file="$1"

  [[ -s "$ipxe_file" ]] || die "iPXE script is empty or missing: ${ipxe_file}"
  INITRD_URL="$(awk '$1 == "initrd" {print $NF; exit}' "$ipxe_file")"
  KERNEL_URL="$(awk '$1 == "kernel" {print $2; exit}' "$ipxe_file")"
  KERNEL_CMDLINE="$(awk '$1 == "kernel" {$1=""; $2=""; sub(/^  */, ""); print; exit}' "$ipxe_file")"

  [[ -n "$INITRD_URL" ]] || die "Could not find initrd URL in iPXE script."
  [[ -n "$KERNEL_URL" ]] || die "Could not find kernel URL in iPXE script."
  [[ -n "$KERNEL_CMDLINE" ]] || die "Could not find kernel command line in iPXE script."
}

install_kexec_tools() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: would install kexec-tools."
    return 0
  fi

  echo kexec-tools kexec-tools/use_grub_config select false | debconf-set-selections
  echo kexec-tools kexec-tools/load_kexec select true | debconf-set-selections
  apt-get update -y || true
  apt-get install -y kexec-tools
}

print_resolved_config() {
  echo "Resolved configuration:"
  echo "  iPXE URL:      ${IPXE_SCRIPT_URL}"
  echo "  Artifact dir:  ${ARTIFACT_DIR}"
  if [[ -n "${KERNEL_URL:-}" ]]; then
    echo "  Kernel URL:    ${KERNEL_URL}"
    echo "  Initrd URL:    ${INITRD_URL}"
    echo "  Kernel args:   ${KERNEL_CMDLINE}"
  fi
}

main() {
  local parse_status
  local ipxe_file
  local kernel_path
  local initrd_path

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
  validate_ipxe_url
  require_arch
  warn_if_not_debian_12
  print_resolved_config

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: would download the iPXE script, validate it, download kernel/initrd, install kexec-tools, and kexec."
    return 0
  fi

  require_root
  require_commands curl awk apt-get debconf-set-selections
  confirm_or_die "package installation and kexec"

  mkdir -p "$ARTIFACT_DIR"
  ipxe_file="${ARTIFACT_DIR}/discovery_ipxe_script.txt"
  kernel_path="${ARTIFACT_DIR}/kernel"
  initrd_path="${ARTIFACT_DIR}/initrd"
  CLEANUP_FILES+=("$ipxe_file" "$kernel_path" "$initrd_path")

  echo "This script is meant to be run in the rescue environment to provision the Hetzner node so it can be discovered by assisted installer."
  curl_retry -o "$ipxe_file" "$IPXE_SCRIPT_URL"
  parse_ipxe_script "$ipxe_file"
  print_resolved_config

  install_kexec_tools
  require_commands kexec
  curl_retry -o "$kernel_path" "$KERNEL_URL"
  curl_retry -o "$initrd_path" "$INITRD_URL"
  [[ -s "$kernel_path" ]] || die "Downloaded kernel is empty: ${kernel_path}"
  [[ -s "$initrd_path" ]] || die "Downloaded initrd is empty: ${initrd_path}"

  kexec "$kernel_path" --initrd="$initrd_path" --append="$KERNEL_CMDLINE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
