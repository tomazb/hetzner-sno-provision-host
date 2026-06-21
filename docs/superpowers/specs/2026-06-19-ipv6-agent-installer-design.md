# IPv6 support for the agent-based installer

**Date:** 2026-06-19
**Status:** Design approved, pending spec review
**Target script:** `hetzner-sno-prepare-pxe.sh`

## Problem

The PXE preparation script (`hetzner-sno-prepare-pxe.sh`) generates the
OpenShift agent-based installer inputs (`install-config.yaml`,
`agent-config.yaml`) for a single-node OpenShift (SNO) host. Today it is
IPv4-only:

- `--ip-with-prefix` / `--gateway` / `--dns-server` validate IPv4 only.
- `resolve_network_config` detects the address via `ip -4`.
- `install-config.yaml` emits a single IPv4 `machineNetwork` CIDR and relies
  on the installer's implicit IPv4 `clusterNetwork`/`serviceNetwork` defaults.
- `agent-config.yaml` emits only an `ipv4:` nmstate block and a single
  `0.0.0.0/0` route.

Hetzner dedicated servers ship a routed IPv6 `/64`. Operators who want IPv6 (or
dual-stack) connectivity for the SNO node cannot express it through this
script.

Some groundwork already exists and is preserved:

- `filter_dns_by_family` already treats an address containing `:` as IPv6.
- `networkType` is `OVNKubernetes`, which supports IPv6 and dual-stack
  (OpenShiftSDN does not).

## Goals

- Allow a single run to configure the node as **IPv4-only**, **IPv6-only**, or
  **dual-stack** (selectable per run).
- Autodiscover IPv6 networking (prefix, gateway) and propose a stable static
  host address `<prefix>::1`, mirroring the interactive IPv4 flow.
- Preserve the existing IPv4-only behavior **byte-for-byte** when IPv6 is not
  requested (zero regression for existing users and replay commands).

## Non-goals

- Rewriting the networking layer into a separate sourced library (out of scope;
  high regression risk on a working script).
- DHCPv6 / SLAAC-managed addressing for the node. The node is configured with a
  static address (`autoconf: false`, `dhcp: false`), consistent with the
  current IPv4 static configuration.
- IPv6-primary dual-stack. Dual-stack is always IPv4-primary (see Decisions).

## Decisions

These were settled during brainstorming and are fixed for this design:

1. **Selectable per run.** A single run configures v4, v6, or dual.
2. **Hybrid family selection.** Family is inferred from the address flags
   present; an optional `--ip-family v4|v6|dual` flag forces and validates
   intent.
3. **IPv4-only is the auto-detect default.** A full auto-detect run (no address
   flags, no `--ip-family`) configures IPv4-only exactly as today.
4. **Cluster/service CIDRs:** OpenShift-recommended ULA defaults
   (`clusterNetwork fd01::/48` hostPrefix 64, `serviceNetwork fd02::/112`) with
   optional `--cluster-network` / `--service-network` override flags.
5. **Dual-stack is IPv4-primary.** IPv4 is listed first in every ordered list
   (`machineNetwork`, `clusterNetwork`, `serviceNetwork`); `rendezvousIP` is the
   node's IPv4 address. For a single v6 family, v6 is primary and `rendezvousIP`
   is the v6 address.
6. **Implementation approach B** (normalized per-family model), not a parallel
   IPv6 code path and not a full rewrite.

## Architecture

### Normalized per-family model

Networking is resolved once into an ordered list of family records. Each record:

```
family   : "v4" | "v6"
ip       : address without prefix (e.g. 2a01:4f8:abcd:1234::1)
prefix   : prefix length, int (e.g. 64)
gateway  : next-hop address (may be link-local fe80::1 for v6)
cidr     : machineNetwork CIDR, derived (e.g. 2a01:4f8:abcd:1234::/64)
```

Order: IPv4 first when present (primary), then IPv6. This single list is the
input to validation, both YAML generators, the DNS filter, the resolved-config
display, and the replay-command printer. The two inline Python heredocs receive
it as JSON and loop over it, so v4, v6, and dual all flow through one code path.

### Family selection logic (`resolve_network_config`)

