# IPv6 Support for the Agent-Based Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `hetzner-sno-prepare-pxe.sh` configure the SNO node as IPv4-only, IPv6-only, or dual-stack, with IPv6 autodiscovery proposing a stable `<prefix>::1` host address.

**Architecture:** Networking is resolved once into an ordered JSON family list (`NET_FAMILIES_JSON`), IPv4 first. The two inline-Python YAML generators loop over that list to emit `machineNetwork`/`clusterNetwork`/`serviceNetwork` entries and `ipv4:`/`ipv6:` nmstate blocks with matching default routes. Family is inferred from the address flags present; an optional `--ip-family` forces and validates intent. The IPv4-only path stays byte-for-byte identical to today.

**Tech Stack:** Bash (global-variable style), Python 3 `ipaddress` (inline heredocs), shell test harness in `tests/test-hetzner-sno-prepare-pxe.sh` (source script with `HSPPXE_TEST_MODE=1`, stub `ip`/`lsblk` via `PATH`).

## Global Constraints

- **Backward compatibility:** an IPv4-only run (no IPv6 flags, no `--ip-family`, no `--cluster-network`/`--service-network`) MUST produce byte-identical `install-config.yaml` and `agent-config.yaml` to the current script. Every generator change is guarded to preserve this.
- **Dual-stack is IPv4-primary:** IPv4 is always first in every ordered list; `rendezvousIP` is the IPv4 node address when IPv4 is active.
- **Static addressing only:** generated nmstate uses `dhcp: false` (both families) and `autoconf: false` (IPv6). No DHCPv6/SLAAC for the node address.
- **IPv6 ULA defaults:** `clusterNetwork fd01::/48` hostPrefix `64`; `serviceNetwork fd02::/112`. IPv4 defaults: `clusterNetwork 10.128.0.0/14` hostPrefix `23`; `serviceNetwork 172.30.0.0/16`.
- **Test invocation:** run the suite with `bash tests/test-hetzner-sno-prepare-pxe.sh`. Every test must print `ok - <name>`; the script exits non-zero if any fail.
- **No Co-Authored-By trailer** in commits.
- Match the existing code style: 2-space indent, `die "..."` for fatal errors, `printf '%s\n'` over `echo` for data, functions added near related functions.

## File Structure

- **Modify** `hetzner-sno-prepare-pxe.sh` — all logic (CLI parsing, validation, discovery, family model, generators, display, persistence).
- **Modify** `tests/test-hetzner-sno-prepare-pxe.sh` — new test functions + `run_test` registrations.
- **Modify** `README.md`, `COMPARISON.md` — document the IPv6/dual-stack flags and examples.

There is one script file by project convention; do not split it. Helper functions are added beside the functions they relate to.

---

### Task 1: New CLI flags and usage text

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (usage block ~196-210; `parse_args` defaults ~219-233; option `case` ~273-299)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Produces (globals set by `parse_args`): `IPV6_WITH_PREFIX_OVERRIDE` (string), `IPV6_GATEWAY_OVERRIDE` (string), `IP_FAMILY_OVERRIDE` (`""`|`v4`|`v6`|`dual`), `CLUSTER_NETWORKS` (array), `SERVICE_NETWORKS` (array). Existing `IP_WITH_PREFIX_OVERRIDE`, `GATEWAY_OVERRIDE`, `DNS_SERVERS_OVERRIDE` unchanged.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-hetzner-sno-prepare-pxe.sh`:

```bash
test_parse_args_accepts_ipv6_and_family_flags() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    parse_args \
      --ipv6-with-prefix 2a01:4f8:abcd:1234::1/64 \
      --ipv6-gateway fe80::1 \
      --ip-family dual \
      --cluster-network fd01::/48,64 \
      --service-network fd02::/112 \
      4.16.15 /tmp/pull-secret.json example.com sno
    [[ "${IPV6_WITH_PREFIX_OVERRIDE}" == "2a01:4f8:abcd:1234::1/64" ]] || { echo "v6 prefix: ${IPV6_WITH_PREFIX_OVERRIDE}"; exit 1; }
    [[ "${IPV6_GATEWAY_OVERRIDE}" == "fe80::1" ]] || { echo "v6 gw"; exit 1; }
    [[ "${IP_FAMILY_OVERRIDE}" == "dual" ]] || { echo "family"; exit 1; }
    [[ "${#CLUSTER_NETWORKS[@]}" -eq 1 && "${CLUSTER_NETWORKS[0]}" == "fd01::/48,64" ]] || { echo "cluster: ${CLUSTER_NETWORKS[*]}"; exit 1; }
    [[ "${#SERVICE_NETWORKS[@]}" -eq 1 && "${SERVICE_NETWORKS[0]}" == "fd02::/112" ]] || { echo "service: ${SERVICE_NETWORKS[*]}"; exit 1; }
  '
}
```

Register it next to the other `parse_args` registrations (~575):

```bash
run_test "parse_args accepts ipv6 and family flags" test_parse_args_accepts_ipv6_and_family_flags
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'ipv6 and family'`
Expected: `not ok - parse_args accepts ipv6 and family flags`

- [ ] **Step 3: Add the defaults**

In `parse_args`, after line 228 (`GATEWAY_OVERRIDE=""`), add:

```bash
  IPV6_WITH_PREFIX_OVERRIDE=""
  IPV6_GATEWAY_OVERRIDE=""
  IP_FAMILY_OVERRIDE=""
  CLUSTER_NETWORKS=()
  SERVICE_NETWORKS=()
```

- [ ] **Step 4: Add the option cases**

In the `case "$1"` block, after the `--gateway` case (ends line 290), add:

```bash
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
```

- [ ] **Step 5: Update usage text**

In the usage heredoc, after the `--gateway` line (202) add:

```
  --ipv6-with-prefix <cidr>  IPv6 address with prefix, for example 2a01:db8::1/64
  --ipv6-gateway <ip>        Default IPv6 gateway (may be link-local, e.g. fe80::1)
  --ip-family <v4|v6|dual>   Force/validate the configured IP family set
  --cluster-network <cidr[,hostPrefix]>  Override clusterNetwork (repeatable)
  --service-network <cidr>   Override serviceNetwork (repeatable)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'ipv6 and family'`
Expected: `ok - parse_args accepts ipv6 and family flags`

- [ ] **Step 7: Run full suite (regression guard)**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, no `not ok -`, exit 0.

- [ ] **Step 8: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Add IPv6/dual-stack CLI flags and usage text"
```

---

### Task 2: Validate IPv6 values and family consistency

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (`validate_ip_values` ~638-656; add `validate_ip_family` near it)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `IP_WITH_PREFIX_OVERRIDE`, `GATEWAY_OVERRIDE`, `IPV6_WITH_PREFIX_OVERRIDE`, `IPV6_GATEWAY_OVERRIDE`, `IP_FAMILY_OVERRIDE`.
- Produces: `validate_ip_family` — returns 0 if the requested `--ip-family` is consistent with the address flags present, else calls `die` and returns 1. Pure (reads globals, no side effects beyond `die`).

