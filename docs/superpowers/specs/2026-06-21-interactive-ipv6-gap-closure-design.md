# Interactive IPv6 gap closure

**Date:** 2026-06-21
**Status:** Spec reviewed, pending user review
**Target script:** `hetzner-sno-prepare-pxe.sh`

## Problem

The prepare script already supports IPv4-only, IPv6-only, and dual-stack
networking for the OpenShift agent-based installer. The remaining gaps are not
in the core network model or YAML generation; they are in the interactive
surface and its documentation:

- `--interactive` prompts for IPv4 fields, IPv6 fields, and then the IP family.
  That order is technically usable but confusing because the family choice
  comes after the fields it should control.
- Interactive mode always shows both IPv4 and IPv6 address prompts, even when
  the user wants a single-family cluster.
- `EXAMPLE-SESSION.md` still shows the older IPv4-only prompt flow, so the docs
  understate current IPv6 and dual-stack support.
- The replay-command IPv6 test passes, but its fixture omits positional values
  that `print_replay_command` expects, producing avoidable unbound-variable
  stderr noise during the test run.

## Goals

- Make interactive networking prompts reflect the configured family:
  IPv4-only prompts for IPv4 fields, IPv6-only prompts for IPv6 fields, and
  dual-stack prompts for both.
- Ask for the IP family before family-specific address fields.
- Preserve existing CLI behavior, defaults, auto-detection, YAML generation, and
  replay output semantics.
- Update examples and tests so the repository clearly demonstrates interactive
  IPv6-only and dual-stack support.
- Clean up the replay-command test fixture so the prepare test suite runs
  without unrelated stderr noise.

## Non-goals

- Redesigning the whole interactive flow into a full wizard.
- Prompting for `--cluster-network` or `--service-network` overrides in
  interactive mode. Those remain advanced CLI options.
- Changing OpenShift network defaults, IPv4-primary dual-stack ordering,
  `rendezvousIP` selection, DNS filtering, or generated YAML structure.
- Changing the agent-based kexec script. Its `--interactive` mode only selects
  the artifact directory; network configuration belongs to the prepare script.

## Current State

The existing implementation has the required IPv6 plumbing:

- `prompt_for_missing_config` has fields for IPv4, IPv6, and `IP_FAMILY_OVERRIDE`.
- `validate_ip_family` rejects inconsistent family/address combinations.
- `resolve_network_config` activates v4, v6, or both; blank family still defaults
  to IPv4-only auto-detection.
- `discover_ipv6` detects an IPv6 prefix/gateway and proposes a stable host
  address.
- `generate_install_config` and `generate_agent_config` loop over normalized
  per-family records.
- `print_resolved_config` and `print_replay_command` include IPv6 fields when
  IPv6 is active.

Because this foundation is already present, the implementation should be a
small interactive-layer change plus docs/tests.

## Approaches Considered

### Recommended: focused gap close plus targeted cleanup

Move the IP-family prompt before the address prompts, conditionally prompt only
for relevant address families, update docs/examples, and fix the noisy replay
test fixture.

This has the best risk profile because it leaves the working network resolution
and YAML generation paths alone.

### Docs and tests only

Document the current behavior and add more coverage without changing prompts.
This is the smallest change, but it keeps the awkward UX where family selection
comes after family-specific fields.

### Broader interactive wizard

Create a more guided interactive experience with staged network choices and
advanced network override prompts. This would improve ergonomics more, but it
touches more surface area than the current gap requires.

## Design

### Prompt flow

Keep the existing high-level `prompt_for_missing_config` sequence. Only the
network prompt block changes.

Current network block:

1. Rendezvous IP
2. Network interface
3. IPv4 address with prefix
4. Gateway
5. IPv6 address with prefix
6. IPv6 gateway
7. IP family

New network block:

1. Rendezvous IP
2. Network interface
3. IP family (`v4`, `v6`, `dual`, blank = auto)
4. IPv4 address with prefix, when the family is blank/auto, `v4`, or `dual`
5. IPv4 gateway, when the family is blank/auto, `v4`, or `dual`
6. IPv6 address with prefix, when the family is `v6` or `dual`
7. IPv6 gateway, when the family is `v6` or `dual`

