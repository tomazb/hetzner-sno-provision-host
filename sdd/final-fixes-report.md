# Final Review Fixes Report

## Fix 1 — Misleading dual error message (Important)

**File:** `hetzner-sno-prepare-pxe.sh`, `validate_ip_family`

Removed "(or IPv6 autodiscovery)" from the `dual` branch error message. The message now reads:

    --ip-family dual requires --ipv6-with-prefix in addition to the IPv4 address.

No logic changes were made.

## Fix 2 — Byte-stability regression test

**Approach used:** git-show diff (not golden-string).

`git show 9c53635:hetzner-sno-prepare-pxe.sh` into a temp file, then ran the old generator's `generate_install_config` and `generate_agent_config` using its original variable contract (`IP_ADDR`, `PREFIX_LEN`, `GATEWAY`, `MACHINE_NETWORK` for install-config; `IP_ADDR`, `PREFIX_LEN`, `GATEWAY`, `DNS_SERVERS_RAW`, `NODE_HOSTNAME`, `MAC_ADDR`, `INSTALL_DISK`, `DEFAULT_IFACE`, `RENDEZVOUS_IP` for agent-config). Ran the new generator with `NET_FAMILIES_JSON`, `ACTIVE_V4=1`, `ACTIVE_V6=0`, empty `CLUSTER_NETWORKS`/`SERVICE_NETWORKS`, and `INSTALL_DISK_SERIAL=""` (so both fall back to `deviceName`). Verified `diff` is empty for both `install-config.yaml` and `agent-config.yaml`.

**Why git-show approach:** The old and new generators have completely different internal variable contracts; the old script uses `HSP_MACHINE_NETWORK` while the new uses `HSP_NET_FAMILIES`. Calling `git show` is straightforward and more robust than maintaining a hardcoded golden string that would need updating whenever even whitespace changes.

## Fix 3 — Cluster-network hostPrefix override test

**File:** `tests/test-hetzner-sno-prepare-pxe.sh`

Added `test_generate_install_config_cluster_network_override_hostprefix`:
- Sets `ACTIVE_V6=1`, `CLUSTER_NETWORKS=("fd01::/48,56")`.
- Asserts `clusterNetwork:`, `cidr: "fd01::/48"`, `hostPrefix: 56` all appear in the output.
- Verifies `hostPrefix: 56` immediately follows the `cidr` entry using `grep -A1`.

## Fix 4 — v6-only print_resolved_config display test

**File:** `tests/test-hetzner-sno-prepare-pxe.sh`

Added `test_print_resolved_config_v6_only_shows_ipv6_lines`:
- Sets `ACTIVE_V4=0`, `ACTIVE_V6=1` plus every variable `print_resolved_config` reads (sentinel values).
- `WORKDIR` passed via env-prefix to respect the `readonly` declaration.
- Asserts IPv6 address and gateway lines appear in output.
- Uses `if grep ...; then` (not `&&`) for the "must NOT appear" checks to avoid `set -e` triggering on a wanted non-match.

## Suite Result

Command: `bash tests/test-hetzner-sno-prepare-pxe.sh`

**Total: 51 ok / exit 0**

**Pristine:** The 5 "unbound variable" stderr lines from `test_print_replay_command_includes_ipv6_flags` were pre-existing (present in the 48-test baseline). The 3 new tests add no new stray warnings.
