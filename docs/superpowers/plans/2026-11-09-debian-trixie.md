# Debian Trixie support implementation plan

> **For agentic workers:** Use superpowers:executing-plans for implementation after user approval. Advisors and review do not authorize provisioning or disk writes.

**Goal:** Add verified Debian 13 Trixie Hetzner Rescue support while retaining Debian 12 Bookworm.

**Architecture:** Preserve three standalone scripts and the pinned Cargo nmstatectl path. Introduce a shared container test runner, perform real dependency and boot validation, then update recognition and support documentation.

**Tech Stack:** Bash, Python test helpers, Podman/Docker, Debian 12/13, Cargo, nmstatectl 2.2.60, OpenShift agent PXE and assisted iPXE.

**Spec:** [Proposed design](../specs/2026-11-09-debian-trixie-design.md).

## Global constraints

- Retain Debian 12 Bookworm and the OpenShift PXE floor of 4.14.
- Keep scripts standalone, dry-run free of package/download/boot effects, and disk selection semantics unchanged.
- Keep nmstatectl at 2.2.60 unless a demonstrated incompatibility requires a separately reviewed decision.
- Keep Bookworm requirement and current warning behavior until real Trixie boot evidence passes.
- Use only sanitized public evidence. Save necessary logs before deleting task-owned container/scratch data; do not remove pre-existing images or other sessions' data.
- The user approved preparatory container tests and confirmed toolchain fixes after dependency probes. Live provisioning, support declarations and issue closure remain outside that approval. Tasks 4/5 are future work.

## Review focus

- A green stubbed suite must never be reported as a real dependency build or a successful kexec boot.
- A preinstalled Rust meeting the old 1.85 check may still be too old for locked dependencies; test it separately from fresh rustup.
- OS fixtures must not accept Ubuntu with VERSION_ID 13, future Debian, or execute text in os-release.
- A matrix loop must run both images, preserve a failed leg and reject unsupported arguments before starting a container.
- Shared dependency or boot changes can regress Bookworm despite a passing Trixie probe; rerun relevant Bookworm integration and hardware checks.

## Task 1: Record dependency evidence and resolve the installation policy

**Files:** preserve logs and reproduction notes under `docs/superpowers/evidence/2026-11-09-debian-trixie/`; no production edits in this task.

- [ ] Record source SHA and script SHA256, image tag/digest/architecture, engine version, exact invocation and flags, container OS metadata and configured apt sources. Check disk space, inodes and quota before builds. Use a unique container name and record its ID; remove only task-owned scratch/containers after preserving evidence. Keep pre-existing images.
- [ ] Probe clean Trixie for an existing executable and apt candidates named nmstate, nmstatectl, libnmstate and python3-libnmstate after successful apt update. Record absence as absence for those sources/architecture only.
- [ ] Exercise actual `ensure_cargo_available` and `ensure_nmstatectl` from the current prepare script in a disposable container, with required compiler/system development packages explicitly recorded. Confirm `nmstatectl --version` is 2.2.60 and run `nmstatectl gc` on representative generated networkConfig fixtures. Do not run `apply` or reconfigure container networking.
- [ ] Mandatory minimal-prerequisite probe: start clean Trixie, add only curl and ca-certificates, and invoke the real helpers. Record the first failure. Retry in a clean environment with gcc and libc6-dev added, without the earlier broad development-package set. Record actual package dependencies; do not declare a minimal set without testing it. Record Cargo/Rust directory sizes and build temporary storage/peak memory before container removal.
- [ ] Mandatory apt-toolchain probe: clean Trixie with `rustc cargo gcc libc6-dev curl ca-certificates`, without preinstalled rustup. Invoke the real helpers and pinned build with the actual Debian-provided toolchain. Record success/failure and crate minimum-version diagnostics independently. This tests the existing 1.85 reuse threshold. A raised threshold must be measured, not inferred from an advisor's memory.
- [ ] In clean Debian 12 and 13 containers, install kexec-tools with the scripts' exact debconf selections; record debconf templates, package version, and `kexec --version`. Never load or execute a kernel in containers.
- [ ] If a build fails, classify missing probe prerequisites, unavailable downloads and actual compatibility defects separately. Add exact reproduction and the smallest proposed fix to this plan before implementation. Retain the pinned Cargo route if it passes; do not add native-first fallback speculatively.

