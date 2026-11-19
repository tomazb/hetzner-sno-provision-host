#!/bin/bash
# Run as root in a disposable debian:13-slim container with the repo at /work.
set -euo pipefail

export HSPPXE_ALLOW_NON_TTY_INTERACTIVE=1
export SNO_CONFIG_FILE=/root/preflight-probe.conf
export WORKDIR=/root/preflight-probe-work
export CARGO_BUILD_JOBS=2

for tool in curl python3 ip cc; do
  if command -v "$tool"; then
    echo "The probe requires a container without $tool." >&2
    exit 1
  fi
done

status=0
output="$(bash /work/hetzner-sno-prepare-pxe.sh --interactive --yes --dry-run </dev/null 2>&1)" || status=$?
printf '%s\n' "$output"
[[ "$status" == 1 && "$output" == *"Missing required host prerequisites:"* ]]
[[ "$output" != *"Installing host packages:"* ]]

status=0
output="$(bash /work/hetzner-sno-prepare-pxe.sh --interactive --yes </dev/null 2>&1)" || status=$?
printf '%s\n' "$output"
# EOF at the first configuration question intentionally stops the run.
[[ "$status" == 1 && "$output" == *"Installing host packages:"*"OpenShift version:"* ]]
dpkg-query -W python3 iproute2 curl ca-certificates gcc libc6-dev
curl --version
[[ ! -e "$SNO_CONFIG_FILE" && ! -e "$WORKDIR" ]]

status=0
output="$(bash /work/hetzner-sno-prepare-pxe.sh --interactive --yes \
  --network-interface sno-missing0 </dev/null 2>&1)" || status=$?
printf '%s\n' "$output"
[[ "$status" == 1 && "$output" == *"Network interface 'sno-missing0' could not be resolved"* ]]
[[ "$output" != *"OpenShift version:"* && "$output" != *"Installing host packages:"* ]]
echo 'PASS: host prerequisites install before the first question'

# Exercise the actual build helpers without creating OpenShift artifacts.
# shellcheck source=/dev/null
source /work/hetzner-sno-prepare-pxe.sh
export DRY_RUN=0
ensure_cargo_available
rustc --version
ensure_nmstatectl
matching_nmstatectl_version
echo 'PASS: the installed package set builds pinned nmstatectl'
