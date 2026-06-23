# Design: Reserve a raw boot-disk partition for CSI storage

Date: 2026-06-23
Status: Approved design
Component: `hetzner-sno-prepare-pxe.sh`

## Problem

Single-node OpenShift installations on small Hetzner systems often have only
one practical disk for both the OpenShift OS and local persistent storage. The
current agent-based workflow lets the installer consume the whole selected boot
disk. That leaves no stable, intentionally reserved block device for the LVM
Storage Operator or another CSI/operator to consume later.

The goal is to let an operator reserve a requested amount of the selected boot
disk as a raw partition while leaving enough space for OpenShift itself. This
must not weaken the existing disk-selection safety work: install targeting
remains serial-aware, and normal installs must remain unchanged unless the new
feature is explicitly enabled.

## Decisions

- Add an explicit-only CSI reservation feature to `hetzner-sno-prepare-pxe.sh`.
- Enable it only when `--csi-reserve-size <size>` is passed.
- Generate a day-1 `MachineConfig` manifest consumed by
  `openshift-install agent create pxe-files`.
- Create one raw GPT partition on the installed boot disk.
- Do not format, mount, encrypt, or otherwise initialize that partition.
- Do not generate LVMS, `LVMCluster`, StorageClass, or any CSI/operator
  resource.
- Use `/dev/disk/by-partlabel/<label>` as the stable post-install contract.
- Keep the minimum OpenShift version at 4.14, matching this repository's direct
  PXE workflow minimum.

## Non-goals

- No rescue-system disk mutation with `sgdisk`, `parted`, or similar tools.
- No support for multiple reserved partitions in the first version.
- No automatic interactive prompt for CSI reservation.
- No LVMS installation or configuration.
- No support for OpenShift versions below 4.14.

## Architecture

The feature lives entirely in `hetzner-sno-prepare-pxe.sh`. When the user does
not pass `--csi-reserve-size`, the script behaves as it does today and writes no
extra manifests.

When enabled, the script calculates a partition boundary after resolving the
install disk and before invoking:

```sh
openshift-install agent create pxe-files
```

It writes:

```text
<install-dir>/openshift/98-master-csi-raw-partition.yaml
```

The manifest is a `MachineConfig` for the `master` role. It targets the
installed RHCOS boot disk through:

```text
/dev/disk/by-id/coreos-boot-disk
```

The created raw partition is selected after installation through:

```text
/dev/disk/by-partlabel/openshift-csi
```

or the same path using a custom label from `--csi-part-label`.

## CLI

Add these options:

```text
--csi-reserve-size <size>     Reserve a raw boot-disk partition for CSI/LVMS, e.g. 800G
--csi-min-root-size <size>    Minimum OpenShift OS/root allowance after reservation (default: 120GiB)
--csi-part-label <label>      PARTLABEL for the raw partition (default: openshift-csi)
```

`--csi-reserve-size` is the only enabling flag. The other CSI flags configure
that feature only. If `--csi-min-root-size` or `--csi-part-label` is supplied
without `--csi-reserve-size`, fail with a clear error rather than silently
ignoring the option. The replay command includes CSI flags only when
`--csi-reserve-size` was used.

Size parsing accepts integer values with these case-insensitive suffixes:

- `M` and `MiB`: mebibytes
- `G` and `GiB`: gibibytes
- `T` and `TiB`: tebibytes

Short suffixes intentionally mean binary units, because Ignition partition
fields are expressed in MiB. Decimal SI units are not supported in the first
version.

Partition labels must be safe for stable device paths:

```text
^[A-Za-z0-9._-]{1,36}$
```

The default label is:

```text
openshift-csi
```

## Partition calculation

After resolving `INSTALL_DISK`, read the disk size with:

```sh
lsblk -bndo SIZE "$INSTALL_DISK"
```

Convert all sizes to MiB:

```text
disk_mib = floor(disk_bytes / 1048576)
reserve_mib = parsed --csi-reserve-size
min_root_mib = parsed --csi-min-root-size, default 122880
start_mib = disk_mib - reserve_mib
```

Validation fails before PXE generation if:

- `reserve_mib` is zero or invalid
- `disk_mib` cannot be read
- `start_mib` is less than `min_root_mib`
- `start_mib` is not positive
- the partition label is invalid
- the manifest cannot be written

The default `min_root_mib` is 120 GiB. This protects against a reservation that
would technically create a partition but leave too little space for OpenShift.

## Generated MachineConfig

Generate a direct `MachineConfig`, not a Butane file. Because OpenShift 4.14
uses Ignition 3.4.0, the generated config uses `ignition.version: 3.4.0` as the
cross-version baseline.

