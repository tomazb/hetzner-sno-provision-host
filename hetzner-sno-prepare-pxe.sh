#!/bin/bash

# Prepare PXE files for agent-based OpenShift SNO installation on a Hetzner
# rescue environment (Debian 12).
#
# This script:
#   1. Installs Rust/Cargo and nmstatectl (required by openshift-install to
#      validate the NMState YAML schema in agent-config.yaml).
#   2. Downloads the OpenShift CLI (oc) and openshift-install binary.
#   3. Inspects the rescue machine's network and generates install-config.yaml
#      and agent-config.yaml.
#   4. Runs "openshift-install agent create pxe-files".
#   5. Copies the resulting boot artifacts to /root so that
#      hetzner-sno-provision-host-agentbased.sh can boot them with kexec.
#
# Usage:
#   ./hetzner-sno-prepare-pxe.sh <ocp_version> <pull_secret_file> <base_domain> [cluster_name] [rendezvous_ip]
#
# Arguments:
#   ocp_version      - OpenShift version to install, e.g. 4.16.15
#   pull_secret_file - Path to a file containing your Red Hat pull secret JSON
#   base_domain      - Base DNS domain for the cluster, e.g. example.com
#   cluster_name     - (optional) Cluster name, defaults to "sno"
#   rendezvous_ip    - (optional) IP to use as rendezvousIP; auto-detected if omitted
#
# After this script completes, run hetzner-sno-provision-host-agentbased.sh to
# kexec into the agent installer kernel.

set -euo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
OCP_VERSION="${1:-}"
PULL_SECRET_FILE="${2:-}"
BASE_DOMAIN="${3:-}"
CLUSTER_NAME="${4:-sno}"
OVERRIDE_IP="${5:-}"

if [[ -z "$OCP_VERSION" || -z "$PULL_SECRET_FILE" || -z "$BASE_DOMAIN" ]]; then
  echo "Usage: $0 <ocp_version> <pull_secret_file> <base_domain> [cluster_name] [rendezvous_ip]"
  echo "Example: $0 4.16.15 /root/pull-secret.json example.com sno"
  exit 1
fi

if [[ ! -f "$PULL_SECRET_FILE" ]]; then
  echo "ERROR: Pull secret file not found: $PULL_SECRET_FILE"
  exit 1
fi

# Validate that the pull secret is valid JSON
if ! python3 -c "import json, sys; json.load(open('${PULL_SECRET_FILE}'))" 2>/dev/null; then
  echo "ERROR: Pull secret file does not contain valid JSON: $PULL_SECRET_FILE"
  exit 1
fi

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
WORKDIR="/root/ocp-prepare"
INSTALL_DIR="${WORKDIR}/install"
mkdir -p "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# Step 1: Install Rust/Cargo and nmstatectl
# ---------------------------------------------------------------------------
echo "=== Step 1: Installing Rust/Cargo and nmstatectl ==="

CARGO_ENV="$HOME/.cargo/env"

if ! command -v cargo &>/dev/null; then
  echo "  Installing Rust toolchain..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi

# shellcheck source=/dev/null
source "$CARGO_ENV"
export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v nmstatectl &>/dev/null; then
  echo "  Installing nmstatectl via cargo..."
  cargo install nmstatectl
fi

echo "  nmstatectl: $(nmstatectl --version)"

# ---------------------------------------------------------------------------
# Step 2: Download OpenShift tools
# ---------------------------------------------------------------------------
echo "=== Step 2: Downloading OpenShift tools ==="

OCP_MIRROR="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}"

if ! command -v oc &>/dev/null; then
  echo "  Downloading oc ${OCP_VERSION}..."
  curl -L -f -o "${WORKDIR}/oc.tar.gz" "${OCP_MIRROR}/openshift-client-linux.tar.gz"
  tar -xzf "${WORKDIR}/oc.tar.gz" -C "${WORKDIR}" oc
  mv "${WORKDIR}/oc" /usr/local/bin/oc
  rm -f "${WORKDIR}/oc.tar.gz"
fi

