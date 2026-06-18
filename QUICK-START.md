# Quick Start: Agent-Based SNO on Hetzner Rescue

**WARNING**: Experimental, not supported by Red Hat or Hetzner. Use at your own risk. See [README.md](README.md) for full details.

## Prerequisites

- A Hetzner dedicated server booted into [Rescue System](https://docs.hetzner.com/robot/dedicated-server/troubleshooting/hetzner-rescue-system/) (Debian 12).
- SSH access as root (DHCP is already working if you got in).
- Target disks wiped.
- A [pull secret](https://console.redhat.com/openshift/install/pull-secret) saved somewhere under `$HOME` as `pull-secret.json` (or `pull-secret.txt`).
- Hetzner Robot firewall configured (see [FIREWALL.md](FIREWALL.md)).

## Steps

SSH into the rescue host, then:

```bash
git clone https://github.com/tomazb/hetzner-sno-provision-host.git
cd hetzner-sno-provision-host
./hetzner-sno-prepare-pxe.sh --interactive
```

The script will prompt you for everything it needs: OpenShift version, pull secret path, base domain, cluster name, hostname, SSH public key, and install disk (if the server has more than one).

Right away, before any other prompt, the script reports whether it found a pull secret and an SSH public key, so you know immediately if something is missing. It automatically searches `$HOME` for `pull-secret.*` files and SSH `*.pub` keys. If one match is found it is offered as the default; if several are found you get a numbered menu to pick from. If none are found, a warning is printed and you can type the path manually.

## Save credentials before rebooting

After PXE files are generated, the script prints:

- **kubeadmin password** -- copy it now.
- **kubeconfig** content (between `--- kubeconfig start ---` and `--- kubeconfig end ---`) -- save it to `~/.kube/config` on your workstation.

These are lost after the next step replaces the rescue environment.

## Follow the script output

At the end, the script tells you exactly what to run next, for example:

```
Boot artifacts are in /root. You can now run:
  ./hetzner-sno-provision-host-agentbased.sh --artifact-dir /root
to kexec into the agent installer.
```

It also prints a **replay command** that you can copy for next time to skip all interactive prompts.

Run the command it suggests. Confirm when prompted. `kexec` replaces the running kernel -- **your SSH session will drop immediately**. This is expected.

## What happens next

- The server boots into the RHCOS agent installer.
- OpenShift installation proceeds automatically (30-60+ minutes).
- After ~5 minutes you can SSH in as `core`:

```bash
ssh core@<SERVER_IP>
```

- Monitor from your workstation using the saved kubeconfig:

```bash
export KUBECONFIG=~/.kube/config
oc get nodes
oc get clusteroperators
```

- **SSH host keys change** with every rescue boot and again when RHCOS takes over. Expect `REMOTE HOST IDENTIFICATION HAS CHANGED` warnings -- clear the old key with `ssh-keygen -R <SERVER_IP>`.
- If the network is misconfigured, you may need a [Hetzner KVM console](https://docs.hetzner.com/robot/dedicated-server/maintenance/kvm-console/).

## More information

See [README.md](README.md) for the full reference, assisted installer workflow, network overrides, non-interactive automation flags, local testing, and additional warnings.
