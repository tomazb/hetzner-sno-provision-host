#!/bin/bash

# Boot a Hetzner rescue host into agent-based installer PXE artifacts via kexec.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
KERNEL_CMDLINE="rw ignition.firstboot ignition.platform.id=metal"

die() {
  echo "ERROR: $*" >&2
  return 1
}

can_prompt() {
  [[ "${HSPAGENT_ALLOW_NON_TTY_INTERACTIVE:-0}" == "1" ]] && return 0
  [[ -t 0 && -t 1 && -z "${CI:-}" ]]
}

print_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  --artifact-dir <dir>  Directory containing agent.x86_64-* boot artifacts (default: /root)
  --dry-run             Validate and print planned actions without installs, writes, or kexec
  --interactive         Prompt for artifact directory on a TTY
  --yes                 Skip confirmation prompts
  -h, --help            Show this help

Example:
  ${SCRIPT_NAME} --yes --artifact-dir /root
EOF
}

parse_args() {
  DRY_RUN=0
  INTERACTIVE=0
  YES=0
  ARTIFACT_DIR="${ARTIFACT_DIR:-/root}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --artifact-dir)
        [[ $# -ge 2 ]] || { die "--artifact-dir requires a directory path."; print_usage; return 1; }
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
        die "Unknown option: $1"
        print_usage
        return 1
        ;;
      *)
        print_usage
        return 1
        ;;
    esac
  done
}

prompt_for_missing_config() {
  local value

  if [[ "$INTERACTIVE" != "1" ]]; then
    return 0
  fi

  if ! can_prompt; then
    die "--interactive requires a TTY; pass --artifact-dir explicitly in non-interactive shells."
    return 1
  fi

  read -r -p "Artifact directory [${ARTIFACT_DIR}]: " value
  ARTIFACT_DIR="${value:-$ARTIFACT_DIR}"
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

artifact_path() {
  printf '%s/%s\n' "$ARTIFACT_DIR" "$1"
}

validate_agent_artifacts() {
  local artifact

  [[ -d "$ARTIFACT_DIR" ]] || die "Artifact directory not found: ${ARTIFACT_DIR}"
  for artifact in agent.x86_64-vmlinuz agent.x86_64-initrd.img agent.x86_64-rootfs.img; do
    [[ -s "$(artifact_path "$artifact")" ]] || die "Missing required artifact: $(artifact_path "$artifact")"
  done
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
  echo "  Artifact dir:    ${ARTIFACT_DIR}"
  echo "  Kernel:          $(artifact_path agent.x86_64-vmlinuz)"
  echo "  Initrd:          $(artifact_path agent.x86_64-initrd.img)"
  echo "  Rootfs:          $(artifact_path agent.x86_64-rootfs.img)"
  echo "  Combined initrd: $(artifact_path agent.x86_64-combinedinitrd.img)"
  echo "  Kernel args:     ${KERNEL_CMDLINE}"
}

main() {
  local parse_status
  local combined_initrd

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
  require_arch
  warn_if_not_debian_12
  validate_agent_artifacts
  print_resolved_config

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: would install kexec-tools, concatenate initrds, and kexec the agent installer."
    return 0
  fi

  require_root
  require_commands apt-get debconf-set-selections cat
  confirm_or_die "package installation and kexec"

  echo "This script is meant to be run in the rescue environment to provision the Hetzner node, where the PXE files from agent-based installation should have been copied already."
  install_kexec_tools
  require_commands kexec
  combined_initrd="$(artifact_path agent.x86_64-combinedinitrd.img)"
  cat "$(artifact_path agent.x86_64-initrd.img)" "$(artifact_path agent.x86_64-rootfs.img)" > "$combined_initrd"
  kexec "$(artifact_path agent.x86_64-vmlinuz)" --initrd="$combined_initrd" --command-line="$KERNEL_CMDLINE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
