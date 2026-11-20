#!/bin/bash
# Run in a disposable Debian 12 container with /probe/prepare.sh read-only.
set -euo pipefail
[[ -r /probe/prepare.sh ]] || { echo 'Run only inside the documented disposable container.' >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive CARGO_BUILD_JOBS=2 HSPPXE_TEST_MODE=1
cat /etc/os-release
apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=30 update
apt-get install -y --no-install-recommends curl ca-certificates gcc libc6-dev
source /probe/prepare.sh
DRY_RUN=0
ensure_cargo_available
rustup toolchain install 1.88.0 --profile minimal
export RUSTUP_TOOLCHAIN=1.88.0
ensure_cargo_available
rustc --version
cargo --version
ensure_nmstatectl
nmstatectl --version
dpkg-query -W gcc libc6-dev
printf 'BOOKWORM_RUST_FLOOR_SUCCESS\n'