## Task 2: Cover both releases with fast regression checks

**Files:** create executable `scripts/test-debian-container.sh`; modify `scripts/test-debian12-container.sh` as a compatibility wrapper; add executable `tests/test-debian-container-runner.sh`; update the existing hardening wrapper-existence assertion only if needed.

**Interface:** `scripts/test-debian-container.sh [12|13|all]`, default `all`; the existing Debian 12 command invokes only `12`.

- [ ] Write runner tests using fake Podman/Docker commands and an isolated PATH containing only required utility shims/symlinks, so host engines cannot contaminate fallback/missing-engine cases. Assert `12` selects `debian:12-slim`, `13` selects `debian:13-slim`, and `all`/no arguments selects both once. Assert invalid or extra arguments fail before container launch; missing engines fail clearly; Podman preference, Docker fallback, explicit container user 0, working directory and mount rules survive. Do not drop the capabilities apt needs for `_apt` user/group transitions. Both legs must run even if the first fails; the final exit must be nonzero if either fails.
- [ ] Add unconditional focused characterization tests for `ensure_cargo_available` and `ensure_nmstatectl`, with fake tools on PATH and a private fake HOME. Cover pinned reuse with no Cargo install, mismatched version using exactly `cargo install --locked --force --version 2.2.60 nmstatectl`, Debian-format version output, 1.84/1.85 current boundary, rustc present with Cargo absent, rustup failure, Cargo failure and side-effect-free dry-run. Main-flow failures must precede `install_ocp_tool`. Record existing defects explicitly; update boundary expectations when Task 3 fixes the measured minimum. Direct helper reuse and the main flow must be distinguished because main currently ensures Rust before checking nmstatectl.
- [ ] Run `bash tests/test-debian-container-runner.sh` and confirm new-interface assertions fail before implementation.
- [ ] Implement the runner and wrapper without duplicating the test command body. Preserve shell syntax, ShellCheck and both existing suites; include the new runner test in both images. Keep package/build smoke checks outside the default fast runner.
- [ ] Run syntax and ShellCheck for all tracked shell scripts. Run the new runner test, both existing suites, then `scripts/test-debian-container.sh all`. Record each image identity, suite result and final status. Fix only failures exposed by the matrix.
- [ ] Add README instructions for the matrix as userspace regression coverage; leave the Bookworm rescue selection requirement intact. Commit this preparatory change separately when implementation is approved.

## Task 3: Fix demonstrated dependency or userspace incompatibilities

**Files:** `hetzner-sno-prepare-pxe.sh` and focused tests in `tests/test-hetzner-sno-prepare-pxe.sh` / `tests/test-hetzner-sno-hardening.sh`; modify the boot scripts only if their real package probes expose a defect.

**Interfaces:** preserve `ensure_cargo_available`, `ensure_nmstatectl`, `NMSTATECTL_VERSION`, all public flags and standalone execution.

- [ ] Extend Task 2's characterization with failing regressions before each required fix. If apt Rust fails because it is too old, raise the threshold to a measured working minimum and route older compilers through rustup, with below/at-boundary cases. If Cargo is missing with an otherwise sufficient compiler, route through a working toolchain install instead of a misleading post-install error; test rustup behavior with distro rustc on PATH. Assert failures stop before installer/PXE or kexec effects.
- [ ] If real Rescue lacks compiler prerequisites, present the concrete choice before adding a new prepare-script apt step: document/fail clearly on missing tools, or install the verified package set inside the compile branch. Any chosen package install must follow confirmation, never run on pinned-binary reuse or dry-run, fail before artifact generation and have stubbed ordering/failure tests. Do not silently expand prepare-script package behavior based on the over-provisioned container probe alone.
- [ ] For any kexec-tools defect, test exact preseed/install behavior and failure before kexec in both scripts. Preserve assisted one-shot invocation and agent `-l`/`-e` plus padded combined initrd. Do not change apt-update policy without an observed failure and an explicit recovery decision.
- [ ] Implement only fixes justified by Task 1. If real Trixie `ip`/route/DNS/lsblk formats expose parsing problems, add sanitized fixtures and the smallest parser correction. Keep claimed/tested network modes explicit.
- [ ] Rerun focused regressions and the two-image matrix; rerun actual dependency probes on both releases. Save versions, outcomes, and any minimum-toolchain decision. Commit independently of support claims.

