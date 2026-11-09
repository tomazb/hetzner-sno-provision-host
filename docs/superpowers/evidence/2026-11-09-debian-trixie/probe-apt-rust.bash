#!/bin/bash
# Run inside a disposable Debian 13 container with /probe/prepare.sh read-only.
set -euo pipefail
[[ -r /probe/prepare.sh ]] || { echo 'Run only inside the documented disposable container.' >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive CARGO_BUILD_JOBS=2
cat /etc/os-release
apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=30 update
apt-get install -y --no-install-recommends rustc cargo gcc libc6-dev curl ca-certificates
dpkg-query -W rustc cargo gcc libc6-dev
command -v rustc cargo
rustc --version
cargo --version
export HSPPXE_TEST_MODE=1
source /probe/prepare.sh
DRY_RUN=0
ensure_cargo_available
printf 'Toolchain selected by current helper:\n'
rustc --version
cargo --version
ensure_nmstatectl
nmstatectl --version