- [ ] **Step 1: Write the failing tests**

```bash
test_validate_ip_family_rejects_dual_with_one_address() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    IP_FAMILY_OVERRIDE="dual"
    IP_WITH_PREFIX_OVERRIDE="192.0.2.10/24"
    IPV6_WITH_PREFIX_OVERRIDE=""
    ! validate_ip_family
  ' 2>/dev/null
}

test_validate_ip_family_rejects_v6_with_v4_address() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    IP_FAMILY_OVERRIDE="v6"
    IP_WITH_PREFIX_OVERRIDE="192.0.2.10/24"
    ! validate_ip_family
  ' 2>/dev/null
}

test_validate_ip_family_accepts_consistent_dual() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    IP_FAMILY_OVERRIDE="dual"
    IP_WITH_PREFIX_OVERRIDE="192.0.2.10/24"
    IPV6_WITH_PREFIX_OVERRIDE="2a01:db8::1/64"
    validate_ip_family
  '
}
```

Register all three near the other validation registrations (~588):

```bash
run_test "validate_ip_family rejects dual with one address" test_validate_ip_family_rejects_dual_with_one_address
run_test "validate_ip_family rejects v6 family with v4 address" test_validate_ip_family_rejects_v6_with_v4_address
run_test "validate_ip_family accepts consistent dual" test_validate_ip_family_accepts_consistent_dual
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep validate_ip_family`
Expected: `not ok` for all three (`validate_ip_family: command not found`).

- [ ] **Step 3: Implement `validate_ip_family`**

Add directly above `validate_ip_values` (line 638). Note: `--ip-family v6` with a v4 address is a conflict only when the v4 address came from an explicit flag (auto-detect fills v4 by default and must not block a `v6` request).

```bash
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
```

- [ ] **Step 4: Extend `validate_ip_values` to accept IPv6**

`validate_ip_values` already validates whatever is in `IP_WITH_PREFIX`, `GATEWAY`, and `DNS_SERVERS` with `ipaddress`, which accepts either family. Add a second optional pair for IPv6 so a dual-stack run validates both. Replace the body (lines 638-656) with:

```bash
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep validate_ip_family`
Expected: `ok` for all three.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0. (Confirms the `validate_ip_values` change still passes the existing IPv4 path, which sets `IP_WITH_PREFIX`/`GATEWAY` and leaves the IPv6 vars empty.)

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Validate IPv6 values and --ip-family consistency"
```

---

### Task 3: IPv6 autodiscovery

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (add `propose_ipv6_host` and `discover_ipv6` near `resolve_network_config` ~967)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Produces:
  - `propose_ipv6_host <network-cidr>` — prints `<network-address+1>/<prefix>` (e.g. `2a01:db8::/64` → `2a01:db8::1/64`). Pure.
  - `discover_ipv6` — consumes `DEFAULT_IFACE`, `IPV6_WITH_PREFIX_OVERRIDE`, `IPV6_GATEWAY_OVERRIDE`; sets globals `IPV6_WITH_PREFIX` and `IPV6_GATEWAY`. Uses the `ip` command (stubbable). Calls `die` and returns 1 if no prefix or no gateway can be found and none was supplied.

- [ ] **Step 1: Write the failing tests**

```bash
test_propose_ipv6_host_returns_first_address() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    [[ "$(propose_ipv6_host 2a01:4f8:abcd:1234::/64)" == "2a01:4f8:abcd:1234::1/64" ]]
  '
}

test_discover_ipv6_uses_ra_prefix_and_default_gateway() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/ip" <<'EOF'
#!/bin/bash
case "$*" in
  "-6 route show dev eth0")
    printf 'fe80::/64 dev eth0 proto kernel metric 256\n'
    printf '2a01:4f8:abcd:1234::/64 dev eth0 proto ra metric 100\n'
    ;;
  "-6 route show default")
    printf 'default via fe80::1 dev eth0 proto ra metric 100\n'
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${stub_dir}/ip"
  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DEFAULT_IFACE="eth0"
    IPV6_WITH_PREFIX_OVERRIDE=""
    IPV6_GATEWAY_OVERRIDE=""
    discover_ipv6
    [[ "${IPV6_WITH_PREFIX}" == "2a01:4f8:abcd:1234::1/64" ]] || { echo "ip: ${IPV6_WITH_PREFIX}"; exit 1; }
    [[ "${IPV6_GATEWAY}" == "fe80::1" ]] || { echo "gw: ${IPV6_GATEWAY}"; exit 1; }
  '
  status=$?
  rm -rf "${stub_dir}"
  return "${status}"
}

test_discover_ipv6_honors_overrides() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DEFAULT_IFACE="eth0"
    IPV6_WITH_PREFIX_OVERRIDE="2a01:db8::5/64"
    IPV6_GATEWAY_OVERRIDE="2a01:db8::1"
    discover_ipv6
    [[ "${IPV6_WITH_PREFIX}" == "2a01:db8::5/64" ]] || { echo "ip: ${IPV6_WITH_PREFIX}"; exit 1; }
    [[ "${IPV6_GATEWAY}" == "2a01:db8::1" ]] || { echo "gw: ${IPV6_GATEWAY}"; exit 1; }
  '
}

test_discover_ipv6_dies_without_prefix() {
  local stub_dir status
  stub_dir="$(mktemp -d)"
  cat > "${stub_dir}/ip" <<'EOF'
#!/bin/bash
case "$*" in
  "-6 route show dev eth0") printf 'fe80::/64 dev eth0 proto kernel metric 256\n' ;;
  "-6 route show default") printf '' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${stub_dir}/ip"
  PATH="${stub_dir}:${PATH}" HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    DEFAULT_IFACE="eth0"
    IPV6_WITH_PREFIX_OVERRIDE=""
    IPV6_GATEWAY_OVERRIDE=""
    ! discover_ipv6
  ' 2>/dev/null
  status=$?
  rm -rf "${stub_dir}"
  return "${status}"
}
```

Register near the network-related registrations (~753):

```bash
run_test "propose_ipv6_host returns first address" test_propose_ipv6_host_returns_first_address
run_test "discover_ipv6 uses RA prefix and default gateway" test_discover_ipv6_uses_ra_prefix_and_default_gateway
run_test "discover_ipv6 honors overrides" test_discover_ipv6_honors_overrides
run_test "discover_ipv6 dies without a usable prefix" test_discover_ipv6_dies_without_prefix
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep -E 'propose_ipv6|discover_ipv6'`
Expected: `not ok` for all four.

- [ ] **Step 3: Implement `propose_ipv6_host`**

Add above `resolve_network_config` (line 967):

```bash
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
```

- [ ] **Step 4: Implement `discover_ipv6`**

Add directly below `propose_ipv6_host`:

```bash
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep -E 'propose_ipv6|discover_ipv6'`
Expected: `ok` for all four.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Add IPv6 autodiscovery proposing <prefix>::1"
```

---