## Task 4: Validate real Hetzner Trixie rescue workflows

**Files:** create a validation runbook at `docs/TRIXIE-VALIDATION.md` and sanitized result notes under the evidence directory. Test credentials and raw private logs stay outside tracked files.

**Prerequisites:** designated disposable test server, server/disks identified by the user, console/recovery path, OpenShift release and credentials. Obtain authorization for destructive live runs when these concrete inputs exist. Planning does not provide it.

- [ ] Run the documented user path without build-storage environment overrides, so evidence reflects actual default behavior. Before/after prepare, record rescue disk/tmpfs space, inode capacity, account quota, memory and build peaks where measurable. Do not use target installation disks for scratch. If default storage runs out, stop and record it as a defect before proposing an explicitly documented alternative. Private disposable evidence scratch must not change the build's storage path.
- [ ] Capture actual rescue os-release as a fixture; kernel, firmware, kexec configuration/lockdown, `kexec_load_disabled`, initial `/sys/kernel/kexec_loaded`, architecture, `systemctl --version`, `kexec --version`, memory and Rust/Cargo versions. Record `command -v cc gcc ld pkg-config` and installed gcc/libc6-dev versions. Bind each result to the validated commit SHA and SHA256 of all three scripts.
- [ ] Compare resolved network and disk values against the live host using dry-runs. Validate the supplied SSH public key, pull secret and intended serial-backed install disk before a real run. Generate PXE artifacts with the real installer and record SHA256 sums and nmstatectl version.
- [ ] First fresh rescue session: run the direct-agent workflow on the approved test disk. Verify remote reachability after kexec, installer progress, installation completion, reboot from disk and cluster availability. Save sanitized results and timestamps.
- [ ] Second fresh rescue session: run assisted iPXE provisioning with a current discovery URL. Verify assisted host discovery, network reachability and installation completion. Explicitly detect a return to disk/rescue without discovery, which could indicate a one-shot kexec/shutdown handoff failure. A handoff fix is a separately reviewed runtime change and requires Bookworm hardware revalidation. Do not publish the URL/token. Each run must record its own actual invocation and results.
- [ ] If shared runtime dependency or boot behavior changed in Task 3, run the affected real Bookworm workflow too. Containers alone do not clear that regression risk.
- [ ] Minimum pass bar: both Trixie workflows complete on at least one identified server class, firmware mode, network mode and OpenShift version. Record each actual combination; leave other modes explicitly untested. If either Trixie workflow fails, keep the Bookworm recommendation and record the failure without declaring support.

## Task 5: Enable recognition and update support guidance after validation

**Files:** all three `hetzner-sno-*.sh`, including the prepare-script header; `tests/test-hetzner-sno-hardening.sh`; warning-helper overrides and documentation file list in `tests/test-hetzner-sno-prepare-pxe.sh`; `README.md`, including both dependency explanations, `QUICK-START.md`, `COMPARISON.md`; validation results. Update runner errors to match their selected version. Preserve historical planning docs and the Bookworm screenshot's accurate caption.

- [ ] After Task 4 passes, add parameterized assertions across all three scripts: Debian 12 and 13 produce no warning; Debian 11/14, Ubuntu VERSION_ID 13, missing metadata and missing required keys warn and return success. Include the captured rescue fixture, malformed unrelated lines, unquoted/single-quoted/double-quoted values, no PRETTY_NAME, and literal shell substitutions which must never execute. Parse quotes as data, never source os-release.
- [ ] Assert these exact warning templates, substituting the actual path/name: `WARNING: This script is tested for Debian 12 (Bookworm) and Debian 13 (Trixie) Hetzner Rescue. Detected ${pretty_name}; it may fail.` and `WARNING: Could not read ${os_release_file}. This script is tested for Debian 12 (Bookworm) and Debian 13 (Trixie) Hetzner Rescue and may fail on other systems.`
- [ ] Rename `warn_if_not_debian_12` to `warn_if_not_supported_debian` in the three scripts and every test helper, stub and main call. Retain the data-only parser and warning-and-continue semantics. Adapt only parsing defects covered by the new cases.
- [ ] Run both suites and the two-version container matrix. Search tracked shell sources for `warn_if_not_debian_12`; expect no remaining runtime references. Run the documentation command guard as part of the prepare suite.
- [ ] Compare final script changes against every validated revision using `git diff <validated-sha>..HEAD -- 'hetzner-sno-*.sh'`. Only warning-helper parsing/messages, their call sites and header comments may differ without another affected-workflow hardware run. Any change to dependency, network, artifact or boot behavior invalidates the corresponding earlier result. Record final script hashes and this comparison in the evidence summary.
- [ ] Update rescue instructions to select Bookworm or Trixie by codename, with Robot's current labels secondary. Name both tested versions in warnings, README dependency explanations, quick start, test guidance and comparison. State the actual tested hardware/firmware/network/OpenShift combination. Distinguish userspace matrix coverage from real-server evidence; do not represent the Bookworm screenshot as a Trixie selection. Add the new validation runbook to the explicit documentation-command guard list and ensure it yields checked prepare commands, so examples cannot silently drift.
- [ ] Review the final diff and evidence for secrets, source/tool versions, actual boot outcomes and unsupported claims. Open the support PR with evidence and link issue #14; close the issue only after its real-host acceptance criteria are met.

