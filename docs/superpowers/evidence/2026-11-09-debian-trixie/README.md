# Trixie planning evidence, 2026-11-09

The subsequent [real Trixie VM validation](vm-validation.md) passed dependency installation, all regression suites, live network discovery, offline nmstate validation, verified OpenShift tools, real PXE generation and combined-initrd checks. Temporary artifacts and credential copies were removed after preserving output checksums. Real Hetzner Rescue boot/install validation remains pending.

## Source and environment

- Issue: https://github.com/tomazb/hetzner-sno-provision-host/issues/14
- Baseline source revision for the initial probes: `af566a7f36b0ccba06bbc9c67bc0e0e01a37cfd0`.
- Baseline prepare script SHA256: `129774abd86485eb095a6428ce8b19525864251ec166afe77219ed781680cde3`.
- Reviewed source revision for the final container matrix and Bookworm Rust-floor probe: `56d9901492eb27b5cc143edec7f3c26a2b59afe4`.
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

Run the probe commands from the root of a checkout containing this guide. Use rootless Podman, sufficient disk space and quota, and access to Debian, rustup and crates.io. Record the image digest and compare the resulting tool versions with the versions above, since apt packages and rustup stable can change.

The guide needs two pinned revisions: the baseline `af566a7f36b0ccba06bbc9c67bc0e0e01a37cfd0` and the reviewed `56d9901492eb27b5cc143edec7f3c26a2b59afe4`. A shallow or single-branch clone may lack them. Fetch them first:

```bash
git fetch --no-tags origin af566a7f36b0ccba06bbc9c67bc0e0e01a37cfd0 56d9901492eb27b5cc143edec7f3c26a2b59afe4
```

If the remote no longer has the reviewed revision on a branch, fetch `refs/pull/16/head` from the GitHub repository instead.

Each setup block below sets `probe_ready=1` only after the prepare script has been extracted and its SHA256 verified. On any failure it deletes the script, prints `STOP` and leaves `probe_ready=0`. Do not run a probe after a `STOP`; fix the cause and rerun the setup block. Each probe command also checks `probe_ready`, and a deleted script makes the Podman bind mount fail instead of mounting an empty or wrong file.

Extract the baseline prepare script into a temporary directory for the initial Cargo probe, the failing apt-Rust probe (`probe-apt-rust.bash`), and the minimal-package probe (`probe-minimal-rustup.bash`).

```bash
set -o pipefail
evidence_dir="$PWD/docs/superpowers/evidence/2026-11-09-debian-trixie"
baseline_rev=af566a7f36b0ccba06bbc9c67bc0e0e01a37cfd0
baseline_sha256=129774abd86485eb095a6428ce8b19525864251ec166afe77219ed781680cde3
probe_dir="$(mktemp -d)"
trap 'rm -rf -- "$probe_dir"' EXIT
probe_ready=0
if git cat-file -e "${baseline_rev}^{commit}" &&
  git show "${baseline_rev}:hetzner-sno-prepare-pxe.sh" > "$probe_dir/hetzner-sno-prepare-pxe.sh" &&
  (cd "$probe_dir" && echo "${baseline_sha256}  hetzner-sno-prepare-pxe.sh" | sha256sum -c -) &&
  chmod u+x "$probe_dir/hetzner-sno-prepare-pxe.sh"; then
  probe_ready=1
else
  rm -f -- "$probe_dir/hetzner-sno-prepare-pxe.sh"
  echo "STOP: baseline prepare script was not extracted and verified; do not run the probe." >&2
fi
```

The initial Cargo probe uses the baseline script and the recorded Trixie image.

```bash
[[ "$probe_ready" == 1 ]] &&
timeout --signal=TERM --kill-after=20s 900s podman run --rm --user 0 \
  --security-opt no-new-privileges --memory 4g --cpus 2 --pids-limit 512 \
  -v "$probe_dir/hetzner-sno-prepare-pxe.sh:/probe/prepare.sh:ro" \
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

To run a saved probe, replace `bash -s <<'PROBE'` and the here-document with `bash -s < "$evidence_dir/<probe-file>.bash"`. Use the filename below for the probe you want to run. Each probe reads the script mounted at `/probe/prepare.sh`.

- **Baseline probe bodies.** Use `probe-apt-rust.bash` to reproduce the Rust 1.85.1 failure and `probe-minimal-rustup.bash` to verify the smaller prerequisite set. Both use the baseline script and the Trixie image above.
- **Successful apt-Rust upgrade.** The earlier fix was tested before the broken-`rustc` recovery guard was added. Reconstruct it from the reviewed revision with the patch below, then run `probe-apt-rust.bash` on the same Trixie image.
- **Bookworm Rust-floor probe.** Extract the prepare script from the reviewed revision with the block below, but set `apply_patch=0` and `expected_sha256_file="$evidence_dir/reviewed-prepare-script.sha256"`. Run `probe-bookworm-rust-floor.bash` with the Bookworm image digest in `matrix-images.txt`.

```bash
reviewed_rev=56d9901492eb27b5cc143edec7f3c26a2b59afe4
# Successful apt-Rust upgrade: apply_patch=1, fixed-prepare-script.sha256.
# Bookworm Rust-floor probe:   apply_patch=0, reviewed-prepare-script.sha256.
apply_patch=1
expected_sha256_file="$evidence_dir/fixed-prepare-script.sha256"
probe_ready=0
rm -f -- "$probe_dir/hetzner-sno-prepare-pxe.sh"
if git cat-file -e "${reviewed_rev}^{commit}" &&
  git show "${reviewed_rev}:hetzner-sno-prepare-pxe.sh" > "$probe_dir/hetzner-sno-prepare-pxe.sh" &&
  (
    cd "$probe_dir" &&
      { [[ "$apply_patch" == 0 ]] || git apply "$evidence_dir/pre-review-prepare.patch"; } &&
      sha256sum -c "$expected_sha256_file"
  ) &&
  chmod u+x "$probe_dir/hetzner-sno-prepare-pxe.sh"; then
  probe_ready=1
else
  rm -f -- "$probe_dir/hetzner-sno-prepare-pxe.sh"
  echo "STOP: prepare script was not reconstructed and verified; do not run the probe." >&2
fi
```

Prefix each saved-probe run with `[[ "$probe_ready" == 1 ]] &&`, as in the initial Cargo probe.

For the final regression matrix, run `./scripts/test-debian-container.sh all` from a checkout of `56d9901492eb27b5cc143edec7f3c26a2b59afe4`. The runner exercises the userspace suites in both images. The separate probe commands build nmstatectl with Cargo. Containers' writable layers were removed automatically after exit and pre-existing Debian images were kept.

## Advisor synthesis

Opus advice is preserved locally in `opus-advice.md`; hypotheses there are not test results. Its native-package hypothesis was disproven for the tested repositories. Astra independently recommends standalone scripts, minimal changes, a dual-version userspace test runner, separate real dependency smoke tests and real Hetzner proof for both kexec invocation styles. Both recommend preserving Bookworm until those gates pass. Fable's completed adversarial review is preserved locally in `fable-advice.md`; the public planning response is in [review-resolution.md](review-resolution.md). Raw logs and transcripts remain persistent but are excluded from Git by this directory's .gitignore; they have not been published. `SHA256SUMS` covers the published evidence files; `SHA256SUMS.private` covers the complete local evidence set, including ignored logs and VM configuration.
