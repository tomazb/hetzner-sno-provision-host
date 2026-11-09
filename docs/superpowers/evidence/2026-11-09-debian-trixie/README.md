# Trixie planning evidence, 2026-11-09

The subsequent [real Trixie VM validation](vm-validation.md) passed dependency installation, all regression suites, live network discovery, offline nmstate validation, verified OpenShift tools, real PXE generation and combined-initrd checks. Temporary artifacts and credential copies were removed after preserving output checksums. Real Hetzner Rescue boot/install validation remains pending.

## Source and environment

- Issue: https://github.com/tomazb/hetzner-sno-provision-host/issues/14
- Source revision: `af566a7f36b0ccba06bbc9c67bc0e0e01a37cfd0`.
- Prepare script SHA256: `129774abd86485eb095a6428ce8b19525864251ec166afe77219ed781680cde3`.
- Rootless Podman 5.8.9, cached image `docker.io/library/debian:13`; immutable identity and architecture in `image.txt`.
- Container reports Debian 13.6 Trixie, amd64. Apt sources contacted trixie, trixie-updates and trixie-security on deb.debian.org. This is a Debian userspace container, not a Hetzner Rescue kernel.
- Before workloads: host disk had 62 GB available, tmpfs had 32 GB available with a per-user 25 GB quota, and ample tmpfs inodes. Container build limited to two CPUs, 4 GB RAM, 512 PIDs and 900 seconds. No host credentials, container socket, device access or host network were supplied.

## Results

`nmstate-package-probe.log`: apt refresh succeeded. nmstatectl was absent in the base image; `apt-cache policy nmstate nmstatectl python3-libnmstate` and `apt-cache search nmstate` found no candidates. Rust/Cargo candidate was 1.85.1+dfsg1-1+deb13u1; kexec-tools candidate was 1:2.0.29-2+b2. No Debian native nmstate installation was possible from those configured sources. This does not establish availability in every repository or architecture.

`nmstate-cargo-probe.log`: current prepare-script helpers installed Rust/Cargo 1.99.1 with rustup and ran `cargo install --locked --force --version 2.2.60 nmstatectl`. Compilation completed in 3m36s, installed binary reported nmstatectl 2.2.60, and `--help` / `validate --help` succeeded. The complete container command exited 0.

Explicit probe prerequisites were ca-certificates, curl, build-essential, pkg-config, libssl-dev and libdbus-1-dev, installed with `--no-install-recommends`. Their versions appear at the log end. They are a known successful set, not a proven minimal set or proof of their presence in Hetzner Rescue.

The first package attempt used `--cap-drop ALL`, which prevented apt from changing user/group and exited 100. `nmstate-package-probe-capability-failure.log` preserves that setup failure. Rerunning with normal rootless container capabilities succeeded. This was not a Trixie package failure.

The initial broad-package probe did not generate network configuration. The resumed probes below add toolchain and offline configuration evidence. No probe applied network configuration, ran an OpenShift tool, installed kexec-tools, or loaded a kernel. Containers use `--rm`; their writable build layers are disposable. The pre-existing Debian image is retained.

## Resumed dependency investigation

`nmstate-apt-rust-probe.log` reproduced a failure with Debian's rustc/Cargo 1.85.1. The unchanged helper reused that compiler, and Cargo exited 101: nmstatectl 2.2.60 requires rustc 1.88 or newer. This directly confirms the minimum-version bug identified during planning. It establishes a declared requirement of 1.88; it is not a successful build with 1.88.

`nmstate-minimal-rustup-probe.log` started with only curl and ca-certificates added to the clean image. Rustup installed Rust/Cargo 1.99.1, but the pinned Cargo build failed with `linker cc not found`, status 101. Adding only gcc and libc6-dev with `--no-install-recommends`, including their apt dependencies, allowed the pinned build to succeed in 2m51s. This did not need the earlier build-essential, pkg-config, libssl-dev or libdbus-1-dev packages. The same container had only the original curl/CA packages before that retry; its failed compiler-free build had installed no compiler or development packages.

The smaller-package probe also ran real `nmstatectl gc` and `nmstatectl validate` against a documentation-address IPv4 fixture. Both succeeded, generating an offline NetworkManager keyfile and normalized network state without applying it. This is one representative fixture, not real OpenShift PXE or every network mode. After success, .cargo used 170 MB and .rustup used 593 MB; transient build peak storage was not measured.

Exact probe bodies are preserved in `probe-apt-rust.bash` and `probe-minimal-rustup.bash`. Their named containers used the same immutable Debian image, read-only prepare-script bind mount, default rootless container capabilities, no-new-privileges, two CPUs, 4 GB RAM, 512 PIDs, and a 900-second outer timeout. Names are recorded in the corresponding `*-container-name.txt` files. Raw logs are ignored by Git.

## Preparatory implementation verification

After the user approved tests and confirmed fixes, the helper's Rust requirement was raised to the crate-declared 1.88 floor, missing Cargo triggers toolchain installation, and a missing cc produces an actionable error before Cargo compilation. No native-package fallback or automatic compiler package installation was added.