### Task 4: Family model and selection in `resolve_network_config`

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (add `build_net_families_json`; extend `resolve_network_config` ~967-1044)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `validate_ip_family` (Task 2), `discover_ipv6` (Task 3).
- Produces:
  - `build_net_families_json` — reads env `NETF_V4_IP`, `NETF_V4_PREFIX`, `NETF_V4_GW`, `NETF_V6_IP`, `NETF_V6_PREFIX`, `NETF_V6_GW` (any pair may be empty) and prints a JSON array of records `{"family","ip","prefix","gateway","cidr"}`, IPv4 first. Pure.
  - `resolve_network_config` additionally sets: `ACTIVE_V4` (0/1), `ACTIVE_V6` (0/1), `NET_FAMILIES_JSON` (string), and `RENDEZVOUS_IP` = `OVERRIDE_IP` or the primary (first) family's IP.

- [ ] **Step 1: Write the failing test**

```bash
test_build_net_families_json_orders_v4_first() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    out="$(NETF_V4_IP=192.0.2.10 NETF_V4_PREFIX=24 NETF_V4_GW=192.0.2.1 \
           NETF_V6_IP=2a01:db8::1 NETF_V6_PREFIX=64 NETF_V6_GW=fe80::1 \
           build_net_families_json)"
    printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert [r[\"family\"] for r in d]==[\"v4\",\"v6\"], d
assert d[0][\"cidr\"]==\"192.0.2.0/24\", d[0]
assert d[1][\"cidr\"]==\"2a01:db8::/64\", d[1]
assert d[1][\"gateway\"]==\"fe80::1\", d[1]
"
  '
}

test_build_net_families_json_v6_only() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    out="$(NETF_V4_IP="" NETF_V4_PREFIX="" NETF_V4_GW="" \
           NETF_V6_IP=2a01:db8::1 NETF_V6_PREFIX=64 NETF_V6_GW=fe80::1 \
           build_net_families_json)"
    printf "%s" "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert [r[\"family\"] for r in d]==[\"v6\"], d
"
  '
}
```

Register near the network registrations (~753):

```bash
run_test "build_net_families_json orders v4 first" test_build_net_families_json_orders_v4_first
run_test "build_net_families_json supports v6-only" test_build_net_families_json_v6_only
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep build_net_families`
Expected: `not ok` for both.

- [ ] **Step 3: Implement `build_net_families_json`**

Add above `resolve_network_config` (line 967):

```bash
# Emit the ordered per-family record list as JSON (IPv4 first). Each present
# family (non-empty NETF_<F>_IP) becomes {family,ip,prefix,gateway,cidr}.
build_net_families_json() {
  python3 - <<'PY'
import ipaddress
import json
import os

records = []
for fam, ipkey, pfxkey, gwkey in (
    ("v4", "NETF_V4_IP", "NETF_V4_PREFIX", "NETF_V4_GW"),
    ("v6", "NETF_V6_IP", "NETF_V6_PREFIX", "NETF_V6_GW"),
):
    ip = os.environ.get(ipkey, "").strip()
    if not ip:
        continue
    prefix = int(os.environ[pfxkey])
    gateway = os.environ.get(gwkey, "").strip()
    cidr = str(ipaddress.ip_interface(f"{ip}/{prefix}").network)
    records.append({"family": fam, "ip": ip, "prefix": prefix,
                    "gateway": gateway, "cidr": cidr})
print(json.dumps(records))
PY
}
```

- [ ] **Step 4: Wire selection into `resolve_network_config`**

This is the integration step. The current function (967-1044) detects IPv4, gateway, MAC, DNS, derives `MACHINE_NETWORK`, then validates. Restructure it so IPv4 detection is conditional on the active family set and IPv6 is discovered when active. Replace the function body with the version below (preserves all existing IPv4 behavior when only v4 is active):

```bash
resolve_network_config() {
  DEFAULT_IFACE="${NETWORK_INTERFACE_OVERRIDE:-}"
  if [[ -z "$DEFAULT_IFACE" ]]; then
    DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5}' | head -1)"
  fi
  [[ -n "$DEFAULT_IFACE" ]] || die "Could not determine the default network interface. Use --network-interface."

  validate_ip_family || exit 1

  # Decide which families are active. Explicit --ip-family wins; otherwise infer
  # from the address flags, defaulting to IPv4-only auto-detect (unchanged).
  ACTIVE_V4=0
  ACTIVE_V6=0
  case "${IP_FAMILY_OVERRIDE:-}" in
    v4) ACTIVE_V4=1 ;;
    v6) ACTIVE_V6=1 ;;
    dual) ACTIVE_V4=1; ACTIVE_V6=1 ;;
    "")
      [[ -n "${IP_WITH_PREFIX_OVERRIDE:-}" ]] && ACTIVE_V4=1
      [[ -n "${IPV6_WITH_PREFIX_OVERRIDE:-}" ]] && ACTIVE_V6=1
      if [[ "$ACTIVE_V4" -eq 0 && "$ACTIVE_V6" -eq 0 ]]; then
        ACTIVE_V4=1   # default: IPv4-only auto-detect
      fi
      ;;
  esac

  MAC_ADDR="$(ip link show "$DEFAULT_IFACE" | awk '/link\/ether/ {print $2}' | head -1)"
  [[ -n "$MAC_ADDR" ]] || die "Could not determine MAC address for ${DEFAULT_IFACE}."

  IP_WITH_PREFIX=""; IP_ADDR=""; PREFIX_LEN=""; GATEWAY=""
  IPV6_WITH_PREFIX=""; IPV6_ADDR=""; IPV6_PREFIX_LEN=""; IPV6_GATEWAY=""

  if [[ "$ACTIVE_V4" -eq 1 ]]; then
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
  fi

  if [[ "$ACTIVE_V6" -eq 1 ]]; then
    discover_ipv6 || exit 1
    IPV6_ADDR="${IPV6_WITH_PREFIX%/*}"
    IPV6_PREFIX_LEN="${IPV6_WITH_PREFIX#*/}"
  fi

  # Primary family is IPv4 when active, else IPv6.
  local primary_ip="$IP_ADDR"
  [[ "$ACTIVE_V4" -eq 0 ]] && primary_ip="$IPV6_ADDR"
  RENDEZVOUS_IP="${OVERRIDE_IP:-${primary_ip}}"
  NODE_HOSTNAME="$HOSTNAME_OVERRIDE"

  resolve_dns_servers   # sets DNS_SERVERS (Task 5)

  validate_ip_values

  NET_FAMILIES_JSON="$(NETF_V4_IP="$IP_ADDR" NETF_V4_PREFIX="$PREFIX_LEN" NETF_V4_GW="$GATEWAY" \
    NETF_V6_IP="$IPV6_ADDR" NETF_V6_PREFIX="$IPV6_PREFIX_LEN" NETF_V6_GW="$IPV6_GATEWAY" \
    build_net_families_json)"

  # MACHINE_NETWORK retained for the resolved-config display (primary family).
  if [[ "$ACTIVE_V4" -eq 1 ]]; then
    MACHINE_NETWORK="$(python3 - "$IP_WITH_PREFIX" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
  else
    MACHINE_NETWORK="$(python3 - "$IPV6_WITH_PREFIX" <<'PY'
import ipaddress, sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
  fi

  DNS_SERVERS_RAW="$(printf '%s\n' "${DNS_SERVERS[@]}")"
  DNS_DISPLAY="$(printf '%s ' "${DNS_SERVERS[@]}")"
}
```