Blank IP family keeps the existing default: IPv4-only auto-detection. It should
therefore prompt for IPv4 fields and skip IPv6 fields. A user who wants IPv6
auto-detection chooses `v6`; a user who wants dual-stack chooses `dual`.
When saved address defaults exist, blank family should infer the prompt family
from those saved values: saved IPv6-only defaults imply `v6`, and saved IPv4 +
IPv6 defaults imply `dual`. A fresh run with no saved address values still
keeps the existing IPv4-only blank-family behavior.

### Saved config behavior

Saved values should keep their current role as prompt defaults. When a saved
`IP_FAMILY_OVERRIDE` exists, the prompt uses it as the default and the
conditional prompts follow the effective family value.

When the saved family is blank, the prompt should derive the effective family
from current or saved address defaults: IPv4-only stays `v4`, IPv6-only becomes
`v6`, and having both becomes `dual`. If neither current nor saved address
exists, the effective family remains blank so a fresh interactive run still
defaults to IPv4-only auto-detection.

### Validation

Reuse existing validation:

- `parse_args` still restricts CLI `--ip-family` to `v4`, `v6`, or `dual`.
- `validate_ip_family` remains the guard for interactive input and rejects any
  other family string.
- Existing conflict checks remain unchanged.

Add small local helper functions that return whether a family should prompt for
IPv4 or IPv6. They stay in `hetzner-sno-prepare-pxe.sh`; this does not create a
new sourced library.

### Replay test cleanup

Update `test_print_replay_command_includes_ipv6_flags` to set all positional
values read by `print_replay_command`:

- `OCP_VERSION`
- `PULL_SECRET_FILE`
- `BASE_DOMAIN`
- `CLUSTER_NAME`
- `RENDEZVOUS_IP`

This is not a production-code change; it removes misleading test stderr while
keeping the existing assertions.

### Documentation

Update `EXAMPLE-SESSION.md` so the sample interactive prompt sequence matches
the new flow. The main walkthrough can remain IPv4-only, but it must include the
new `IP family` prompt before the address fields.

Add a concise IPv6-focused section to `EXAMPLE-SESSION.md` after the main
walkthrough, and make the README point to it from the IPv6 and dual-stack
section:

- IPv6-only interactive: choose `v6`, leave IPv6 address and gateway blank to
  auto-detect, resolved config shows IPv6/prefix and IPv6 gateway, replay command
  includes `--ip-family v6`, `--ipv6-with-prefix`, and `--ipv6-gateway`.
- Dual-stack interactive: choose `dual`, provide or accept both families, replay
  command includes both IPv4 and IPv6 flags and keeps IPv4 primary.

## Testing

Add focused shell tests in `tests/test-hetzner-sno-prepare-pxe.sh`:

- Interactive prompt order includes `IP family` before IPv4/IPv6 address prompts.
- Blank family prompts for IPv4 fields and skips IPv6 fields.
- `v4` prompts for IPv4 fields and skips IPv6 fields.
- `v6` skips IPv4 fields and prompts for IPv6 fields.
- `dual` prompts for both IPv4 and IPv6 fields.
- Existing invalid-family validation continues to reject values such as `ipv6`.
- Replay-command IPv6 test emits no unbound-variable stderr from missing
  positional values.

Run the prepare-script test suite after implementation:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh
```

If docs change only markdown files, no extra runtime verification is required
beyond reviewing the rendered prompt transcript for consistency with the script.

## Risks

- Prompt tests can become brittle if they assert too much exact prose. Keep them
  focused on ordering and presence/absence of family-specific prompts.
- Saved address defaults now influence blank-family prompt gating. Keep that
  inference limited to current/saved address presence so a fresh run with no
  saved addresses still preserves IPv4-only auto-detection.
- Changing prompt order can affect users who rely on pasted interactive input.
  This is acceptable because replay commands and CLI flags are the supported
  automation path; interactive mode is for TTY-guided use.

## Acceptance Criteria

- Interactive mode asks for IP family before address/gateway prompts.
- Interactive mode only asks for address families selected by the effective
  family value.
- Blank family still means IPv4-only auto-detect.
- CLI behavior and generated YAML output are unchanged for existing flag-based
  runs.
- README/example material accurately shows IPv6-aware interactive behavior.
- The prepare-script test suite passes without the replay-command unbound
  variable noise observed before this work.
