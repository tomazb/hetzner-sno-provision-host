# PXE preflight verification

The change starts from `fix/debian-trixie-preparation` at `2099e8a`. The
reported failures are recorded in [issue #17](https://github.com/tomazb/hetzner-sno-provision-host/issues/17).

- `./scripts/test-debian-container.sh all` exited 0. Syntax checks,
  ShellCheck, and all four regression suites passed in Debian 12 and 13.
  The output is in `debian-matrix.log`.
- The expanded Trixie probe started with no Python, `ip`, `curl`, or C
  compiler. A dry run reported the missing validation tools. A real run
  installed `python3`, `iproute2`, `curl`, `ca-certificates`, `gcc`, and
  `libc6-dev` in one apt transaction before prompting for an OpenShift
  version. Closing stdin at that prompt left the config file and work
  directory absent. An unknown interface exited before prompting or
  invoking apt. Rustup installed Rust 1.100.0, Cargo built the pinned
  `nmstatectl` in 2m46s, and the binary reported version 2.2.60. The probe
  exited 0. The output is in `trixie-dependencies.log`.

Run the probe from the repository root with Podman and the Debian 13 slim
image already available locally. The build needs access to Debian package
repositories, Rustup, and crates.io.

```bash
podman run --rm --pull=never --user 0 --cpus=2 --memory=4g --pids-limit=512 \
  --security-opt label=disable \
  -v "$PWD:/work:ro" docker.io/library/debian:13-slim \
  bash /work/docs/superpowers/evidence/2026-11-19-prepare-preflight/probe-trixie.bash
```

The checks stopped short of generating PXE artifacts or booting OpenShift.
