#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENGINE=""

if command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
else
  echo "ERROR: podman or docker is required to run the Debian 12 container tests." >&2
  exit 1
fi

"$ENGINE" run --rm \
  -v "${REPO_ROOT}:/work:Z" \
  -w /work \
  debian:12-slim \
  bash -lc '
    set -euo pipefail
    apt-get update
    apt-get install -y --no-install-recommends bash ca-certificates curl iproute2 python3 shellcheck util-linux
    bash -n *.sh tests/*.sh scripts/*.sh
    shellcheck *.sh tests/*.sh scripts/*.sh
    ./tests/test-hetzner-sno-prepare-pxe.sh
    ./tests/test-hetzner-sno-hardening.sh
  '