> Note: the DNS collection/filtering currently inline in `resolve_network_config` (lines ~1002-1039) moves into `resolve_dns_servers` in Task 5. Until Task 5 lands, temporarily keep the existing DNS lines in place of the `resolve_dns_servers` call so the script stays runnable; Task 5 replaces them. (If executing strictly task-by-task, paste the current lines 1002-1039 inline here, then extract them in Task 5.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep build_net_families`
Expected: `ok` for both.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0 (the existing `main allows interactive multi-disk selection` test exercises the IPv4 auto-detect path end-to-end).

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Build ordered per-family network model and selection"
```

---

### Task 5: DNS family union and per-family fallback

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (extract `resolve_dns_servers` from the DNS block; relax single-family filter to a per-active-family union)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `filter_dns_by_family` (existing), `ACTIVE_V4`, `ACTIVE_V6`, `DNS_SERVERS_OVERRIDE`.
- Produces: `resolve_dns_servers` — sets `DNS_SERVERS` to the collected resolvers filtered to the union of active families, applying per-family fallbacks when empty.
  - `filter_dns_by_active_families <server...>` — prints the subset of servers whose family is active. Pure (reads `ACTIVE_V4`/`ACTIVE_V6`).

- [ ] **Step 1: Write the failing test**

```bash
test_filter_dns_by_active_families_keeps_both_in_dual() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ACTIVE_V4=1; ACTIVE_V6=1
    mapfile -t kept < <(filter_dns_by_active_families 8.8.8.8 2001:4860:4860::8888 1.1.1.1)
    [[ "${#kept[@]}" -eq 3 ]] || { echo "got ${#kept[@]}: ${kept[*]}"; exit 1; }
  '
}

test_filter_dns_by_active_families_drops_v6_when_v4_only() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    ACTIVE_V4=1; ACTIVE_V6=0
    mapfile -t kept < <(filter_dns_by_active_families 8.8.8.8 2001:4860:4860::8888)
    [[ "${#kept[@]}" -eq 1 && "${kept[0]}" == "8.8.8.8" ]] || { echo "got: ${kept[*]}"; exit 1; }
  '
}
```

Register near the DNS registrations (~753):

```bash
run_test "filter_dns_by_active_families keeps both in dual" test_filter_dns_by_active_families_keeps_both_in_dual
run_test "filter_dns_by_active_families drops v6 when v4 only" test_filter_dns_by_active_families_drops_v6_when_v4_only
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep filter_dns_by_active_families`
Expected: `not ok` for both.

- [ ] **Step 3: Implement `filter_dns_by_active_families`**

Add directly below `filter_dns_by_family` (line 965):

```bash
# Keep DNS servers whose family is currently active. In dual-stack both
# families are kept; in single-family runs the mismatched family is dropped
# (nmstate has no IP-enabled interface for it).
filter_dns_by_active_families() {
  local server is_v6
  for server in "$@"; do
    is_v6=0
    [[ "$server" == *:* ]] && is_v6=1
    if [[ "$is_v6" -eq 1 && "${ACTIVE_V6:-0}" -eq 1 ]]; then
      printf '%s\n' "$server"
    elif [[ "$is_v6" -eq 0 && "${ACTIVE_V4:-0}" -eq 1 ]]; then
      printf '%s\n' "$server"
    fi
  done
}
```

- [ ] **Step 4: Extract and rewrite `resolve_dns_servers`**

Move the DNS collection and filtering (current lines ~1002-1039) into a new function placed just above `resolve_network_config`. Replace the per-`IP_ADDR` filter with the active-families union, and add per-family fallbacks:

```bash
resolve_dns_servers() {
  if [[ "${#DNS_SERVERS_OVERRIDE[@]}" -gt 0 ]]; then
    DNS_SERVERS=("${DNS_SERVERS_OVERRIDE[@]}")
  else
    DNS_SERVERS=()
    if command -v resolvectl >/dev/null 2>&1; then
      mapfile -t DNS_SERVERS < <(resolvectl dns 2>/dev/null \
        | awk '{for(i=2;i<=NF;i++) print $i}' \
        | grep -vE '^(127\.|::1$)' | head -3)
    fi
    if [[ "${#DNS_SERVERS[@]}" -eq 0 ]]; then
      mapfile -t DNS_SERVERS < <(awk '/^nameserver/ {print $2}' /etc/resolv.conf \
        | grep -vE '^(127\.|::1$)' | head -3)
    fi
  fi

  local -a dns_kept
  mapfile -t dns_kept < <(filter_dns_by_active_families "${DNS_SERVERS[@]}")
  if [[ "${#dns_kept[@]}" -ne "${#DNS_SERVERS[@]}" ]]; then
    local -a dns_dropped
    mapfile -t dns_dropped < <(comm -23 \
      <(printf '%s\n' "${DNS_SERVERS[@]}" | sort) \
      <(printf '%s\n' "${dns_kept[@]}" | sort))
    echo "WARNING: Ignoring DNS server(s) for inactive address families: ${dns_dropped[*]}" >&2
  fi
  DNS_SERVERS=("${dns_kept[@]}")

  # Fallback resolvers per active family when nothing usable remained.
  if [[ "${#DNS_SERVERS[@]}" -eq 0 ]]; then
    [[ "${ACTIVE_V4:-0}" -eq 1 ]] && DNS_SERVERS+=("8.8.8.8" "8.8.4.4")
    [[ "${ACTIVE_V6:-0}" -eq 1 ]] && DNS_SERVERS+=("2001:4860:4860::8888" "2001:4860:4860::8844")
  fi
}
```

Then ensure `resolve_network_config` calls `resolve_dns_servers` (the placeholder from Task 4 Step 4 note) and remove the now-duplicated inline DNS lines.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep filter_dns_by_active_families`
Expected: `ok` for both.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0. The existing `filter_dns_by_family keeps IPv4 for IPv4 host` test still passes (that helper is unchanged).

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Union DNS resolvers across active families with per-family fallback"
```

---

### Task 6: install-config generator — cluster/service/machine networks

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (`generate_install_config` ~1080-1121)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `NET_FAMILIES_JSON` (Task 4), `ACTIVE_V4`/`ACTIVE_V6`, `CLUSTER_NETWORKS`/`SERVICE_NETWORKS` (Task 1), plus existing `INSTALL_DIR`, `BASE_DOMAIN`, `CLUSTER_NAME`, `PULL_SECRET_FILE`, `SSH_PUB_KEY`.
- Produces: writes `install-config.yaml`. Cluster/service blocks emitted only when IPv6 is active OR an override array is non-empty; otherwise omitted (byte-stable IPv4-only output).

- [ ] **Step 1: Write the failing tests**

```bash
_write_install_config_for_test() {
  # args: INSTALL_DIR is set by caller; relies on globals set inline
  generate_install_config >/dev/null
}

test_generate_install_config_ipv4_only_omits_cluster_service() {
  local dir status
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    INSTALL_DIR="'"${dir}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=1; ACTIVE_V6=0
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    MACHINE_NETWORK="192.0.2.0/24"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"}]"
    generate_install_config >/dev/null
    f="'"${dir}"'/install-config.yaml"
    grep -q "machineNetwork" "$f" || { echo "no machineNetwork"; exit 1; }
    grep -q "cidr: \"192.0.2.0/24\"" "$f" || { echo "no v4 cidr"; exit 1; }
    ! grep -q "clusterNetwork" "$f" || { echo "clusterNetwork leaked"; exit 1; }
    ! grep -q "serviceNetwork" "$f" || { echo "serviceNetwork leaked"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_generate_install_config_dual_emits_both_networks() {
  local dir status
  dir="$(mktemp -d)"
  printf '{}' > "${dir}/pull-secret.json"
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    INSTALL_DIR="'"${dir}"'"
    BASE_DOMAIN="example.com"; CLUSTER_NAME="sno"
    PULL_SECRET_FILE="'"${dir}"'/pull-secret.json"; SSH_PUB_KEY="ssh-ed25519 AAAA"
    ACTIVE_V4=1; ACTIVE_V6=1
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    MACHINE_NETWORK="192.0.2.0/24"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"},{\"family\":\"v6\",\"ip\":\"2a01:db8::1\",\"prefix\":64,\"gateway\":\"fe80::1\",\"cidr\":\"2a01:db8::/64\"}]"
    generate_install_config >/dev/null
    f="'"${dir}"'/install-config.yaml"
    grep -q "cidr: \"192.0.2.0/24\"" "$f" || { echo "no v4 machine"; exit 1; }
    grep -q "cidr: \"2a01:db8::/64\"" "$f" || { echo "no v6 machine"; exit 1; }
    grep -q "cidr: \"10.128.0.0/14\"" "$f" || { echo "no v4 cluster"; exit 1; }
    grep -q "cidr: \"fd01::/48\"" "$f" || { echo "no v6 cluster default"; exit 1; }
    grep -q "172.30.0.0/16" "$f" || { echo "no v4 service"; exit 1; }
    grep -q "fd02::/112" "$f" || { echo "no v6 service default"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}
```

Register near the end (~759):

```bash
run_test "generate_install_config IPv4-only omits cluster/service" test_generate_install_config_ipv4_only_omits_cluster_service
run_test "generate_install_config dual emits both networks" test_generate_install_config_dual_emits_both_networks
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep generate_install_config`
Expected: `not ok` (dual test fails — current generator emits a single machineNetwork and no cluster/service).

- [ ] **Step 3: Rewrite `generate_install_config`**

Replace the function (1080-1121) with the version below. It passes the family list and override arrays as env/JSON and loops in Python.

```bash
generate_install_config() {
  local cluster_json service_json
  cluster_json="$(printf '%s\n' "${CLUSTER_NETWORKS[@]:-}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l.strip()]))')"
  service_json="$(printf '%s\n' "${SERVICE_NETWORKS[@]:-}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l.strip()]))')"

  HSP_INSTALL_DIR="$INSTALL_DIR" \
  HSP_BASE_DOMAIN="$BASE_DOMAIN" \
  HSP_CLUSTER_NAME="$CLUSTER_NAME" \
  HSP_PULL_SECRET_FILE="$PULL_SECRET_FILE" \
  HSP_SSH_PUB_KEY="$SSH_PUB_KEY" \
  HSP_NET_FAMILIES="$NET_FAMILIES_JSON" \
  HSP_ACTIVE_V6="$ACTIVE_V6" \
  HSP_CLUSTER_NETWORKS="$cluster_json" \
  HSP_SERVICE_NETWORKS="$service_json" \
  python3 - <<'PY'
import json
import os

def q(value):
    return json.dumps(value)

CLUSTER_DEFAULTS = {"v4": ("10.128.0.0/14", 23), "v6": ("fd01::/48", 64)}
SERVICE_DEFAULTS = {"v4": "172.30.0.0/16", "v6": "fd02::/112"}

families = json.loads(os.environ["HSP_NET_FAMILIES"])
active_v6 = os.environ["HSP_ACTIVE_V6"] == "1"
cluster_overrides = json.loads(os.environ["HSP_CLUSTER_NETWORKS"])
service_overrides = json.loads(os.environ["HSP_SERVICE_NETWORKS"])

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

    # clusterNetwork / serviceNetwork only when IPv6 is active or overridden,
    # so the IPv4-only file stays byte-identical to the historical output.
    if active_v6 or cluster_overrides or service_overrides:
        handle.write("  clusterNetwork:\n")
        if cluster_overrides:
            for entry in cluster_overrides:
                cidr, _, hp = entry.partition(",")
                if not hp:
                    hp = "64" if ":" in cidr else "23"
                handle.write(f"  - cidr: {q(cidr)}\n")
                handle.write(f"    hostPrefix: {int(hp)}\n")
        else:
            for fam in families:
                cidr, hp = CLUSTER_DEFAULTS[fam["family"]]
                handle.write(f"  - cidr: {q(cidr)}\n")
                handle.write(f"    hostPrefix: {hp}\n")
        handle.write("  serviceNetwork:\n")
        if service_overrides:
            for cidr in service_overrides:
                handle.write(f"  - {q(cidr)}\n")
        else:
            for fam in families:
                handle.write(f"  - {q(SERVICE_DEFAULTS[fam['family']])}\n")

    handle.write("  machineNetwork:\n")
    for fam in families:
        handle.write(f"  - cidr: {q(fam['cidr'])}\n")

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
```

> Byte-stability note: for IPv4-only with no overrides, the emitted lines are `apiVersion`, `baseDomain`, `metadata`, `networking` (networkType + machineNetwork only), `compute`, `controlPlane`, `platform`, `pullSecret`, `sshKey` — identical to the current generator.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep generate_install_config`
Expected: `ok` for both.

- [ ] **Step 5: Verify IPv4-only byte-stability against main**

Run:

```bash
git stash --include-untracked
git show main:hetzner-sno-prepare-pxe.sh > /tmp/old.sh 2>/dev/null || git show 9c53635:hetzner-sno-prepare-pxe.sh > /tmp/old.sh
git stash pop
```

Then generate from both with identical IPv4 globals into two temp dirs and `diff` the `install-config.yaml`. (A scripted comparison: source each script, set the same v4 globals as in the IPv4-only test, call `generate_install_config`, `diff` the outputs.) Expected: no differences.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Generate install-config networks per active family"
```

---

### Task 7: agent-config generator — per-family nmstate and routes

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (`generate_agent_config` ~1123-1197)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `NET_FAMILIES_JSON`, `DNS_SERVERS_RAW`, `RENDEZVOUS_IP`, plus existing host globals (`NODE_HOSTNAME`, `DEFAULT_IFACE`, `MAC_ADDR`, `INSTALL_DISK`, `INSTALL_DISK_SERIAL`, `CLUSTER_NAME`, `INSTALL_DIR`).
- Produces: writes `agent-config.yaml` with one nmstate `ipv4:`/`ipv6:` block and one default route per family, `rendezvousIP` from the primary family.

- [ ] **Step 1: Write the failing tests**

```bash
test_generate_agent_config_dual_emits_both_blocks() {
  local dir status
  dir="$(mktemp -d)"
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    INSTALL_DIR="'"${dir}"'"; CLUSTER_NAME="sno"
    RENDEZVOUS_IP="192.0.2.10"; NODE_HOSTNAME="node.example.com"
    DEFAULT_IFACE="eth0"; MAC_ADDR="00:11:22:33:44:55"
    INSTALL_DISK="/dev/nvme0n1"; INSTALL_DISK_SERIAL="SN-A"
    DNS_SERVERS_RAW="$(printf "8.8.8.8\n2001:4860:4860::8888\n")"
    NET_FAMILIES_JSON="[{\"family\":\"v4\",\"ip\":\"192.0.2.10\",\"prefix\":24,\"gateway\":\"192.0.2.1\",\"cidr\":\"192.0.2.0/24\"},{\"family\":\"v6\",\"ip\":\"2a01:db8::1\",\"prefix\":64,\"gateway\":\"fe80::1\",\"cidr\":\"2a01:db8::/64\"}]"
    generate_agent_config >/dev/null
    f="'"${dir}"'/agent-config.yaml"
    grep -q "rendezvousIP: \"192.0.2.10\"" "$f" || { echo "rendezvous"; exit 1; }
    grep -q "ipv4:" "$f" || { echo "no ipv4"; exit 1; }
    grep -q "ipv6:" "$f" || { echo "no ipv6"; exit 1; }
    grep -q "autoconf: false" "$f" || { echo "no autoconf false"; exit 1; }
    grep -q "destination: 0.0.0.0/0" "$f" || { echo "no v4 route"; exit 1; }
    grep -q "destination: ::/0" "$f" || { echo "no v6 route"; exit 1; }
    grep -q "next-hop-address: \"fe80::1\"" "$f" || { echo "no v6 gw"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}

test_generate_agent_config_v6_only_has_no_ipv4_block() {
  local dir status
  dir="$(mktemp -d)"
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    INSTALL_DIR="'"${dir}"'"; CLUSTER_NAME="sno"
    RENDEZVOUS_IP="2a01:db8::1"; NODE_HOSTNAME="node.example.com"
    DEFAULT_IFACE="eth0"; MAC_ADDR="00:11:22:33:44:55"
    INSTALL_DISK="/dev/nvme0n1"; INSTALL_DISK_SERIAL="SN-A"
    DNS_SERVERS_RAW="$(printf "2001:4860:4860::8888\n")"
    NET_FAMILIES_JSON="[{\"family\":\"v6\",\"ip\":\"2a01:db8::1\",\"prefix\":64,\"gateway\":\"fe80::1\",\"cidr\":\"2a01:db8::/64\"}]"
    generate_agent_config >/dev/null
    f="'"${dir}"'/agent-config.yaml"
    grep -q "ipv6:" "$f" || { echo "no ipv6"; exit 1; }
    ! grep -q "ipv4:" "$f" || { echo "ipv4 leaked"; exit 1; }
    grep -q "destination: ::/0" "$f" || { echo "no v6 route"; exit 1; }
    ! grep -q "destination: 0.0.0.0/0" "$f" || { echo "v4 route leaked"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}
```

Register near the end (~759):

```bash
run_test "generate_agent_config dual emits both blocks" test_generate_agent_config_dual_emits_both_blocks
run_test "generate_agent_config v6-only has no ipv4 block" test_generate_agent_config_v6_only_has_no_ipv4_block
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep generate_agent_config`
Expected: `not ok` for both.

- [ ] **Step 3: Rewrite `generate_agent_config`**

Replace the function (1123-1197) with the version below. The `rootDeviceHints` logic (serial-vs-deviceName) is preserved verbatim; only the networking block becomes a per-family loop.

```bash
generate_agent_config() {
  HSP_DNS_SERVERS_RAW="$DNS_SERVERS_RAW" \
  HSP_INSTALL_DIR="$INSTALL_DIR" \
  HSP_CLUSTER_NAME="$CLUSTER_NAME" \
  HSP_RENDEZVOUS_IP="$RENDEZVOUS_IP" \
  HSP_NODE_HOSTNAME="$NODE_HOSTNAME" \
  HSP_DEFAULT_IFACE="$DEFAULT_IFACE" \
  HSP_MAC_ADDR="$MAC_ADDR" \
  HSP_INSTALL_DISK="$INSTALL_DISK" \
  HSP_INSTALL_DISK_SERIAL="${INSTALL_DISK_SERIAL:-}" \
  HSP_NET_FAMILIES="$NET_FAMILIES_JSON" \
  python3 - <<'PY'
import json
import os
import sys

def q(value):
    return json.dumps(value)

dns_servers = [line.strip() for line in os.environ["HSP_DNS_SERVERS_RAW"].splitlines() if line.strip()]
families = json.loads(os.environ["HSP_NET_FAMILIES"])
iface = os.environ["HSP_DEFAULT_IFACE"]
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
    handle.write(f"      - name: {q(iface)}\n")
    handle.write(f"        macAddress: {q(os.environ['HSP_MAC_ADDR'])}\n")
    handle.write("    rootDeviceHints:\n")
    install_disk_serial = os.environ.get("HSP_INSTALL_DISK_SERIAL", "").strip()
    if install_disk_serial:
        handle.write(f"      serialNumber: {q(install_disk_serial)}\n")
    else:
        device = os.environ['HSP_INSTALL_DISK']
        print(
            f"WARNING: no serial for {device}; using unstable deviceName as "
            "install target. The kernel device name may resolve to a different "
            "disk inside the installer.",
            file=sys.stderr,
        )
        handle.write(f"      deviceName: {q(device)}\n")
    handle.write("    networkConfig:\n")
    handle.write("      interfaces:\n")
    handle.write(f"        - name: {q(iface)}\n")
    handle.write("          type: ethernet\n")
    handle.write("          state: up\n")
    handle.write(f"          mac-address: {q(os.environ['HSP_MAC_ADDR'])}\n")
    for fam in families:
        if fam["family"] == "v4":
            handle.write("          ipv4:\n")
            handle.write("            enabled: true\n")
            handle.write("            address:\n")
            handle.write(f"              - ip: {q(fam['ip'])}\n")
            handle.write(f"                prefix-length: {int(fam['prefix'])}\n")
            handle.write("            dhcp: false\n")
        else:
            handle.write("          ipv6:\n")
            handle.write("            enabled: true\n")
            handle.write("            address:\n")
            handle.write(f"              - ip: {q(fam['ip'])}\n")
            handle.write(f"                prefix-length: {int(fam['prefix'])}\n")
            handle.write("            dhcp: false\n")
            handle.write("            autoconf: false\n")
    handle.write("      dns-resolver:\n")
    handle.write("        config:\n")
    handle.write("          server:\n")
    for server in dns_servers:
        handle.write(f"            - {q(server)}\n")
    handle.write("      routes:\n")
    handle.write("        config:\n")
    for fam in families:
        destination = "0.0.0.0/0" if fam["family"] == "v4" else "::/0"
        handle.write(f"          - destination: {destination}\n")
        handle.write(f"            next-hop-address: {q(fam['gateway'])}\n")
        handle.write(f"            next-hop-interface: {q(iface)}\n")
        handle.write("            table-id: 254\n")
PY

  echo "  Written: ${INSTALL_DIR}/agent-config.yaml"
}
```

> Byte-stability note: for an IPv4-only family list the loop emits exactly the previous `ipv4:` block (`enabled`/`address`/`prefix-length`/`dhcp: false`) and the single `0.0.0.0/0` route with `next-hop-interface` + `table-id: 254`, matching the current generator.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep generate_agent_config`
Expected: `ok` for both.

- [ ] **Step 5: Verify IPv4-only byte-stability**

As in Task 6 Step 5, diff the IPv4-only `agent-config.yaml` produced by the new generator against the `9c53635` baseline using identical v4 globals (`NET_FAMILIES_JSON` with one v4 record, `RENDEZVOUS_IP`, etc.). Expected: no differences.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Generate agent-config nmstate per active family"
```

---

### Task 8: Resolved-config display and replay command

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (`print_resolved_config` ~1232-1252; `print_replay_command` ~1253-1330)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `ACTIVE_V4`/`ACTIVE_V6`, `IPV6_WITH_PREFIX`, `IPV6_GATEWAY`, `IP_FAMILY_OVERRIDE`, `CLUSTER_NETWORKS`, `SERVICE_NETWORKS`.
- Produces: display includes IPv6 address/gateway lines when v6 active; `print_replay_command` emits `--ipv6-with-prefix`, `--ipv6-gateway`, `--ip-family`, `--cluster-network`, `--service-network` when set, so the printed command reproduces the run.

- [ ] **Step 1: Write the failing test**

```bash
test_print_replay_command_includes_ipv6_flags() {
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_NAME="hetzner-sno-prepare-pxe.sh"
    NODE_HOSTNAME="node.example.com"; SSH_PUBLIC_KEY_FILE="/root/id.pub"
    DEFAULT_IFACE="eth0"
    IP_WITH_PREFIX="192.0.2.10/24"; GATEWAY="192.0.2.1"
    ACTIVE_V4=1; ACTIVE_V6=1
    IPV6_WITH_PREFIX="2a01:db8::1/64"; IPV6_GATEWAY="fe80::1"
    IP_FAMILY_OVERRIDE="dual"
    DNS_SERVERS=("8.8.8.8"); INSTALL_DISK="/dev/nvme0n1"
    ARTIFACT_DIR="/root"; BIN_DIR="/usr/local/bin"
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    out="$(print_replay_command)"
    [[ "$out" == *"--ipv6-with-prefix 2a01:db8::1/64"* ]] || { echo "no v6 prefix: $out"; exit 1; }
    [[ "$out" == *"--ipv6-gateway fe80::1"* ]] || { echo "no v6 gw"; exit 1; }
    [[ "$out" == *"--ip-family dual"* ]] || { echo "no family"; exit 1; }
  '
}
```

Register near the end (~759):

```bash
run_test "print_replay_command includes ipv6 flags" test_print_replay_command_includes_ipv6_flags
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'replay_command includes ipv6'`
Expected: `not ok`.

- [ ] **Step 3: Extend `print_resolved_config`**

After the IPv4 `Gateway:` line (1238), add conditional IPv6 lines. Insert after the `echo "  Gateway:           ${GATEWAY}"` line:

```bash
  if [[ "${ACTIVE_V6:-0}" -eq 1 ]]; then
    echo "  IPv6/prefix:       ${IPV6_WITH_PREFIX}"
    echo "  IPv6 gateway:      ${IPV6_GATEWAY}"
  fi
  if [[ -n "${IP_FAMILY_OVERRIDE:-}" ]]; then
    echo "  IP family:         ${IP_FAMILY_OVERRIDE}"
  fi
```

(Guard the IPv4 `IP/prefix:` and `Gateway:` lines so a v6-only run does not print empty values: wrap lines 1235-1236 in `if [[ "${ACTIVE_V4:-1}" -eq 1 ]]; then ... fi`.)

- [ ] **Step 4: Extend `print_replay_command`**

After the IPv4 `--gateway` line is appended (1286), add:

```bash
  if [[ "${ACTIVE_V6:-0}" -eq 1 ]]; then
    lines+=("  --ipv6-with-prefix $(printf '%q' "$IPV6_WITH_PREFIX") \\")
    lines+=("  --ipv6-gateway $(printf '%q' "$IPV6_GATEWAY") \\")
  fi
  if [[ -n "${IP_FAMILY_OVERRIDE:-}" ]]; then
    lines+=("  --ip-family $(printf '%q' "$IP_FAMILY_OVERRIDE") \\")
  fi
  local _cn _sn
  for _cn in "${CLUSTER_NETWORKS[@]:-}"; do
    [[ -n "$_cn" ]] && lines+=("  --cluster-network $(printf '%q' "$_cn") \\")
  done
  for _sn in "${SERVICE_NETWORKS[@]:-}"; do
    [[ -n "$_sn" ]] && lines+=("  --service-network $(printf '%q' "$_sn") \\")
  done
```

Also guard the IPv4 `--ip-with-prefix`/`--gateway` lines (1285-1286) with `if [[ "${ACTIVE_V4:-1}" -eq 1 ]]; then ... fi` so a v6-only replay omits them.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'replay_command includes ipv6'`
Expected: `ok`.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Show and replay IPv6/dual-stack configuration"
```

---

### Task 9: Interactive prompts and config persistence

**Files:**
- Modify: `hetzner-sno-prepare-pxe.sh` (`prompt_for_missing_config` ~468-472; `save_config` ~159-190; `load_saved_config` consumers)
- Test: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: `_SAVED` map, `prompt_optional_value`.
- Produces: persisted keys `IPV6_WITH_PREFIX_OVERRIDE`, `IPV6_GATEWAY_OVERRIDE`, `IP_FAMILY_OVERRIDE` in the config file; interactive prompts for the IPv6 address, IPv6 gateway, and IP family.

- [ ] **Step 1: Write the failing test**

```bash
test_save_config_persists_ipv6_fields() {
  local dir status
  dir="$(mktemp -d)"
  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    CONFIG_FILE="'"${dir}"'/config"
    OCP_VERSION="4.16.15"; PULL_SECRET_FILE="/x"; BASE_DOMAIN="e"; CLUSTER_NAME="sno"
    IPV6_WITH_PREFIX="2a01:db8::1/64"; IPV6_GATEWAY="fe80::1"; IP_FAMILY_OVERRIDE="dual"
    save_config
    grep -q "IPV6_WITH_PREFIX_OVERRIDE=2a01:db8::1/64" "'"${dir}"'/config" || { echo "no v6 prefix"; exit 1; }
    grep -q "IPV6_GATEWAY_OVERRIDE=fe80::1" "'"${dir}"'/config" || { echo "no v6 gw"; exit 1; }
    grep -q "IP_FAMILY_OVERRIDE=dual" "'"${dir}"'/config" || { echo "no family"; exit 1; }
  '
  status=$?
  rm -rf "${dir}"
  return "${status}"
}
```

Register near the end (~759):

```bash
run_test "save_config persists ipv6 fields" test_save_config_persists_ipv6_fields
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'persists ipv6'`
Expected: `not ok`.

- [ ] **Step 3: Persist the new fields in `save_config`**

In `save_config`, add local resolution near the other locals (after line 165):

```bash
  local ipv6="${IPV6_WITH_PREFIX:-${IPV6_WITH_PREFIX_OVERRIDE:-}}"
  local ipv6_gw="${IPV6_GATEWAY:-${IPV6_GATEWAY_OVERRIDE:-}}"
  local ipfamily="${IP_FAMILY_OVERRIDE:-}"
```

And append to the heredoc (after the `GATEWAY_OVERRIDE=` line, 185):

```bash
IPV6_WITH_PREFIX_OVERRIDE=${ipv6}
IPV6_GATEWAY_OVERRIDE=${ipv6_gw}
IP_FAMILY_OVERRIDE=${ipfamily}
```

- [ ] **Step 4: Add interactive prompts**

In `prompt_for_missing_config`, after the IPv4 gateway prompt (line 471) add:

```bash
  prompt_optional_value IPV6_WITH_PREFIX_OVERRIDE "IPv6 address with prefix" "${_SAVED[IPV6_WITH_PREFIX_OVERRIDE]:-}"
  prompt_optional_value IPV6_GATEWAY_OVERRIDE "IPv6 gateway" "${_SAVED[IPV6_GATEWAY_OVERRIDE]:-}"
  prompt_optional_value IP_FAMILY_OVERRIDE "IP family (v4, v6, dual; blank = auto)" "${_SAVED[IP_FAMILY_OVERRIDE]:-}"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'persists ipv6'`
Expected: `ok`.

- [ ] **Step 6: Run full suite**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Prompt for and persist IPv6/dual-stack settings"
```

---

### Task 10: Documentation

**Files:**
- Modify: `README.md`, `COMPARISON.md`

**Interfaces:** none (docs only).

- [ ] **Step 1: Document the flags and examples in README.md**

Find the section that lists the CLI options / networking examples (search `--ip-with-prefix`). Add the IPv6/dual-stack flags (`--ipv6-with-prefix`, `--ipv6-gateway`, `--ip-family`, `--cluster-network`, `--service-network`) with one-line descriptions matching the usage text from Task 1, and add two runnable examples:

```bash
# IPv6-only, autodiscovering the prefix and gateway, proposing <prefix>::1
./hetzner-sno-prepare-pxe.sh --ip-family v6 4.16.15 /root/pull-secret.json example.com sno

# Dual-stack with an explicit IPv6 address
./hetzner-sno-prepare-pxe.sh \
  --ip-with-prefix 192.0.2.10/24 --gateway 192.0.2.1 \
  --ipv6-with-prefix 2a01:db8::1/64 --ipv6-gateway fe80::1 \
  4.16.15 /root/pull-secret.json example.com sno
```

Add a short note: IPv6 cluster/service networks default to ULA `fd01::/48` and `fd02::/112`; override with `--cluster-network` / `--service-network`. Dual-stack is IPv4-primary.

- [ ] **Step 2: Update COMPARISON.md**

In the feature list, mark IPv6 / dual-stack networking as supported (it was previously IPv4-only). Keep the existing table/format.

- [ ] **Step 3: Run full suite (sanity)**

Run: `bash tests/test-hetzner-sno-prepare-pxe.sh`
Expected: all `ok -`, exit 0 (docs don't affect tests; confirms nothing regressed).

- [ ] **Step 4: Commit**

```bash
git add README.md COMPARISON.md
git commit -m "Document IPv6 and dual-stack support"
```

---

## Self-Review

**Spec coverage** (each spec section → task):
- Selectable per-run family (v4/v6/dual) → Tasks 1, 4.
- Hybrid family selection + validation → Tasks 1 (`--ip-family`), 2 (`validate_ip_family`), 4 (inference/default).
- IPv4-only auto-detect default + byte-stable output → Task 4 (default), Tasks 6 & 7 (byte-stability guards + diff steps).
- IPv6 autodiscovery (`<prefix>::1`, gateway, `fe80::1`) → Task 3.
- Cluster/service ULA defaults + override flags → Tasks 1 (flags), 6 (generation).
- Normalized per-family model (approach B) → Task 4 (`build_net_families_json`, `NET_FAMILIES_JSON`).
- DNS union / per-family fallback → Task 5.
- install-config generation → Task 6.
- agent-config generation (nmstate `ipv4:`/`ipv6:`, routes, `autoconf: false`, rendezvousIP) → Task 7.
- Display + replay flags → Task 8.
- Prompts + persistence → Task 9.
- Edge cases (link-local gw, skip SLAAC, hostPrefix parsing, empty-DNS per family) → Tasks 3, 5, 6.
- Documentation → Task 10.
- Test matrix from spec → covered across Tasks 1-9 (IPv4 byte-identical, IPv6-only, dual-stack, discovery, hybrid validation, DNS filter).

**Placeholder scan:** no TBD/TODO; every code step shows complete bash/Python; every test step shows the full test body and registration.

**Type/name consistency:** globals are consistent across tasks — `NET_FAMILIES_JSON`, `ACTIVE_V4`/`ACTIVE_V6`, `IPV6_WITH_PREFIX`/`IPV6_GATEWAY`, `IPV6_WITH_PREFIX_OVERRIDE`/`IPV6_GATEWAY_OVERRIDE`/`IP_FAMILY_OVERRIDE`, `CLUSTER_NETWORKS`/`SERVICE_NETWORKS`. Function names consistent: `validate_ip_family`, `discover_ipv6`, `propose_ipv6_host`, `build_net_families_json`, `resolve_dns_servers`, `filter_dns_by_active_families`. Record schema `{family,ip,prefix,gateway,cidr}` identical in producer (Task 4) and both consumers (Tasks 6, 7).

**Note on inter-task coupling:** Task 4 introduces a call to `resolve_dns_servers` that Task 5 implements; Task 4 Step 4 documents the temporary inline fallback so each task leaves the script runnable and the suite green.
