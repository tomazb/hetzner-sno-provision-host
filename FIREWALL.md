# Hetzner Robot Firewall Configuration

Configure the Hetzner Robot firewall **before** deploying SNO. The node is exposed from the moment `kexec` boots into RHCOS, so the firewall should already be in place.

The Hetzner Robot firewall is a free [stateless packet filter](https://docs.hetzner.com/robot/dedicated-server/firewall/) configured at the switch port. It inspects individual packet headers without tracking connection state, which means return traffic for server-initiated connections must be explicitly allowed. Rules are evaluated top to bottom -- the first matching rule is applied and subsequent rules are skipped. Packets that match no rule are discarded.

## Where to configure

Go to [https://robot.hetzner.com/server](https://robot.hetzner.com/server), select your server, and open the **Firewall** tab.

## Global settings

Enable these two checkboxes before adding rules:

- **Filter IPv6 packets**: Enabled. Blocks all IPv6 traffic unless explicit IPv6 rules are added. SNO on Hetzner typically uses IPv4 only.
- **Hetzner Services**: Enabled. Allows Hetzner infrastructure services (Rescue System, DHCP, DNS, and System Monitor) without needing explicit incoming rules.

## Outgoing rules

A single rule allowing all outgoing traffic is sufficient. The SNO node needs unrestricted egress for container image pulls (quay.io, registry.redhat.io), Red Hat API access, DNS queries, NTP, and cluster telemetry.

- **Name**: Allow all outgoing
- **Protocol**: `*`
- **Action**: accept
- All other fields left empty.

## Incoming rules

Incoming rules are the core of this configuration. The rules below are listed in recommended priority order (first rule = highest priority). You can use up to 10 incoming rules.

### Rule 1 -- Trusted IP access

Allow all traffic from your workstation, VPN, or management network. This covers SSH (22), Kubernetes API (6443), OpenShift console (443), and everything else from known IPs.

- **Name**: Trusted admin
- **Source IP**: `<your IP or CIDR, e.g. 203.0.113.10/32>`
- **Protocol**: `*`
- **Action**: accept

Add one rule per trusted IP or CIDR block. If you have multiple management locations, each one consumes one of the 10-rule budget.

### Rule 2 -- ICMP

Allow ICMP for ping, path MTU discovery, and destination-unreachable messages.

- **Name**: ICMP
- **Protocol**: icmp
- **Action**: accept

### Rule 3 -- TCP return traffic (established connections)

Because the firewall is stateless, return packets for server-initiated outgoing TCP connections (image pulls, API calls, telemetry) must be explicitly allowed. These responses arrive at ephemeral destination ports with the ACK flag set.

- **Name**: TCP established
- **Destination port**: 32768-65535
- **Protocol**: tcp
- **TCP flags**: ack
- **Action**: accept

### Rule 4 -- UDP return traffic

Return packets for outgoing UDP traffic (DNS responses, NTP responses) also arrive at ephemeral destination ports. Restricting to the ephemeral range avoids exposing all UDP ports.

- **Name**: UDP responses
- **Destination port**: 32768-65535
- **Protocol**: udp
- **Action**: accept

### Optional rules

These are only needed if the SNO node should accept traffic from IPs beyond your trusted list. Each one consumes one of the 10-rule budget.

**Public HTTPS and HTTP routes** -- if the cluster will serve OpenShift routes (applications, console) to the public internet:

- **Name**: Public HTTPS
- **Destination port**: 443
- **Protocol**: tcp
- **Action**: accept

<!-- -->

- **Name**: Public HTTP
- **Destination port**: 80
- **Protocol**: tcp
- **Action**: accept

**Public Kubernetes API** -- if the API server should be reachable beyond the trusted IP list. Consider the security implications before enabling this.

- **Name**: Public API
- **Destination port**: 6443
- **Protocol**: tcp
- **Action**: accept

## Rule ordering

Rules are evaluated top to bottom. The first matching rule decides the packet's fate.

1. Place the trusted-admin rule(s) first so all traffic from known IPs is accepted before more specific rules are checked.
2. Place ICMP and return-traffic rules (TCP ACK, UDP ephemeral) next to keep basic connectivity working for all sources.
3. Place optional public-access rules last. They only match traffic not already handled by earlier rules.
4. Any packet that matches no rule is discarded.

## Important notes

- The firewall takes approximately 20-30 seconds to apply after saving.
- Maximum 10 rules per direction -- plan your rule budget. Each trusted IP/CIDR consumes one rule.
- The **Hetzner Services** checkbox only works for incoming rules. If you also filter outgoing traffic, you need explicit outgoing rules for Hetzner DNS servers and other infrastructure services.
- After installation completes, review your rules and tighten them if possible.
- RHCOS does not ship `firewalld`. For more granular host-level ingress filtering after installation, the [Ingress Node Firewall Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/networking_operators/ingress-node-firewall-operator) can be enabled on the cluster. The Hetzner Robot firewall complements it as a network-level perimeter applied at the switch port.

## Example: minimal single-admin configuration

Global settings:

- Filter IPv6 packets: **Enabled**
- Hetzner Services: **Enabled**

Outgoing rules:

| # | Name | Protocol | Action |
|---|------|----------|--------|
| 1 | Allow all outgoing | `*` | accept |

Incoming rules:

| # | Name | Source IP | Dst Port | Protocol | TCP Flags | Action |
|---|------|----------|----------|----------|-----------|--------|
| 1 | Trusted admin | 203.0.113.10/32 | | `*` | | accept |
| 2 | ICMP | | | icmp | | accept |
| 3 | TCP established | | 32768-65535 | tcp | ack | accept |
| 4 | UDP responses | | 32768-65535 | udp | | accept |

Replace `203.0.113.10/32` with your actual IP address or CIDR block. All other incoming traffic is discarded.