1. If `--ip-family` is given, that is the requested set (`v4`, `v6`, `dual`).
2. Otherwise infer from address flags present:
   - `--ip-with-prefix` (IPv4) present → v4 active.
   - `--ipv6-with-prefix` present → v6 active.
   - both present → dual.
   - neither present → IPv4-only via auto-detect (unchanged default).
3. Hybrid validation (fail fast with a nonzero exit and actionable message):
   - `--ip-family dual` but only one family resolvable → die.
   - `--ip-family v6` but an IPv4 address flag was passed → die.
   - `--ip-family v4` but an IPv6 address flag was passed → die.
4. Build the ordered family list (IPv4 first).

### IPv6 autodiscovery (`discover_ipv6`)

Runs when v6 is requested and `--ipv6-with-prefix` was not given.

1. **Prefix discovery** (first hit wins):
   - On-link prefix from the route table:
     `ip -6 route show dev IFACE` → first non-`fe80::` `*/64` entry
     (`proto ra` or `proto kernel`).
   - Fallback: derive from an existing global `inet6` address —
     `ip_network(addr/len, strict=False).network`.
   - Prefix length taken as detected; default 64.
2. **Proposed host address** = network address + 1 →
   `<network>::1/<prefix>`, e.g. `2a01:4f8:abcd:1234::/64` proposes
   `2a01:4f8:abcd:1234::1/64`. This deliberately ignores the SLAAC/temporary
   address the OS auto-assigned, because those are unstable across reboots.
3. **Gateway discovery**:
   - `ip -6 route show default` → next-hop address (often link-local
     `fe80::1` on Hetzner; kept and paired with `next-hop-interface`).
   - If a default route exists but no explicit next-hop is parseable, fall back
     to `fe80::1`.
   - If no default route at all, die asking for `--ipv6-gateway`.

**Proposal surface:**

- Interactive prompts show the discovered v6 ip/prefix and gateway as the
  prefilled default (reusing the existing `prompt_optional_value` mechanism);
  the user accepts or edits.
- `--yes` / non-interactive runs accept the proposal silently.
- `--ipv6-with-prefix` / `--ipv6-gateway` always override discovery.

### Detection (IPv4 unchanged)

- v4 address: `ip -4 addr show dev IFACE` → first global `inet` (unchanged).
- v4 gateway: `ip -4 route show default` next-hop (unchanged).
- v6 detection is the `discover_ipv6` routine above; raw global address scan
  uses `ip -6 addr show dev IFACE scope global`, skipping `fe80::` link-local
  and `deprecated`/`temporary` (privacy-extension) addresses.
- MAC detection unchanged.

### Validation

Extends the existing Python `ipaddress` validation block:

- Each node address is parsed with `ipaddress.ip_interface`; its family must
  match the slot it came from (a v6 flag must yield a v6 address).
- Each gateway is parsed with `ipaddress.ip_address`; its family must match its
  address family.
- The `--ip-family` consistency checks (the hybrid die-checks) are enforced
  here.
- `machineNetwork` CIDR per family is derived via
  `ip_interface(...).network` (the existing one-liner, now run per family).

### DNS handling

A single combined DNS list is collected as today. `filter_dns_by_family` is run
for each active family and the results are unioned:

- Dual-stack keeps resolvers of both families.
- Single family drops the mismatched-family resolvers (current behavior
  preserved).
- The empty-DNS fallback is family-aware and emits a fallback resolver per
  active family (extends the existing IPv4/IPv6 fallback logic).

## YAML generation

### `install-config.yaml`

The generator receives the family list plus cluster/service overrides as JSON
and loops:

```yaml
networking:
  networkType: OVNKubernetes
  clusterNetwork:                 # emitted only when v6 active OR override given
  - cidr: 10.128.0.0/14           #   v4 present
    hostPrefix: 23
  - cidr: fd01::/48               #   v6 present
    hostPrefix: 64
  serviceNetwork:                 # emitted only when v6 active OR override given
  - 172.30.0.0/16                 #   v4 present
  - fd02::/112                    #   v6 present
  machineNetwork:                 # always emitted, ordered primary-first
  - cidr: <v4 cidr>
  - cidr: <v6 cidr>
```

