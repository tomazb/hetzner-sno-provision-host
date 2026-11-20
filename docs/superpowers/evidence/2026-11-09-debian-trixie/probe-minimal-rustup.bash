#!/bin/bash
# Run inside a disposable Debian 13 container with /probe/prepare.sh read-only.
set -euo pipefail
[[ -r /probe/prepare.sh ]] || { echo 'Run only inside the documented disposable container.' >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive CARGO_BUILD_JOBS=2 HSPPXE_TEST_MODE=1
cat /etc/os-release
apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=30 update
apt-get install -y --no-install-recommends curl ca-certificates
source /probe/prepare.sh
DRY_RUN=0
ensure_cargo_available
rustc --version
cargo --version
printf 'Attempt without compiler prerequisites:\n'
set +e
bash -c 'source /probe/prepare.sh; DRY_RUN=0; export PATH="/root/.cargo/bin:$PATH"; ensure_nmstatectl'
compiler_free_status=$?
set -e
printf 'COMPILER_FREE_STATUS=%s\n' "$compiler_free_status"
if [[ "$compiler_free_status" -eq 0 ]]; then
  printf 'Unexpected success without compiler packages; inspect image before interpreting result.\n'
  exit 1
fi
printf 'Retry after adding gcc and libc6-dev only:\n'
apt-get install -y --no-install-recommends gcc libc6-dev
dpkg-query -W gcc libc6-dev
ensure_nmstatectl
nmstatectl --version
printf 'Offline representative networkConfig fixture:\n'
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
cat > "$fixture_dir/network.yaml" <<'YAML'
interfaces:
  - name: eth0
    type: ethernet
    state: up
    mac-address: '00:00:5e:00:53:01'
    ipv4:
      enabled: true
      dhcp: false
      address:
        - ip: 192.0.2.10
          prefix-length: 24
    ipv6:
      enabled: false
dns-resolver:
  config:
    server:
      - 192.0.2.53
routes:
  config:
    - destination: 0.0.0.0/0
      next-hop-address: 192.0.2.1
      next-hop-interface: eth0
      table-id: 254
YAML
cat "$fixture_dir/network.yaml"
nmstatectl gc "$fixture_dir/network.yaml"
nmstatectl validate "$fixture_dir/network.yaml"
du -sh /root/.cargo /root/.rustup
df -h / /tmp
df -i / /tmp
printf 'MINIMAL_PROBE_SUCCESS\n'
