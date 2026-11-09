# Planning review resolution

Opus and Astra advised the initial plan. Fable adversarial review completed on 2026-11-09. This resolution is the parent's response; it is not a second reviewer approval.

1. Over-provisioned Cargo probe: accepted. The existing result explicitly proves installation only with the recorded prerequisite set. Task 1 now requires a clean minimal-set experiment; Task 4 captures actual Rescue compiler packages. New prepare-script package behavior needs a concrete choice before implementation.
2. Rust 1.85 reuse threshold: accepted as an unverified risk. Apt Rust/Cargo testing is mandatory, with below/at-measured-minimum regression coverage and explicit missing-Cargo handling. The specific dependency MSRV mentioned by Fable was from memory and is not a verified finding.
3. TMPDIR changing hardware evidence: accepted. Run the documented default build-storage path, record resource use and stop on exhaustion. Never use installation-target disks as scratch or silently substitute a different user path.
4. Evidence binding: accepted. Record validated revisions and script checksums. Final runtime changes beyond warning recognition/messages/call sites/comments require affected-workflow revalidation. The minimum real-host pass combination and exact warning text are now specified.
5. Conditional helper tests: accepted. Direct helper characterization is unconditional in Task 2; demonstrated defects then get failing regressions and fixes in Task 3. A direct nmstate helper reuse result must not be confused with the main flow, which ensures Rust first today.
6. Runner isolation/capabilities/tags: accepted. Fake engines use an isolated PATH; preserve apt's normal rootless-container capabilities. Record both matrix image tags/digests. The Debian 13 non-slim research image does not stand in for future slim regression results.
7. Assisted shutdown handoff: accepted as a hypothesis requiring observation. Capture userspace/kernel evidence and failure signatures on the live host. No change to assisted invocation is justified by reviewer memory alone; any resulting fix needs Bookworm hardware retesting.
8. Reproduction/evidence: accepted with scope limits. Exact successful build command and source identity are in README.md; raw logs/advisor transcripts remain local persistent files excluded by .gitignore. Checksums accompany the sanitized summary. Runtime command identity, per-container IDs, storage peaks, minimal dependencies, apt toolchain and kexec package installation remain required future evidence. Version/help checks do not imply gc/validate on real networkConfig or PXE success.
9. Metadata and docs: accepted. Capture actual Rescue metadata, handle single/double/unquoted values without execution, update all current dependency explanations and runner diagnostics, and extend the explicit documentation-command guard to the new runbook. Historical plans remain untouched.

No provisioning scripts were modified, no real server was provisioned, and no support declaration or issue closure follows from this planning review. The next step is user review of the proposed design/plan.

## Implementation review response after user approval

The preceding section describes the planning review. The user subsequently approved preparatory tests and confirmed runtime fixes. Fable then reviewed the implementation; the complete review is preserved locally in `fable-implementation-advice.md`. The parent resolves its findings below without claiming a second reviewer sign-off.

- I1: reproduced with a failing fake rustc and fixed. A failed/empty rustc version query now selects rustup instead of aborting on the command substitution. The new regression failed before the change and passed after it.
- I2/I3: the real Bookworm container probe at exactly Rust 1.88.0 passed, including building the pinned crate and its locked dependencies, with final status 0. This covers the declared floor and the supported distro's actual build path together; it is separate from hardware validation.
- M3: preserve the legacy wrapper's ignored arguments; added a failing regression before restoring that behavior.
- M6/M8: fake tools run with an explicit minimal environment; engine argument recordings are sorted numerically.
- M7: compiler diagnostics must name gcc and libc6-dev; failure diagnostics must identify the failing image. A new behavioral test executes the actual container payload with a failing apt stand-in and passing later commands, proving that an apt failure stops execution rather than being masked. No real package operations run on the host.
- M11: use fully qualified docker.io/library image names to avoid rootless Podman short-name prompts; engine-call assertions failed before the change and pass afterward.
- M12: final evidence checksums and verification records replace the stale planning-only check. The real distro-Rust upgrade probe succeeded with rustup's `-y` behavior despite a distro installation warning; synthetic tests do not establish that behavior.

Deferred minor observations: main still ensures Rust before checking reusable nmstatectl; no new main-flow dependency ordering test was added beyond direct-helper failure tests and the existing main tests; the floor remains local to the existing helper; a user-pinned rustup override can still produce Cargo's minimum-version error; header availability beyond cc is checked by the actual build; interruption signal policy is unchanged. These are existing behaviors or separate follow-ups, not reasons to change the supported distro claim. No automatic compiler-package installation or broad dependency refactor was introduced.

The reviewer declined hardware/kernel/kexec behavior, package contents of real Rescue, task-1 kexec-tools installation probes, support-warning changes and pre-existing mount/login-shell behavior. Those remain explicitly unvalidated and outside the approved preparatory changes.