`nmstate-fixed-apt-rust-probe.log` reran `probe-apt-rust.bash` against the changed prepare script, whose checksum is in `fixed-prepare-script.sha256`. Starting with Debian Rust/Cargo 1.85.1 and gcc/libc6-dev, the helper recognized the old compiler, installed rustup stable 1.99.1 and successfully built nmstatectl 2.2.60 in 2m57s. The full probe exited 0. This verifies upgrade despite distro Rust already being on PATH, not a build using Rust 1.88 itself.

`container-matrix.log` records both `debian:12-slim` and `debian:13-slim` passing syntax, ShellCheck and all four suites, with final matrix status 0. Each image ran eight runner tests, eleven dependency tests and both existing prepare/hardening suites. Image tags, digests and architecture are in `matrix-images.txt`. The existing Debian 12 wrapper was also exercised through the isolated-engine tests.

After Fable's implementation review, a failing rustc version query was made recoverable through rustup. Tests now use minimal environments, the legacy wrapper again ignores arguments, and the runner uses fully qualified Docker Hub image names. `final-container-matrix.log` verifies this revised code: both images passed ten runner tests, twelve dependency tests and both existing suites, with final status 0. The exact reviewed prepare script is identified by `reviewed-prepare-script.sha256`.

`nmstate-bookworm-rust-floor-probe.log` validates the final helper on supported Debian 12 userspace at exactly Rust/Cargo 1.88.0, explicitly selected after rustup installation. The pinned nmstatectl 2.2.60 build completed in 3m18s and the binary's version check succeeded; full probe status was 0. Compiler packages were gcc 4:12.2.0-3 and libc6-dev 2.36-9+deb12u14. This confirms both the exact floor with locked dependencies and a real Bookworm build after the shared helper changes. It does not establish real Hetzner boot compatibility.

The regression suites stub package installation, Cargo, OpenShift downloads and kexec. Their success is separate from the real Cargo probes and does not establish Trixie Rescue boot support. The Bookworm selection instructions and runtime Debian-version warnings remain unchanged.

## Reproduction

Run from the repository root at the recorded source revision, with rootless Podman, sufficient disk/quota and access to Debian, rustup and crates.io. Capture the image digest before running and preserve the pipeline exit status with `pipefail`. A newer apt repository or rustup stable can produce different versions; use the recorded log to compare.

```bash
set -o pipefail
timeout --signal=TERM --kill-after=20s 900s podman run --rm --user 0 \
  --security-opt no-new-privileges --memory 4g --cpus 2 --pids-limit 512 \
  -v "$PWD/hetzner-sno-prepare-pxe.sh:/probe/prepare.sh:ro" \
  -i docker.io/library/debian@sha256:d8f17b92dc7ff10f9c1fdecab0ad21103d1d24aed823c3a0359e4f50adfab3eb \
  bash -s <<'PROBE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive CARGO_BUILD_JOBS=2
cat /etc/os-release
apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=30 update
apt-get install -y --no-install-recommends ca-certificates curl build-essential pkg-config libssl-dev libdbus-1-dev
export HSPPXE_TEST_MODE=1
source /probe/prepare.sh
DRY_RUN=0
ensure_cargo_available
rustc --version
cargo --version
ensure_nmstatectl
nmstatectl --version
nmstatectl --help
nmstatectl validate --help
dpkg-query -W ca-certificates curl build-essential pkg-config libssl-dev libdbus-1-dev
PROBE
```

For the package-only probe, use a clean container of the same image, run `command -v nmstatectl`, successfully refresh apt indexes, then run `apt-cache policy nmstate nmstatectl python3-libnmstate cargo rustc kexec-tools` and `apt-cache search nmstate`. An empty candidate list is evidence only after a successful index refresh.

For resumed probes, feed the named `.bash` body to the same bounded container invocation with the prepare script mounted at `/probe/prepare.sh`. `probe-apt-rust.bash` was run first against the baseline script for the failing log, then against the checksum in `fixed-prepare-script.sha256` for the successful upgrade. `probe-minimal-rustup.bash` used the baseline script. `probe-bookworm-rust-floor.bash` uses the reviewed script and the Bookworm image digest in `matrix-images.txt`. All use `--rm --user 0 --security-opt no-new-privileges --memory 4g --cpus 2 --pids-limit 512`, and a 900-second outer timeout. Source identity matters; the failing original-helper probe is not expected to fail after applying the fix.

The final regression command was `./scripts/test-debian-container.sh all`. It runs only userspace tests; real Cargo builds are separate probe commands. Containers' writable layers were removed automatically after exit; pre-existing Debian images were kept.

## Advisor synthesis

Opus advice is preserved locally in `opus-advice.md`; hypotheses there are not test results. Its native-package hypothesis was disproven for the tested repositories. Astra independently recommends standalone scripts, minimal changes, a dual-version userspace test runner, separate real dependency smoke tests and real Hetzner proof for both kexec invocation styles. Both recommend preserving Bookworm until those gates pass. Fable's completed adversarial review is preserved locally in `fable-advice.md`; the public planning response is in [review-resolution.md](review-resolution.md). Raw logs and transcripts remain persistent but are excluded from Git by this directory's .gitignore; they have not been published. `SHA256SUMS` covers the published evidence files; `SHA256SUMS.private` covers the complete local evidence set, including ignored logs and VM configuration.