The generated manifest has this shape:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 98-master-csi-raw-partition
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      disks:
      - device: /dev/disk/by-id/coreos-boot-disk
        partitions:
        - label: openshift-csi
          number: 0
          startMiB: 1075200
          sizeMiB: 819200
          wipePartitionEntry: true
```

`number: 0` is intentional. In Ignition, partition numbers are one-indexed, and
zero means "use the next available partition slot." The partition label is the
stable interface. Operators should consume:

```text
/dev/disk/by-partlabel/openshift-csi
```

No `filesystems` entry is emitted. No `wipeTable: true` is emitted.

## User-visible output

When enabled, `print_resolved_config` includes:

- install disk size
- CSI reserve size
- CSI minimum root size
- computed partition start
- partition label
- stable partition path

In `--dry-run`, the script prints the computed split but does not prepare the
install directory and does not write the MachineConfig.

## Error handling and safety

The script must fail before running `openshift-install` if the reservation is
invalid. It must not attempt to repair or mutate the live rescue disk layout.

Existing disk selection behavior remains intact:

- `--disk-serial` remains the preferred replay-safe selector.
- `--disk-device` remains supported.
- autodetection and the multi-disk prompt remain unchanged.
- no-CSI runs remain unchanged.

If the selected disk size cannot be determined, the feature fails with a clear
error telling the operator to retry on the rescue host or disable CSI
reservation.

## Testing

Use the existing Bash test suite with stubbed commands. Tests should not touch
real disks.

Required coverage:

- size parser accepts `800G`, `800GiB`, `1T`, and `102400MiB`
- invalid sizes fail cleanly
- partition label validation accepts `openshift-csi`
- partition label validation rejects empty labels, slashes, whitespace, and
  labels longer than 36 characters
- reserve calculation fails when the OpenShift side would be below 120 GiB
- reserve calculation succeeds for a mocked 1.9 TiB disk and 800 GiB reservation
- generated MachineConfig contains `/dev/disk/by-id/coreos-boot-disk`
- generated MachineConfig contains `number: 0`, `startMiB`, `sizeMiB`, and
  `wipePartitionEntry: true`
- generated MachineConfig contains no `filesystems`
- `--dry-run --csi-reserve-size ...` prints the computed split but writes no
  manifest
- replay command includes CSI flags only when the feature is enabled
- no-CSI path preserves existing `install-config.yaml` and `agent-config.yaml`
  behavior

## Documentation

Update `README.md` with a focused section that explains:

- this feature is compatible with the repository's OpenShift 4.14+ direct PXE
  workflow
- it creates a raw unformatted boot-disk partition for CSI/LVMS use
- the default stable device path is
  `/dev/disk/by-partlabel/openshift-csi`
- the script does not install LVMS or generate an `LVMCluster`
- operators should target the labeled partition explicitly

Add a short command example:

```sh
./hetzner-sno-prepare-pxe.sh \
  --disk-serial S63CNF0X212063 \
  --csi-reserve-size 800G \
  --hostname sno.example.com \
  --ssh-public-key-file /root/.ssh/id_rsa.pub \
  4.22.1 /root/pull-secret.json example.com sno
```

## Version compatibility

This feature should be supported from OpenShift 4.14 onward.

Reasons:

- the repository's direct PXE workflow already requires 4.14+
- the OpenShift 4.14 Butane schema supports disk partition declarations
- the OpenShift 4.14 Butane schema documents `/dev/disk/by-id/coreos-boot-disk`
- Ignition 3.4.0 supports the required direct MachineConfig fields:
  `partitions`, `label`, `number`, `startMiB`, `sizeMiB`, and
  `wipePartitionEntry`

References:

- https://coreos.github.io/butane/config-openshift-v4_14/
- https://raw.githubusercontent.com/coreos/ignition/main/docs/configuration-v3_4.md
- https://docs.redhat.com/en/documentation/openshift_container_platform/4.14/html/installing_an_on-premise_cluster_with_the_agent-based_installer/installing-with-agent-based-installer

## Custom-branch validation

Because boot-disk partitioning is installation-sensitive, the first
implementation should be tested in a custom branch before merge. The minimum
real-server validation is:

1. Run `--dry-run --csi-reserve-size <size>` and inspect the computed split.
2. Run the real prepare script and confirm the generated MachineConfig exists
   before PXE generation.
3. Boot through the agent-based installer.
4. After installation, confirm the node exposes:
   `/dev/disk/by-partlabel/openshift-csi`
5. Confirm the partition size matches the requested reservation.
6. Configure LVMS or another operator separately to consume that device path.