if ! command -v openshift-install &>/dev/null; then
  echo "  Downloading openshift-install ${OCP_VERSION}..."
  curl -L -f -o "${WORKDIR}/openshift-install.tar.gz" "${OCP_MIRROR}/openshift-install-linux.tar.gz"
  tar -xzf "${WORKDIR}/openshift-install.tar.gz" -C "${WORKDIR}" openshift-install
  mv "${WORKDIR}/openshift-install" /usr/local/bin/openshift-install
  rm -f "${WORKDIR}/openshift-install.tar.gz"
fi

echo "  oc:                 $(oc version --client 2>/dev/null | head -1)"
echo "  openshift-install:  $(openshift-install version 2>/dev/null | head -1)"

# ---------------------------------------------------------------------------
# Step 3: Inspect machine network
# ---------------------------------------------------------------------------
echo "=== Step 3: Inspecting machine network ==="

# Interface used for the default route
DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [[ -z "$DEFAULT_IFACE" ]]; then
  echo "ERROR: Could not determine the default network interface."
  exit 1
fi

# IP address and prefix length (e.g. "192.168.1.10/24")
IP_WITH_PREFIX=$(ip -4 addr show dev "$DEFAULT_IFACE" | awk '/inet / {print $2}' | head -1)
if [[ -z "$IP_WITH_PREFIX" ]]; then
  echo "ERROR: Could not determine the IPv4 address on ${DEFAULT_IFACE}."
  exit 1
fi
IP_ADDR=$(echo "$IP_WITH_PREFIX" | cut -d/ -f1)
PREFIX_LEN=$(echo "$IP_WITH_PREFIX" | cut -d/ -f2)

# Default gateway
GATEWAY=$(ip route show default | awk '/default/ {print $3}' | head -1)
if [[ -z "$GATEWAY" ]]; then
  echo "ERROR: Could not determine the default gateway."
  exit 1
fi

# MAC address
MAC_ADDR=$(ip link show "$DEFAULT_IFACE" | awk '/link\/ether/ {print $2}')

# DNS servers from /etc/resolv.conf (up to 3)
DNS_SERVERS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | head -3)
if [[ -z "$DNS_SERVERS" ]]; then
  DNS_SERVERS="8.8.8.8
8.8.4.4"
fi

# Machine network CIDR (network address of the primary interface)
MACHINE_NETWORK=$(python3 -c "
import ipaddress
net = ipaddress.ip_interface('${IP_WITH_PREFIX}').network
print(net)
")

# Rendezvous IP: use override if provided, otherwise use detected IP
RENDEZVOUS_IP="${OVERRIDE_IP:-${IP_ADDR}}"

# Hostname
NODE_HOSTNAME=$(hostname -f 2>/dev/null || hostname)

echo "  Interface:       ${DEFAULT_IFACE}"
echo "  IP/prefix:       ${IP_WITH_PREFIX}"
echo "  Gateway:         ${GATEWAY}"
echo "  MAC:             ${MAC_ADDR}"
echo "  Machine network: ${MACHINE_NETWORK}"
echo "  Rendezvous IP:   ${RENDEZVOUS_IP}"
echo "  Hostname:        ${NODE_HOSTNAME}"
echo "  DNS servers:     $(echo "$DNS_SERVERS" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# Step 4: Generate SSH key if needed
# ---------------------------------------------------------------------------
SSH_KEY_FILE="${HOME}/.ssh/id_rsa"
if [[ ! -f "${SSH_KEY_FILE}" ]]; then
  echo "=== Generating SSH key ==="
  mkdir -p "${HOME}/.ssh"
  ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_FILE}" -N "" -C "root@$(hostname)"
fi
SSH_PUB_KEY=$(cat "${SSH_KEY_FILE}.pub")

# ---------------------------------------------------------------------------
# Step 5: Generate install-config.yaml
# ---------------------------------------------------------------------------
echo "=== Step 4: Generating install-config.yaml ==="

# Use Python3 to write install-config.yaml so the pull secret JSON is handled
# safely (it may contain characters that would break bash heredoc quoting).
python3 - <<PYEOF
import json

