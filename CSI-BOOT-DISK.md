# Boot-Disk CSI Storage Reservation

`hetzner-sno-prepare-pxe.sh` can reserve part of the OpenShift boot disk as a
raw, unformatted partition for LVMS or another CSI operator. This is useful on
small Hetzner SNO systems where the boot disk is also the only practical local
storage device.

The common case is reserving 500 GiB from the end of the boot disk:

```bash
./hetzner-sno-prepare-pxe.sh \
  --disk-serial <boot-disk-serial> \
  --csi-reserve-size 500G \
  4.22.1 /root/pull-secret.json example.com sno
```

After installation, the reserved block device is available at:

```text
/dev/disk/by-partlabel/openshift-csi
```

Point LVMS or another CSI operator at that device path after the cluster is
installed.

## Requirements

- OpenShift 4.14 or newer for this repository's direct agent PXE workflow.
- A serial-backed install disk selection. Real runs with CSI reservation require
  `--disk-serial <serial>` or an auto-detected disk serial.
- Enough boot-disk space for both OpenShift and the reservation. The default
  minimum OpenShift-side allowance is `120GiB`.
- Validation on the target OpenShift minor release and target server class
  before relying on the layout.

Find the boot disk serial from the rescue system:

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL
```

Use the serial from the disk you want OpenShift to install onto, not a
partition name.

## Dry Run

Run a dry-run first. On the real rescue host, the script can read the selected
disk size and print the computed split:

```bash
./hetzner-sno-prepare-pxe.sh \
  --dry-run \
  --disk-serial <boot-disk-serial> \
  --csi-reserve-size 500G \
  --hostname sno.example.com \
  --ssh-public-key-file /root/.ssh/id_rsa.pub \
  4.22.1 /root/pull-secret.json example.com sno
```

The resolved configuration should include:

```text
CSI reserve size:  500G
CSI part label:    openshift-csi
CSI device path:   /dev/disk/by-partlabel/openshift-csi
Install disk size: ...
CSI partition start: ...
```

When dry-run runs away from the target rescue host, disk size or serial
information may be unavailable. In that case the script reports that CSI split
validation is deferred instead of guessing.

## Real Run

For an automated run, add `--yes` and keep the serial-backed disk selector:

```bash
./hetzner-sno-prepare-pxe.sh \
  --yes \
  --disk-serial <boot-disk-serial> \
  --csi-reserve-size 500G \
  --hostname sno.example.com \
  --ssh-public-key-file /root/.ssh/id_rsa.pub \
  4.22.1 /root/pull-secret.json example.com sno
```

Then boot the generated agent artifacts as usual:

```bash
./hetzner-sno-provision-host-agentbased.sh --yes
```

## What the Script Creates

The script writes a day-1 MachineConfig under the generated install directory:

```text
<install-dir>/openshift/98-master-csi-raw-partition.yaml
```

That MachineConfig asks Ignition to create one GPT partition on the installed
OpenShift boot disk:

- device: `/dev/disk/by-id/coreos-boot-disk`
- default PARTLABEL: `openshift-csi`
- partition number: next available GPT slot
- start: computed from `disk_size - csi_reserve_size`
- size: omitted, so the partition fills the remaining available space

The script does not format the partition, create a filesystem, create an LVM
physical volume, install LVMS, generate an `LVMCluster`, or create a
StorageClass. Keep those steps explicit and tied to the storage operator version
you deploy after installation.

## Size and Label Options

Accepted sizes require a suffix:

- `M` or `MiB`
- `G` or `GiB`
- `T` or `TiB`

Bare numbers are rejected. `500G` is treated as 500 GiB, which is `512000` MiB.

To keep more boot-disk space for OpenShift, raise the minimum root-side
allowance:

```bash
--csi-reserve-size 500G --csi-min-root-size 200GiB
```

To use a different stable device path, set a custom GPT PARTLABEL:

```bash
--csi-reserve-size 500G --csi-part-label lvms-pv
```

The post-install device path then becomes:

```text
/dev/disk/by-partlabel/lvms-pv
```

Labels must match:

```text
^[A-Za-z0-9._-]{1,36}$
```

## Safety Notes

This is an install-time partitioning feature. It applies only while generating
the day-1 agent installer assets. Editing the generated MachineConfig after the
cluster is already installed is not a supported way to repartition a running
node.

The reserved partition is created at the end of the disk before the RHCOS root
filesystem auto-grow completes. The root filesystem grows into the space before
the next existing partition, leaving the labeled CSI partition available at the
tail of the disk.

Use `--disk-serial` for CSI reservation. Device names like `/dev/nvme0n1` are
point-in-time kernel names and can reorder across boots. A wrong disk-size
measurement would make the computed partition boundary unsafe, so the script
requires serial-backed targeting for real CSI reservation runs.

## Troubleshooting

- `CSI reservation requires a serial-backed install disk`: pass
  `--disk-serial <serial>` or run on hardware where the selected disk exposes a
  serial.
- `Cannot determine size for install disk`: rerun on the Hetzner rescue host or
  check that the selected disk exists.
- `below --csi-min-root-size`: reduce `--csi-reserve-size`, lower
  `--csi-min-root-size`, or choose a larger boot disk.
- Missing `/dev/disk/by-partlabel/openshift-csi` after install: verify the
  cluster was installed from assets generated with `--csi-reserve-size`, then
  inspect the node with `lsblk -o NAME,SIZE,TYPE,PARTLABEL`.
