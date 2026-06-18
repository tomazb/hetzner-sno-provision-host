# Example Session: Agent-Based SNO Install on Hetzner Rescue

This is a realistic example of what a full interactive session looks like, from SSH into Hetzner Rescue to kexec into the agent installer.

The server in this example has three NVMe drives and a single network interface.

## 1. Clone and run the prepare script

```console
root@rescue ~ # git clone https://github.com/tomazb/hetzner-sno-provision-host.git
Cloning into 'hetzner-sno-provision-host'...
remote: Enumerating objects: 142, done.
remote: Counting objects: 100% (142/142), done.
remote: Compressing objects: 100% (89/89), done.
remote: Total 142 (delta 68), reused 112 (delta 45), pack-reused 0
Receiving objects: 100% (142/142), 48.21 KiB | 2.41 MiB/s, done.
Resolving deltas: 100% (68/68), done.

root@rescue ~ # cd hetzner-sno-provision-host

root@rescue ~/hetzner-sno-provision-host # ./hetzner-sno-prepare-pxe.sh --interactive
OpenShift version: 4.22.1
Pull secret file [/root/pull-secret.json]:
Base domain: example.com
Cluster name [sno]:
Rendezvous IP (leave blank to auto-detect):
Network interface (leave blank to auto-detect):
IPv4 address with prefix (leave blank to auto-detect):
Gateway (leave blank to auto-detect):
Node hostname: sno.example.com
SSH public key file or key [/root/.ssh/id_ed25519.pub]:
Artifact directory [/root]:
Binary install directory [/usr/local/bin]:
DNS servers, comma-separated (leave blank to auto-detect):
Resolved configuration:
  OpenShift version: 4.22.1
  Pull secret:       /root/pull-secret.json
  Base domain:       example.com
  Cluster name:      sno
  Interface:         enp41s0
  IP/prefix:         78.46.123.45/26
  Gateway:           78.46.123.1
  MAC:               a8:a1:59:b3:c2:01
  Machine network:   78.46.123.0/26
  Rendezvous IP:     78.46.123.45
  Hostname:          sno.example.com
  DNS servers:       213.133.98.98 213.133.99.99 213.133.100.100
  Install disk:      /dev/nvme1n1
  SSH public key:    /root/.ssh/id_ed25519.pub
  Work directory:    /root/.hetzner-sno-provision
  Artifact dir:      /root
  Binary dir:        /usr/local/bin
Proceed with package installation, artifact generation, and writes to /root? [y/N] y
=== Step 1: Installing Rust/Cargo and nmstatectl ===
  Installing Rust/Cargo via rustup...
  Installing nmstatectl 2.2.37 via cargo...
  nmstatectl: nmstatectl 2.2.37
=== Step 2: Downloading OpenShift tools ===
  Downloading OpenShift checksums for 4.22.1...
  Downloading oc 4.22.1...
  Downloading openshift-install 4.22.1...
  oc:                 Client Version: 4.22.1
  openshift-install:  openshift-install 4.22.1
=== Step 3: Generating install-config.yaml ===
  Written: /root/.hetzner-sno-provision/install/install-config.yaml
=== Step 4: Generating agent-config.yaml ===
  Written: /root/.hetzner-sno-provision/install/agent-config.yaml
=== Step 5: Running openshift-install agent create pxe-files ===
=== Step 6: Copying boot artifacts to /root ===
  Copied files to /root:
-rw-r--r-- 1 root root  12M Jun 18 10:32 /root/agent.x86_64-initrd.img
-rw-r--r-- 1 root root 1.1G Jun 18 10:32 /root/agent.x86_64-rootfs.img
-rw-r--r-- 1 root root  12M Jun 18 10:32 /root/agent.x86_64-vmlinuz
=== Step 7: Cluster credentials ===

  kubeadmin password: a1B2c-D3e4f-G5h6i-J7k8L

  IMPORTANT: Save the content of /root/.hetzner-sno-provision/install/auth/kubeconfig before rebooting.
  It will be lost after the kexec reboot into the agent installer.

--- kubeconfig start ---
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTi...BASE64...
    server: https://api.sno.example.com:6443
  name: sno
contexts:
- context:
    cluster: sno
    user: admin
  name: admin
current-context: admin
kind: Config
preferences: {}
users:
- name: admin
  user:
    client-certificate-data: LS0tLS1CRUdJTi...BASE64...
    client-key-data: LS0tLS1CRUdJTi...BASE64...
--- kubeconfig end ---

=== Done ===
Boot artifacts are in /root. You can now run:
  ./hetzner-sno-provision-host-agentbased.sh --artifact-dir /root
to kexec into the agent installer.

To replay this configuration without interactive prompts:

  ./hetzner-sno-prepare-pxe.sh --yes \
  --hostname sno.example.com \
  --ssh-public-key-file /root/.ssh/id_ed25519.pub \
  --network-interface enp41s0 \
  --ip-with-prefix 78.46.123.45/26 \
  --gateway 78.46.123.1 \
  --dns-server 213.133.98.98 \
  --dns-server 213.133.99.99 \
  --dns-server 213.133.100.100 \
  --disk-device /dev/nvme1n1 \
  4.22.1 /root/pull-secret.json example.com sno 78.46.123.45
```

At this point, copy the **kubeadmin password** and save the **kubeconfig** to `~/.kube/config` on your workstation.

## 2. Boot into the agent installer

```console
root@rescue ~/hetzner-sno-provision-host # ./hetzner-sno-provision-host-agentbased.sh --artifact-dir /root
Resolved configuration:
  Artifact dir:    /root
  Kernel:          /root/agent.x86_64-vmlinuz
  Initrd:          /root/agent.x86_64-initrd.img
  Rootfs:          /root/agent.x86_64-rootfs.img
  Combined initrd: /root/agent.x86_64-combinedinitrd.img
  Kernel args:     rw  ignition.firstboot ignition.platform.id=metal
Proceed with kexec into the agent installer? [y/N] y
```

**Your SSH session drops here.** This is expected -- `kexec` has replaced the kernel.

## 3. Monitor from your workstation

After 5-10 minutes, the server should be reachable via SSH as the `core` user:

```console
$ ssh core@78.46.123.45
[core@sno ~]$ sudo crictl ps | head -5
```

You can also monitor via the API using the kubeconfig you saved earlier:

```console
$ export KUBECONFIG=~/.kube/config
$ oc get nodes
NAME              STATUS   ROLES                         AGE   VERSION
sno.example.com   Ready    control-plane,master,worker   42m   v1.35.1+a2c5e01

$ oc get clusteroperators | head -5
NAME                                       VERSION   AVAILABLE   PROGRESSING   DEGRADED   SINCE
authentication                             4.22.1   True        False         False      35m
baremetal                                   4.22.1   True        False         False      40m
cloud-controller-manager                   4.22.1   True        False         False      42m
cloud-credential                           4.22.1   True        False         False      42m
```

The full installation typically takes 30-60 minutes depending on hardware and network speed. If cluster operators are still progressing, wait and re-check.

**Note on SSH host keys:** The server's SSH host key changes with every rescue boot and again when RHCOS takes over. You will see `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` -- this is expected. Remove the old key before reconnecting:

```bash
ssh-keygen -R 78.46.123.45
```

If the server is unreachable after 15 minutes, the network configuration may be wrong. Use a [Hetzner KVM console](https://docs.hetzner.com/robot/dedicated-server/maintenance/kvm-console/) to troubleshoot.
