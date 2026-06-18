# Feature comparison

How this fork (`tomazb/hetzner-sno-provision-host`) compares to upstream
(`palonsoro/hetzner-sno-provision-host`).

Upstream is two lean kexec-bootstrap scripts (~24–28 lines each) that you drive
manually. This fork adds a hardened, interactive, validated installer pipeline
that also generates the PXE artifacts and is test-covered (~302 lines per script
plus a dedicated prepare script).

## Killer features

| Feature | palonsoro (upstream) | tomazb (fork) |
|---|---|---|
| **End-to-end prepare script** (`hetzner-sno-prepare-pxe.sh`) | ✗ — you generate PXE artifacts yourself | ✓ installs `nmstatectl` (via cargo), downloads version-matched `oc`/`openshift-install`, generates `install-config.yaml`/`agent-config.yaml`, runs `agent create pxe-files`, copies artifacts |
| **Checksum verification** of downloaded OCP tools | ✗ | ✓ SHA256-validated |
| **Interactive mode** | ✗ | ✓ `--interactive` with prompts and saved-config replay |
| **Credential auto-discovery** (pull secret, SSH key) | ✗ | ✓ up-front presence report + live re-discovery, numbered menu, paste-key support |
| **Fail-fast validation** | ✗ | ✓ inputs / SSH / pull-secret validated before network probing and downloads |
| **IPv6-aware DNS handling** | ✗ | ✓ filters DNS to the interface address family (avoids nmstate failure), family-matched fallback |
| **Install-disk handling** | manual | ✓ auto-detect, multi-disk numbered selection, `--disk-device` override |
| **`--dry-run`** | ✗ | ✓ validate and print the plan with no writes |
| **Replay command** | ✗ | ✓ prints the exact non-interactive command to reproduce a run |
| **Tests + CI harness** | ✗ | ✓ unit tests plus a Debian-12 container test runner |
| **Documentation** | single README | ✓ README + QUICK-START + EXAMPLE-SESSION + FIREWALL |
| **Robustness** | minimal | ✓ `set -euo pipefail`, signal/cleanup traps, root/arch/OS checks, secret files chmod 600 |

## One-liner

Upstream is a lean kexec bootstrap you drive manually; this fork is a hardened,
interactive, validated installer pipeline that also generates the PXE artifacts
and is test-covered.