**Regression guard:** `clusterNetwork`/`serviceNetwork` are emitted only when
v6 is active or an override flag is given. For an IPv4-only run with no
overrides they are omitted (installer applies the same implicit defaults as
today), keeping the IPv4-only `install-config.yaml` byte-identical.

### `agent-config.yaml`

Same JSON-in approach. The generator loops the family list to emit nmstate:

```yaml
networkConfig:
  interfaces:
  - name: <iface>
    type: ethernet
    state: up
    mac-address: <mac>
    ipv4:                         # emitted if v4 active
      enabled: true
      address:
      - ip: <v4 ip>
        prefix-length: <v4 prefix>
      dhcp: false
    ipv6:                         # emitted if v6 active
      enabled: true
      address:
      - ip: <v6 ip>
        prefix-length: <v6 prefix>
      dhcp: false
      autoconf: false             # static, no SLAAC
  dns-resolver:
    config:
      server: [<unioned, family-filtered list>]
  routes:
    config:
    - destination: 0.0.0.0/0      # if v4
      next-hop-address: <v4 gw>
      next-hop-interface: <iface>
      table-id: 254
    - destination: ::/0           # if v6
      next-hop-address: <v6 gw>
      next-hop-interface: <iface>
      table-id: 254
```

`rendezvousIP` is the primary family's node IP (IPv4 in dual-stack; the v6
address for a v6-only run).

**Regression guard:** for an IPv4-only run the emitted block is byte-identical
to today (no `ipv6:` block, single `0.0.0.0/0` route).

## CLI surface (new flags)

| Flag | Purpose |
|------|---------|
| `--ipv6-with-prefix <cidr>` | IPv6 address/prefix for the node (overrides discovery) |
| `--ipv6-gateway <ip>` | IPv6 default gateway (overrides discovery) |
| `--ip-family v4\|v6\|dual` | Force and validate the active family set (hybrid) |
| `--cluster-network <cidr[,hostPrefix]>` | Override `clusterNetwork` (repeatable) |
| `--service-network <cidr>` | Override `serviceNetwork` (repeatable) |

Existing flags are unchanged: `--ip-with-prefix` / `--gateway` remain IPv4;
`--dns-server` already accepts either family. The replay-command printer emits
whichever flags were active for the run.

## Testing

Follows the existing shell-test pattern in
`tests/test-hetzner-sno-prepare-pxe.sh`.

- **IPv4-only auto-detect:** generated files are byte-identical to current
  output (regression guard).
- **IPv6-only:** `agent-config.yaml` has an `ipv6:` block, a `::/0` route, and
  no `ipv4:` block; `install-config.yaml` carries v6 cluster/service/machine
  networks; `rendezvousIP` is the v6 address.
- **Dual-stack:** both nmstate blocks, both routes, ordered v4-first; v4 and v6
  cluster/service/machine entries; `rendezvousIP` is the v4 address; DNS union
  keeps both families.
- **IPv6 prefix discovery from RA route:** proposes `<net>::1`.
- **IPv6 prefix discovery fallback** from an existing global address.
- **Link-local `fe80::1` v6 gateway** preserved with `next-hop-interface`.
- **`--ipv6-with-prefix` overrides** the `::1` proposal.
- **Discovery finds no `/64`:** dies with an actionable message pointing at
  `--ipv6-with-prefix`.
- **Hybrid validation:** `--ip-family dual` + one address → nonzero exit;
  `--ip-family v6` + a v4 address → nonzero exit.
- **DNS family filter:** dual keeps mixed-family resolvers; single drops the
  mismatched ones (existing test extended).
- **v6 detection skips `fe80::` link-local** when selecting the global prefix.

## Edge cases

- Link-local v6 gateway (`fe80::1`) is valid for nmstate when paired with
  `next-hop-interface`; kept verbatim.
- SLAAC / privacy / temporary v6 addresses are skipped during discovery in
  favor of the deterministic `<prefix>::1`.
- `--cluster-network` parses an optional `,hostPrefix` suffix; `hostPrefix`
  defaults to 23 for v4 and 64 for v6 when omitted.
- The empty-DNS fallback emits a resolver per active family.
```
