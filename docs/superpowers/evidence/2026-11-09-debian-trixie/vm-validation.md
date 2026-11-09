# Real Trixie VM validation

Date: 2026-11-09. The user supplied a Trixie VM and authorized SSH access with passwordless sudo. This is installed Debian userspace on a VM, not Hetzner Rescue or a physical-server boot test.

## Environment and source

- Debian 13.7 Trixie, kernel 6.12.116+deb13-amd64, amd64, four vCPUs, 7.8 GB RAM and legacy firmware.
- Before testing: about 213 GB disk space and 6.8 GB memory available, ample free inodes; root ext4 mount did not advertise quotas and the quota tool was absent. /tmp was tmpfs; build scratch used a private disk-backed /var/tmp directory, with CARGO_BUILD_JOBS=2. This differs from the default storage layout of a Rescue session.
- Prepare script SHA256: `52f51198b3740ebc15e53d0cb8a349eb841d2c56a332333e0621878e0c672ea8`, matching the reviewed implementation.
- GCC 14 and libc6-dev were already present. Rust/Cargo, nmstatectl and OpenShift tools were absent from the inspected command paths. Curl and ShellCheck were installed for validation; CA certificates were already present.
- Read-only kernel checks reported kexec_loaded=0, kexec_load_disabled=0 and lockdown=none. These are capability observations, not proof of a successful kexec handoff.

## Passed checks

1. The actual ensure_cargo_available helper installed Rust/Cargo 1.99.1 via rustup as root. The actual ensure_nmstatectl helper built and installed pinned nmstatectl 2.2.60 in 2m46s, using the VM's existing compiler/header packages.
2. Syntax, ShellCheck 0.10.0 and all four regression suites passed on the VM. Runner tests: 10; dependency tests: 12. The prepare and hardening suites also completed. Final status: 0.
3. The prepare script's real --dry-run resolved the VM's live IPv4 interface, address/prefix, gateway, DNS and disk path, using a disposable public key and an empty-auths dummy JSON file for input validation only. No registry credential was provided or used. The disk path was used only in generated configuration, never to install or repartition.
4. generate_agent_config wrote configuration from that live discovery. Its networkConfig block passed real nmstatectl gc and nmstatectl validate, generating an offline NetworkManager keyfile and normalized state. Nothing was applied to the live interface. IPv6/dual-stack were not tested in this VM run.
5. The actual install_ocp_tool helper downloaded and checksum-verified public OpenShift 4.22.1 client/installer archives. Both binaries ran and reported 4.22.1. Installer release image digest: `a15674d407c156561629987807f6b3e827772c6d2ef51dd226a6114871f23844`.

## Setup issues and handling

The VM's configured Warp apt repository lacked its signing key, causing an initial apt refresh to fail with status 100. During validation, package commands were restricted to the existing Debian entries using `-o Dir::Etc::sourcelist=/etc/apt/sources.list -o Dir::Etc::sourceparts=-`. Signature verification remained enabled and repository configuration was not edited at that stage.

The user then explicitly requested removing Warp Terminal. Package warp-terminal 0.2025.10.15.08.12.stable.01 was purged, its warpdotdev.list repository file removed, and its unused warpdotdev.gpg signing key removed after checking references. A normal apt-get update without source overrides then completed successfully. No autoremove was run. Private vm-warp-removal.log records the package transaction, absence checks and WARP_REMOVAL_AND_APT_UPDATE_SUCCESS marker.

A local SSH configuration include had an ownership/permission error. Subsequent direct SSH used `-F /dev/null`, normal known-host checking and the user's existing authentication. No global SSH configuration was changed.

## Evidence and retained state

Private, ignored local files preserve VM metadata, regression results, dependency/network output, generated agent/network YAML, tool versions/checksums and cleanup results. These contain live network details and must not be published. Public summaries omit VM address, MAC, account/host identity and disk identifiers. SHA256SUMS covers the published evidence files; the ignored SHA256SUMS.private covers the complete local evidence.