## Planning review status

Opus and Astra independently advise staged validation, standalone scripts and conservative support claims. Fable adversarial review completed; the plan now includes minimal-prerequisite and mandatory apt-toolchain probes, unconditional dependency characterization, default-storage hardware runs, isolated-PATH runner tests, exact warning contracts and final-revision evidence binding. See [review resolution](../evidence/2026-11-09-debian-trixie/review-resolution.md). Task 1 planning probes are research evidence; unchecked items remain future implementation/validation work.

The planning-time Trixie amd64 probe successfully built and installed nmstatectl 2.2.60 using the current script helpers with Rust/Cargo 1.99.1. Version and help checks passed. No native nmstate package was found in the configured Trixie repositories. This does not validate the old Rust 1.85 threshold, the minimum required system packages, networkConfig generation or actual installer/boot behavior. See [probe results and reproduction](../evidence/2026-11-09-debian-trixie/README.md).

## Approved preparatory implementation progress

After resumption, the user explicitly approved implementing preparatory tests and confirmed fixes. The mandatory Debian-apt toolchain probe reproduced failure with Rust 1.85.1: the pinned crate declares Rust 1.88 or newer. The smaller prerequisite probe failed without cc and passed after adding gcc/libc6-dev alongside curl/CA certificates. Real offline gc/validate passed for one IPv4 fixture, not an OpenShift installer run.

Implemented on `fix/debian-trixie-preparation`: common two-image runner and legacy wrapper; isolated engine tests; direct dependency-helper tests; Rust 1.88 minimum, missing-Cargo upgrade, broken-rustc recovery and compiler preflight. No automatic prepare-script apt install, Debian-warning recognition changes or boot invocation changes. Fable implementation review completed; confirmed corrections were applied by the parent. Both final Debian 12/13 matrix legs passed all four suites plus syntax/ShellCheck, and the fixed helper upgraded Debian's apt Rust 1.85.1 to rustup 1.99.1 and built the pin successfully in a clean Trixie container. The final helper also built the pin and locked dependencies in Bookworm at exactly Rust 1.88.0, confirming the floor on the supported userspace. These preparatory changes are packaged for a pull request. Hetzner Rescue boot/install gates remain unexecuted and issue #14 remains open.

## Additional user-supplied VM validation

The user subsequently supplied a real Debian 13.7 VM with passwordless sudo. The reviewed prepare helpers built nmstatectl 2.2.60 there, all four suites plus syntax/ShellCheck passed, real network discovery fed generated agent-config whose networkConfig passed offline gc/validate, and the public OpenShift 4.22.1 tools downloaded with checksum verification and ran successfully. After explicit credential-use approval, the full prepare script generated and copied the real PXE artifacts successfully. The real combined-initrd helper and independent byte/padding checks also passed. Temporary artifacts, generated credential copies, test keys and this run's cached ISO were removed after preserving hashes and private redacted evidence; the user's original secret remains at 0600. See [VM evidence](../evidence/2026-11-09-debian-trixie/vm-validation.md). This installed VM is not Hetzner Rescue. No kexec, disk installation or support-warning change has occurred. Real Rescue boot/install gates remain unexecuted.
