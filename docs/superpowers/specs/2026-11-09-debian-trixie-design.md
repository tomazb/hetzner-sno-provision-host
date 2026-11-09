# Debian Trixie rescue support design

Status: user approved preparatory tests and confirmed toolchain fixes for issue [#14](https://github.com/tomazb/hetzner-sno-provision-host/issues/14). Live provisioning and support declarations remain outside this approval.

## Intent and constraints

Allow Debian 13 Trixie Hetzner Rescue to run the assisted and direct agent-based provisioning workflows while retaining Debian 12 Bookworm. Keep the three scripts independently downloadable. Preserve dry-run behavior, interactive and automated disk selection, checksum checks, and both existing kexec invocation styles. The OpenShift PXE version floor stays 4.14.

Container success is prerequisite evidence, not proof of Hetzner rescue kernel or boot compatibility. Keep the Bookworm README requirement and warning behavior until real-server validation passes. Do not claim untested OpenShift releases, network modes, firmware modes, or server classes.

## Approaches considered

1. Retain pinned Cargo nmstatectl 2.2.60 on both Debian releases. Recommended by Opus, consistent with Astra's minimal-change advice. One dependency policy and no release-specific package branch; requires build tools, network access and compilation time.
2. Use a native Trixie package while retaining Cargo on Bookworm. Potentially faster, but the 2026-11-09 amd64 Trixie container probe found no nmstate or nmstatectl package in its configured repositories. Not viable on that evidence.
3. Publish project-built binaries. Adds artifact hosting and supply-chain maintenance outside this issue.

The recommendation is a proposal for the user, not an approved implementation choice. Astra notes that a native package, if considered later, would also need version and installer validation; availability alone would not justify it.

## Proposed changes

Add a common two-version regression container runner and preserve the existing Debian 12 wrapper. Keep expensive real package/build checks separate from fast stubbed suites. Probe the pinned installation path, its toolchain assumptions and kexec-tools installation before changing runtime behavior. Fix only demonstrated compatibility defects, with focused regressions.

After real Trixie validation, consistently rename the three warning helpers to `warn_if_not_supported_debian`, accept only Debian VERSION_ID 12 or 13, and retain warning-and-continue for other metadata. Keep the non-executing parser and update every test override/call site. No shared runtime library or generalized distro framework.

## Evidence and release gates

Record container image identity, repository revision, package sources/versions, Rust/Cargo versions, installation method, commands, status and limits. The initial native-package probe and a container-capability setup failure are preserved under `../evidence/2026-11-09-debian-trixie/`.

Validate real dependency installation separately from stubbed suites. Validate generated network configuration with real nmstatectl and the selected OpenShift installer. Real Hetzner checks need at least two fresh Trixie rescue sessions, because each kexec workflow consumes the session. Prove agent installation and boot from disk, and assisted discovery and installation, using a designated test server and explicitly identified disks. Such runs are future work, not authorized by this planning task.

Keep raw credentials, IPXE tokens, pull secrets and cluster credentials private. Commit only sanitized evidence and artifact checksums. Capture actual rescue metadata, kernel, hardware class, firmware mode, OpenShift version, network mode, disk selector, revision, outcomes and limitations. Revalidate Bookworm on hardware if shared runtime dependency or boot behavior changes.

## Non-goals and open work

No Rust toolchain pin change, package-policy redesign, generic distro support, CI provider setup, broad refactor, or unrelated transcript cleanup without demonstrated need. The pinned Cargo build passed in the Trixie container with Rust/Cargo 1.99.1 and gcc/libc6-dev added alongside curl and CA certificates. Offline gc/validate passed for one IPv4 fixture. Debian Rust 1.85.1 reproduced a failure because the pinned crate requires 1.88; a subsequent real Bookworm container build at exactly Rust 1.88.0 also passed. Upgrade compilers below that floor and install missing Cargo through the current rustup path; recover failed rustc version queries through rustup and check for cc before compilation with actionable prerequisite guidance. Do not add an automatic prepare-script apt step. Unknowns remain actual Trixie Rescue tools/kernel and both real boot outcomes. A successful userspace build cannot close those boot gates.
