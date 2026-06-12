# Debian 12 Warning Design

## Goal

Warn operators when the Hetzner SNO scripts are not running on Debian 12, because the scripts are tested against the Debian 12-based Hetzner Rescue System and may fail elsewhere.

## Scope

Add a non-blocking compatibility warning to all three entrypoints:

- `hetzner-sno-prepare-pxe.sh`
- `hetzner-sno-provision-host.sh`
- `hetzner-sno-provision-host-agentbased.sh`

Do not block execution. Non-Debian-12 systems, missing `/etc/os-release`, and unreadable OS metadata should warn and continue.

## Behavior

Each script will read OS metadata from `/etc/os-release` by default and expect:

- `ID=debian`
- `VERSION_ID=12`

If either value does not match, the script prints a warning to stderr:

```text
WARNING: This script is tested for Debian 12 Hetzner Rescue. Detected <name>; it may fail.
```

If the metadata file is missing or unreadable, the script prints:

```text
WARNING: Could not read /etc/os-release. This script is tested for Debian 12 Hetzner Rescue and may fail on other systems.
```

The check runs in both normal and `--dry-run` paths, immediately after the existing architecture check. It does not prompt and is safe for CI and automation.

## Implementation Shape

Add a small helper named `warn_if_not_debian_12` to each script, matching the current local-helper style already used for `require_arch`, `require_root`, and `require_commands`.

For testability, the helper will use `OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"`, so tests can point it at temporary files without depending on the host OS.

## Tests

Extend `tests/test-hetzner-sno-hardening.sh` with focused checks:

- Debian 12 metadata produces no warning.
- Non-Debian metadata produces a warning and exits successfully.
- Missing metadata produces a warning and exits successfully.

The tests should source one script helper rather than execute package-install or `kexec` paths.

## Documentation

Update `README.md` troubleshooting notes to state that Debian 12 Hetzner Rescue is the tested runtime and other distributions may fail despite the warning being non-blocking.