The initial temporary test key pair, dummy JSON input and empty build scratch were removed after their processes exited. Cargo's temporary compilation tree was automatically removed on success. Root Rust/Cargo/nmstatectl and validation packages remain installed. The private VM workspace was initially retained for artifact generation; after that validation completed, the entire workspace and this run's cached base ISO were removed. Verified output metadata and checksums are preserved locally, without retaining credential-bearing boot artifacts.

## Completed real PXE generation

After identifying an existing pull-secret file, the user explicitly approved restricting it to 0600 and using it on this VM. The full prepare script ran with --yes, OpenShift 4.22.1, an explicit VM disk hint, a disposable SSH public key, private work/bin/artifact paths and disk-backed TMPDIR. The real `openshift-install agent create pxe-files` invocation succeeded. Full script status was 0, including configuration generation, PXE generation and artifact copying. The VM disk was only an installation hint in generated configuration; no kernel or installer was booted and no disk was installed or repartitioned.

Generated outputs, before removal:

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| agent.x86_64-vmlinuz | 15178544 | 1f0cfbf65799bc1e610433308393055360dbf9e772b37b1179bd70d55bfa8d16 |
| agent.x86_64-initrd.img | 116952345 | 2fda6aa0e1fc8b5546c805ea63bc8718388991989e0d6a86b228bfd8719f7776 |
| agent.x86_64-rootfs.img | 1263900672 | 77836ae027501853e4e84f6cd74d72c6d30d3287918aa3faec995685d4cfc850 |
| agent.x86_64-combinedinitrd.img | 1380853024 | 525a828ad07ba960bc9d595341136ca1cc690a09398c79975ac9296a7ab0a32f |

The real agent provisioner's artifact validation and combined-initrd helper also passed. Independent streaming hash checks verified the combined file's exact length, original initrd bytes, seven zero-padding bytes and original rootfs bytes. No kexec function was invoked; kexec_loaded stayed 0 and the VM's root mount stayed unchanged.

## Credential handling and cleanup

The original pull-secret file remains on the VM at 0600. It was not copied into local project storage or printed. Preparation necessarily generated private installation state and embedded credentials in boot artifacts. Those temporary files, configuration backups, generated cluster credentials and the disposable test key were removed with the task-owned VM workspace after verification. This run's downloaded base ISO was also removed after its creation was confirmed in the installer log.

The script's output included a generated kubeconfig and kubeadmin password. Output was captured to a private 0600 log and those credential blocks were removed before review; no raw backup remains. The redaction record preserves the original log's checksum and removal counts. Live network details in the redacted log remain private and excluded from Git.

Private evidence records vm-pxe-preflight.log, vm-pxe-preparation.log, vm-pxe-artifact-verification.log and vm-pxe-cleanup.log establish success and cleanup. Their checksums are preserved in SHA256SUMS.private; the public summary is covered by SHA256SUMS.

## Reproducing the artifact stage

On an authorized Trixie test VM, copy the reviewed scripts into a new 0700 validation directory. Use a private existing pull-secret file and a disposable SSH public key, and keep the secret outside the install directory. Select the test disk explicitly as a configuration hint only. Set private disk-backed work, TMPDIR, bin and artifact paths; the completed run used two Cargo jobs and a 1800-second timeout. Run the prepare script with --yes, --disk-device, --hostname, --ssh-public-key-file, --artifact-dir and --bin-dir, followed by `4.22.1`, the secret path, `example.com` and `sno`. Capture output privately because the script prints generated cluster credentials. Do not run either provisioning main function. Source the agent-based script only to call validate_agent_artifacts and build_combined_initrd for offline validation. Preserve sizes/hashes and remove credential-bearing generated files after testing.

## Remaining gate

Hetzner Rescue assisted/direct-agent boot and installation validation still remain before declaring Trixie support or closing issue #14. An installed Trixie VM's successful PXE preparation does not establish those hardware and Rescue-kernel properties. The README's Bookworm requirement and runtime OS warnings remain unchanged.