# Normalise pull secret to compact single-line JSON
with open("${PULL_SECRET_FILE}") as f:
    pull_secret = json.dumps(json.load(f))

with open("${INSTALL_DIR}/install-config.yaml", "w") as f:
    f.write("apiVersion: v1\n")
    f.write("baseDomain: ${BASE_DOMAIN}\n")
    f.write("metadata:\n")
    f.write("  name: ${CLUSTER_NAME}\n")
    f.write("networking:\n")
    f.write("  networkType: OVNKubernetes\n")
    f.write("  machineNetwork:\n")
    f.write("  - cidr: ${MACHINE_NETWORK}\n")
    f.write("compute:\n")
    f.write("- name: worker\n")
    f.write("  replicas: 0\n")
    f.write("controlPlane:\n")
    f.write("  name: master\n")
    f.write("  replicas: 1\n")
    f.write("platform:\n")
    f.write("  none: {}\n")
    f.write("pullSecret: '" + pull_secret + "'\n")
    f.write("sshKey: '${SSH_PUB_KEY}'\n")

print("  Written: ${INSTALL_DIR}/install-config.yaml")
PYEOF

# ---------------------------------------------------------------------------
# Step 6: Generate agent-config.yaml
# ---------------------------------------------------------------------------
echo "=== Step 5: Generating agent-config.yaml ==="

# Build DNS server YAML lines
DNS_YAML=""
while IFS= read -r dns; do
  DNS_YAML="${DNS_YAML}            - ${dns}"$'\n'
done <<< "$DNS_SERVERS"

cat > "${INSTALL_DIR}/agent-config.yaml" <<YAML
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${RENDEZVOUS_IP}
hosts:
  - hostname: ${NODE_HOSTNAME}
    interfaces:
      - name: ${DEFAULT_IFACE}
        macAddress: ${MAC_ADDR}
    rootDeviceHints:
      deviceName: /dev/sda
    networkConfig:
      interfaces:
        - name: ${DEFAULT_IFACE}
          type: ethernet
          state: up
          mac-address: ${MAC_ADDR}
          ipv4:
            enabled: true
            address:
              - ip: ${IP_ADDR}
                prefix-length: ${PREFIX_LEN}
            dhcp: false
      dns-resolver:
        config:
          server:
${DNS_YAML}      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: ${GATEWAY}
            next-hop-interface: ${DEFAULT_IFACE}
            table-id: 254
YAML

echo "  Written: ${INSTALL_DIR}/agent-config.yaml"

# ---------------------------------------------------------------------------
# Step 7: Create PXE files
# ---------------------------------------------------------------------------
echo "=== Step 6: Running openshift-install agent create pxe-files ==="

# openshift-install consumes and overwrites the config files, so keep copies
cp "${INSTALL_DIR}/install-config.yaml" "${WORKDIR}/install-config.yaml.bak"
cp "${INSTALL_DIR}/agent-config.yaml"   "${WORKDIR}/agent-config.yaml.bak"

openshift-install agent create pxe-files --dir "${INSTALL_DIR}" --log-level info

# ---------------------------------------------------------------------------
# Step 8: Copy boot artifacts to /root
# ---------------------------------------------------------------------------
echo "=== Step 7: Copying boot artifacts to /root ==="

BOOT_ARTIFACTS_DIR="${INSTALL_DIR}/boot-artifacts"
if [[ ! -d "$BOOT_ARTIFACTS_DIR" ]]; then
  echo "ERROR: boot-artifacts directory not found at ${BOOT_ARTIFACTS_DIR}"
  echo "  openshift-install may have placed them elsewhere. Check ${INSTALL_DIR}:"
  ls -la "${INSTALL_DIR}"
  exit 1
fi

cp "${BOOT_ARTIFACTS_DIR}/"* /root/
echo "  Copied files to /root:"
ls -lh /root/agent.x86_64-* 2>/dev/null || ls -lh /root/

echo ""
echo "=== Done! ==="
echo "Boot artifacts are in /root. You can now run:"
echo "  ./hetzner-sno-provision-host-agentbased.sh"
echo "to kexec into the agent installer."
