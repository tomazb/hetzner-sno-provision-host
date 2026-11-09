#!/bin/bash

set -euo pipefail

case "$#:${1-all}" in
  0:all|1:all) VERSIONS=(12 13) ;;
  1:12) VERSIONS=(12) ;;
  1:13) VERSIONS=(13) ;;
  *) echo "Usage: $0 [12|13|all]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MOUNT_SPEC="${REPO_ROOT}:/work"

if command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
  MOUNT_SPEC="${MOUNT_SPEC}:Z"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
else
  echo "ERROR: podman or docker is required to run the Debian container tests." >&2
  exit 1
fi

status=0
for version in "${VERSIONS[@]}"; do
  echo "Running userspace regression checks in debian:${version}-slim"
  # apt needs container root and the normal capabilities for its _apt user.
  # Rootless containers.conf may otherwise select the invoking host user.
  if "$ENGINE" run --rm --user 0 \
    -v "$MOUNT_SPEC" -w /work "docker.io/library/debian:${version}-slim" \
    bash -lc '
      set -euo pipefail
      apt-get update
      apt-get install -y --no-install-recommends bash ca-certificates curl iproute2 python3 shellcheck util-linux
      bash -n *.sh tests/*.sh scripts/*.sh
      shellcheck *.sh tests/*.sh scripts/*.sh
      ./tests/test-debian-container-runner.sh
      ./tests/test-prepare-dependencies.sh
      ./tests/test-hetzner-sno-prepare-pxe.sh
      ./tests/test-hetzner-sno-hardening.sh
    '; then
    echo "PASS: debian:${version}-slim"
  else
    echo "FAIL: debian:${version}-slim" >&2
    status=1
  fi
done
exit "$status"
