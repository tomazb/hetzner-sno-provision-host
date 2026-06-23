# Final Review Fix Report

## Changes Made

- Retargeted the no-CSI byte-identical regression guard in `tests/test-hetzner-sno-prepare-pxe.sh` from the older historical commit `9c53635` to the current feature-base commit `9f8dfc7`.
- Updated the baseline comparison setup so both sides use the `9f8dfc7` config-generation contract, including `NET_FAMILIES_JSON`, `ACTIVE_V4`, `ACTIVE_V6`, and the empty CSI serial path for the no-CSI case.
- Added an end-to-end `main --dry-run --csi-reserve-size 800G ...` test that stubs disk resolution and reports deferred CSI split validation when the install disk size is unavailable.
- Tightened the `--csi-min-root-size` short help text in `hetzner-sno-prepare-pxe.sh` to describe the minimum OpenShift-side disk offset before the raw partition.
- Added a usage assertion to lock the new help wording in place.

## Verification

- `./tests/test-hetzner-sno-prepare-pxe.sh` passed.
- `./tests/test-hetzner-sno-hardening.sh` passed.
- `git diff --check` passed.

## Notes

- The hardening suite emitted the expected local-environment warnings about Debian 12 / rescue-host detection, but the suite still completed successfully.
