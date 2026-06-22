# Interactive IPv6 Gap Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `hetzner-sno-prepare-pxe.sh --interactive` ask for IP family before address fields, show only the relevant IPv4/IPv6 prompts, and update tests/docs to reflect the IPv6-aware flow.

**Architecture:** Keep the existing network resolution, validation, YAML generation, DNS filtering, and replay output intact. Add small local prompt helper functions in `hetzner-sno-prepare-pxe.sh`, then use them inside `prompt_for_missing_config` to control only the interactive prompt surface. Tests exercise prompt output without running the full installer.

**Tech Stack:** Bash 4+, Python 3 for existing test assertions, markdown documentation, existing custom shell test harness in `tests/test-hetzner-sno-prepare-pxe.sh`.

## Global Constraints

- Blank IP family keeps the existing default: IPv4-only auto-detection.
- CLI behavior, generated YAML, DNS filtering, IPv4-primary dual-stack ordering, and `rendezvousIP` selection must not change.
- Interactive mode must not prompt for `--cluster-network` or `--service-network`; those remain advanced CLI options.
- Network configuration changes belong only to `hetzner-sno-prepare-pxe.sh`; do not change `hetzner-sno-provision-host-agentbased.sh`.
- Keep helper functions local to `hetzner-sno-prepare-pxe.sh`; do not create a sourced library.
- Preserve the untracked `.claude/` directory if present; do not add, edit, or delete it.

---

## File Structure

- Modify `hetzner-sno-prepare-pxe.sh`: add prompt-family helper functions, make `prompt_for_missing_config` ask `IP_FAMILY_OVERRIDE` before address prompts, and reuse the existing validation message for invalid family values.
- Modify `tests/test-hetzner-sno-prepare-pxe.sh`: add prompt-flow tests, add run-test registrations, and clean the IPv6 replay-command test fixture.
- Modify `EXAMPLE-SESSION.md`: update the main interactive transcript and add concise IPv6-only/dual-stack interactive variants.
- Modify `README.md`: point IPv6/dual-stack readers to the interactive examples.

---

### Task 1: Conditional Interactive IP Family Prompts

**Files:**
- Modify: `tests/test-hetzner-sno-prepare-pxe.sh`
- Modify: `hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: existing `prompt_for_missing_config`, `prompt_optional_value`, `validate_ip_family`, and shell test harness `run_test`.
- Produces: local shell helpers `validate_ip_family_value`, `prompt_effective_ip_family`, `prompt_family_includes_ipv4`, and `prompt_family_includes_ipv6`.

- [ ] **Step 1: Write failing prompt-flow tests**

In `tests/test-hetzner-sno-prepare-pxe.sh`, add this helper and tests after `test_prompt_file_choice_aborts_on_eof` and before `test_parse_args_sets_disk_serial_override`:

```bash
capture_network_prompt_flow() {
  local family_input="$1"
  local temp_dir output status

  temp_dir="$(mktemp -d)"
  output="$(
    PROMPT_FAMILY_INPUT="$family_input" SNO_CONFIG_FILE="${temp_dir}/config" HSPPXE_TEST_MODE=1 bash -c '
      source "'"${SCRIPT}"'"
      can_prompt() { return 0; }
      report_credential_presence() { :; }
      OCP_VERSION="4.22.1"
      PULL_SECRET_FILE="/tmp/pull-secret.json"
      BASE_DOMAIN="example.com"
      CLUSTER_NAME="sno"
      HOSTNAME_OVERRIDE="node.example.com"
      SSH_PUB_KEY="ssh-ed25519 AAAA"
      ARTIFACT_DIR="/root"
      BIN_DIR="/usr/local/bin"
      DNS_SERVERS_OVERRIDE=("8.8.8.8")
      INTERACTIVE=1
      {
        printf "\n"
        printf "\n"
        printf "%s\n" "$PROMPT_FAMILY_INPUT"
        printf "\n\n\n\n\n"
      } | prompt_for_missing_config
    ' 2>&1
  )"
  status=$?
  rm -rf "${temp_dir}"
  [[ "${status}" -eq 0 ]] || { printf "%s\n" "$output"; return "${status}"; }
  printf "%s\n" "$output"
}

test_prompt_for_missing_config_orders_family_before_addresses() {
  local output
  output="$(capture_network_prompt_flow "")"
  PROMPT_OUTPUT="$output" python3 - <<'PY'
import os
out = os.environ["PROMPT_OUTPUT"]
assert out.index("IP family") < out.index("IPv4 address with prefix"), out
PY
}

test_prompt_for_missing_config_blank_family_prompts_ipv4_only() {
  local output
  output="$(capture_network_prompt_flow "")"
  [[ "$output" == *"IP family (v4, v6, dual; blank = auto): "* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"IP family (v4, v6, dual; blank = auto) (leave blank to auto-detect)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"IPv4 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"Gateway (leave blank to auto-detect)"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"IPv6 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"IPv6 gateway"* ]] || { echo "$output"; return 1; }
}

test_prompt_for_missing_config_v4_family_prompts_ipv4_only() {
  local output
  output="$(capture_network_prompt_flow "v4")"
  [[ "$output" == *"IPv4 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"Gateway (leave blank to auto-detect)"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"IPv6 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"IPv6 gateway"* ]] || { echo "$output"; return 1; }
}

test_prompt_for_missing_config_v6_family_prompts_ipv6_only() {
  local output
  output="$(capture_network_prompt_flow "v6")"
  [[ "$output" != *"IPv4 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"Gateway (leave blank to auto-detect)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"IPv6 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"IPv6 gateway"* ]] || { echo "$output"; return 1; }
}

test_prompt_for_missing_config_dual_family_prompts_both_families() {
  local output
  output="$(capture_network_prompt_flow "dual")"
  [[ "$output" == *"IPv4 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"Gateway (leave blank to auto-detect)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"IPv6 address with prefix"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"IPv6 gateway"* ]] || { echo "$output"; return 1; }
}
```

Add these registrations in the early `run_test` block, immediately after:

```bash
run_test "parse_args leaves cluster name empty when omitted" test_parse_args_leaves_cluster_name_empty_when_omitted
```

```bash
run_test "prompt_for_missing_config orders family before addresses" test_prompt_for_missing_config_orders_family_before_addresses
run_test "prompt_for_missing_config blank family prompts IPv4 only" test_prompt_for_missing_config_blank_family_prompts_ipv4_only
run_test "prompt_for_missing_config v4 family prompts IPv4 only" test_prompt_for_missing_config_v4_family_prompts_ipv4_only
run_test "prompt_for_missing_config v6 family prompts IPv6 only" test_prompt_for_missing_config_v6_family_prompts_ipv6_only
run_test "prompt_for_missing_config dual family prompts both families" test_prompt_for_missing_config_dual_family_prompts_both_families
```

- [ ] **Step 2: Run the prompt-flow tests and verify they fail**

Run:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: nonzero exit. The output includes these failures before implementation:

```text
not ok - prompt_for_missing_config orders family before addresses
not ok - prompt_for_missing_config blank family prompts IPv4 only
not ok - prompt_for_missing_config v4 family prompts IPv4 only
not ok - prompt_for_missing_config v6 family prompts IPv6 only
```

`prompt_for_missing_config dual family prompts both families` may pass before implementation because the current prompt flow always asks both families.

- [ ] **Step 3: Add local prompt-family helpers**

In `hetzner-sno-prepare-pxe.sh`, add these functions immediately after `prompt_optional_value`:

```bash
validate_ip_family_value() {
  local family="${1:-}"
  case "$family" in
    ""|v4|v6|dual)
      return 0
      ;;
    *)
      die "--ip-family must be v4, v6, or dual (got '$family')."
      return 1
      ;;
  esac
}

prompt_effective_ip_family() {
  local family="${IP_FAMILY_OVERRIDE:-}"
  local has_v4=0
  local has_v6=0

  if [[ -n "$family" ]]; then
    printf '%s\n' "$family"
    return 0
  fi

  [[ -n "${IP_WITH_PREFIX_OVERRIDE:-${_SAVED[IP_WITH_PREFIX_OVERRIDE]:-}}" ]] && has_v4=1
  [[ -n "${IPV6_WITH_PREFIX_OVERRIDE:-${_SAVED[IPV6_WITH_PREFIX_OVERRIDE]:-}}" ]] && has_v6=1

  if [[ "$has_v4" -eq 1 && "$has_v6" -eq 1 ]]; then
    printf 'dual\n'
  elif [[ "$has_v6" -eq 1 ]]; then
    printf 'v6\n'
  elif [[ "$has_v4" -eq 1 ]]; then
    printf 'v4\n'
  else
    printf '\n'
  fi
}

prompt_family_includes_ipv4() {
  local family="${1:-}"
  [[ -z "$family" || "$family" == "v4" || "$family" == "dual" ]]
}

prompt_family_includes_ipv6() {
  local family="${1:-}"
  [[ "$family" == "v6" || "$family" == "dual" ]]
}
```

Then update `validate_ip_family` so it reuses the enum check instead of carrying a separate default case. Replace its opening and final default branch with this shape:

```bash
validate_ip_family() {
  local family="${IP_FAMILY_OVERRIDE:-}"
  validate_ip_family_value "$family" || return 1
  [[ -z "$family" ]] && return 0

  local has_v4=0 has_v6=0
  [[ -n "${IP_WITH_PREFIX_OVERRIDE:-}" ]] && has_v4=1
  [[ -n "${IPV6_WITH_PREFIX_OVERRIDE:-}" ]] && has_v6=1

  case "$family" in
    v4)
      if [[ "$has_v6" -eq 1 ]]; then
        die "--ip-family v4 conflicts with --ipv6-with-prefix."
        return 1
      fi
      ;;
    v6)
      if [[ "$has_v4" -eq 1 ]]; then
        die "--ip-family v6 conflicts with --ip-with-prefix."
        return 1
      fi
      ;;
    dual)
      if [[ "$has_v4" -eq 1 && "$has_v6" -eq 0 ]]; then
        die "--ip-family dual requires --ipv6-with-prefix in addition to the IPv4 address."
        return 1
      fi
      if [[ "$has_v6" -eq 1 && "$has_v4" -eq 0 ]]; then
        die "--ip-family dual requires --ip-with-prefix in addition to the IPv6 address."
        return 1
      fi
      ;;
  esac
}
```

- [ ] **Step 4: Reorder and gate the network prompts**

In `prompt_for_missing_config`, replace the current seven-line network prompt block:

```bash
  prompt_optional_value OVERRIDE_IP "Rendezvous IP" "${_SAVED[OVERRIDE_IP]:-}"
  prompt_optional_value NETWORK_INTERFACE_OVERRIDE "Network interface" "${_SAVED[NETWORK_INTERFACE_OVERRIDE]:-}"
  prompt_optional_value IP_WITH_PREFIX_OVERRIDE "IPv4 address with prefix" "${_SAVED[IP_WITH_PREFIX_OVERRIDE]:-}"
  prompt_optional_value GATEWAY_OVERRIDE "Gateway" "${_SAVED[GATEWAY_OVERRIDE]:-}"
  prompt_optional_value IPV6_WITH_PREFIX_OVERRIDE "IPv6 address with prefix" "${_SAVED[IPV6_WITH_PREFIX_OVERRIDE]:-}"
  prompt_optional_value IPV6_GATEWAY_OVERRIDE "IPv6 gateway" "${_SAVED[IPV6_GATEWAY_OVERRIDE]:-}"
  prompt_optional_value IP_FAMILY_OVERRIDE "IP family (v4, v6, dual; blank = auto)" "${_SAVED[IP_FAMILY_OVERRIDE]:-}"
```

with:

```bash
  prompt_optional_value OVERRIDE_IP "Rendezvous IP" "${_SAVED[OVERRIDE_IP]:-}"
  prompt_optional_value NETWORK_INTERFACE_OVERRIDE "Network interface" "${_SAVED[NETWORK_INTERFACE_OVERRIDE]:-}"
  if [[ -n "${IP_FAMILY_OVERRIDE:-}" ]]; then
    :
  elif [[ -n "${_SAVED[IP_FAMILY_OVERRIDE]:-}" ]]; then
    prompt_optional_value IP_FAMILY_OVERRIDE "IP family (v4, v6, dual; blank = auto)" "${_SAVED[IP_FAMILY_OVERRIDE]:-}"
  else
    printf 'IP family (v4, v6, dual; blank = auto): ' >&2
    read -r IP_FAMILY_OVERRIDE
  fi
  validate_ip_family_value "${IP_FAMILY_OVERRIDE:-}" || return 1

  local prompt_ip_family
  prompt_ip_family="$(prompt_effective_ip_family)"
  if prompt_family_includes_ipv4 "$prompt_ip_family"; then
    prompt_optional_value IP_WITH_PREFIX_OVERRIDE "IPv4 address with prefix" "${_SAVED[IP_WITH_PREFIX_OVERRIDE]:-}"
    prompt_optional_value GATEWAY_OVERRIDE "Gateway" "${_SAVED[GATEWAY_OVERRIDE]:-}"
  fi
  if prompt_family_includes_ipv6 "$prompt_ip_family"; then
    prompt_optional_value IPV6_WITH_PREFIX_OVERRIDE "IPv6 address with prefix" "${_SAVED[IPV6_WITH_PREFIX_OVERRIDE]:-}"
    prompt_optional_value IPV6_GATEWAY_OVERRIDE "IPv6 gateway" "${_SAVED[IPV6_GATEWAY_OVERRIDE]:-}"
  fi
```

- [ ] **Step 5: Run the test suite and verify prompt-flow behavior passes**

Run:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: exit 0. The prompt-flow tests print:

```text
ok - prompt_for_missing_config orders family before addresses
ok - prompt_for_missing_config blank family prompts IPv4 only
ok - prompt_for_missing_config v4 family prompts IPv4 only
ok - prompt_for_missing_config v6 family prompts IPv6 only
ok - prompt_for_missing_config dual family prompts both families
```

The suite may still print existing `unbound variable` stderr from `test_print_replay_command_includes_ipv6_flags`; Task 2 removes that noise.

- [ ] **Step 6: Commit the prompt-flow change**

Run:

```bash
git add hetzner-sno-prepare-pxe.sh tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Improve interactive IP family prompts"
```

Expected: commit succeeds with only those two files staged.

---

### Task 2: Clean IPv6 Replay-Command Test Noise

**Files:**
- Modify: `tests/test-hetzner-sno-prepare-pxe.sh`

**Interfaces:**
- Consumes: existing `print_replay_command`.
- Produces: `test_print_replay_command_includes_ipv6_flags` fixture with complete variables and an explicit empty-stderr assertion.

- [ ] **Step 1: Confirm the current noisy behavior**

Run:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'unbound variable'
```

Expected before this task:

```text
/home/tomaz/sources/hetzner-sno-provision-host/hetzner-sno-prepare-pxe.sh: line 1783: OCP_VERSION: unbound variable
/home/tomaz/sources/hetzner-sno-provision-host/hetzner-sno-prepare-pxe.sh: line 1783: PULL_SECRET_FILE: unbound variable
/home/tomaz/sources/hetzner-sno-provision-host/hetzner-sno-prepare-pxe.sh: line 1783: BASE_DOMAIN: unbound variable
/home/tomaz/sources/hetzner-sno-provision-host/hetzner-sno-prepare-pxe.sh: line 1783: CLUSTER_NAME: unbound variable
/home/tomaz/sources/hetzner-sno-provision-host/hetzner-sno-prepare-pxe.sh: line 1783: RENDEZVOUS_IP: unbound variable
```

- [ ] **Step 2: Replace the replay-command IPv6 test**

Replace `test_print_replay_command_includes_ipv6_flags` with:

```bash
test_print_replay_command_includes_ipv6_flags() {
  local err_file status
  err_file="$(mktemp)"

  HSPPXE_TEST_MODE=1 bash -c '
    source "'"${SCRIPT}"'"
    SCRIPT_NAME="hetzner-sno-prepare-pxe.sh"
    OCP_VERSION="4.22.1"
    PULL_SECRET_FILE="/root/pull-secret.json"
    BASE_DOMAIN="example.com"
    CLUSTER_NAME="sno"
    NODE_HOSTNAME="node.example.com"; SSH_PUBLIC_KEY_FILE="/root/id.pub"
    DEFAULT_IFACE="eth0"
    IP_WITH_PREFIX="192.0.2.10/24"; GATEWAY="192.0.2.1"
    ACTIVE_V4=1; ACTIVE_V6=1
    IPV6_WITH_PREFIX="2a01:db8::1/64"; IPV6_GATEWAY="fe80::1"
    IP_FAMILY_OVERRIDE="dual"
    RENDEZVOUS_IP="192.0.2.10"
    DNS_SERVERS=("8.8.8.8"); INSTALL_DISK="/dev/nvme0n1"
    ARTIFACT_DIR="/root"; BIN_DIR="/usr/local/bin"
    CLUSTER_NETWORKS=(); SERVICE_NETWORKS=()
    out="$(print_replay_command)"
    [[ "$out" == *"--ipv6-with-prefix 2a01:db8::1/64"* ]] || { echo "no v6 prefix: $out"; exit 1; }
    [[ "$out" == *"--ipv6-gateway fe80::1"* ]] || { echo "no v6 gw"; exit 1; }
    [[ "$out" == *"--ip-family dual"* ]] || { echo "no family"; exit 1; }
  ' 2>"${err_file}"
  status=$?
  if [[ "${status}" -ne 0 ]]; then
    cat "${err_file}"
    rm -f "${err_file}"
    return "${status}"
  fi
  if [[ -s "${err_file}" ]]; then
    cat "${err_file}"
    rm -f "${err_file}"
    return 1
  fi
  rm -f "${err_file}"
}
```

- [ ] **Step 3: Verify the noise is gone**

Run:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'unbound variable'
```

Expected: no output and exit 1 from `grep`. Then run the full suite:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: exit 0 and `ok - print_replay_command includes ipv6 flags`.

- [ ] **Step 4: Commit the test cleanup**

Run:

```bash
git add tests/test-hetzner-sno-prepare-pxe.sh
git commit -m "Clean IPv6 replay command test fixture"
```

Expected: commit succeeds with only the test file staged.

---

### Task 3: Update Interactive IPv6 Documentation

**Files:**
- Modify: `EXAMPLE-SESSION.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: prompt labels from `hetzner-sno-prepare-pxe.sh`.
- Produces: docs that show the new prompt order and concise IPv6-only/dual-stack interactive variants.

- [ ] **Step 1: Update the main interactive transcript prompt order**

In `EXAMPLE-SESSION.md`, change the prompt block near the start from:

```console
Rendezvous IP (leave blank to auto-detect):
Network interface (leave blank to auto-detect):
IPv4 address with prefix (leave blank to auto-detect):
Gateway (leave blank to auto-detect):
Node hostname: sno.example.com
```

to:

```console
Rendezvous IP (leave blank to auto-detect):
Network interface (leave blank to auto-detect):
IP family (v4, v6, dual; blank = auto):
IPv4 address with prefix (leave blank to auto-detect):
Gateway (leave blank to auto-detect):
Node hostname: sno.example.com
```

Do not add IPv6 prompts to the main transcript; a fresh blank family with no saved addresses remains IPv4-only and skips IPv6 prompts.

- [ ] **Step 2: Add IPv6 and dual-stack interactive variants**

After the paragraph `At this point, copy the **kubeadmin password** and save the **kubeconfig** to \`~/.kube/config\` on your workstation.`, add:

````markdown
### IPv6 and dual-stack interactive variants

For an IPv6-only cluster, choose `v6` at the family prompt and leave the IPv6
address/gateway blank to use the rescue-system auto-detection:

```console
IP family (v4, v6, dual; blank = auto): v6
IPv6 address with prefix (leave blank to auto-detect):
IPv6 gateway (leave blank to auto-detect):
Resolved configuration:
  Interface:         enp41s0
  IPv6/prefix:       2a01:4f8:abcd:1234::1/64
  IPv6 gateway:      fe80::1
  IP family:         v6
  Machine network:   2a01:4f8:abcd:1234::/64
  Rendezvous IP:     2a01:4f8:abcd:1234::1
```

The replay command for that run includes the selected family and resolved IPv6
values:

```console
  ./hetzner-sno-prepare-pxe.sh --yes \
  --hostname sno.example.com \
  --ssh-public-key-file /root/.ssh/id_ed25519.pub \
  --network-interface enp41s0 \
  --ipv6-with-prefix 2a01:4f8:abcd:1234::1/64 \
  --ipv6-gateway fe80::1 \
  --ip-family v6 \
  --dns-server 2001:4860:4860::8888 \
  --disk-device /dev/nvme1n1 \
  4.22.1 /root/pull-secret.json example.com sno 2a01:4f8:abcd:1234::1
```

For dual-stack, choose `dual`. IPv4 remains primary, so the resolved
configuration and replay command keep the IPv4 rendezvous IP while adding the
IPv6 address and gateway:

```console
IP family (v4, v6, dual; blank = auto): dual
IPv4 address with prefix (leave blank to auto-detect):
Gateway (leave blank to auto-detect):
IPv6 address with prefix (leave blank to auto-detect):
IPv6 gateway (leave blank to auto-detect):
Resolved configuration:
  IP/prefix:         78.46.123.45/26
  Gateway:           78.46.123.1
  IPv6/prefix:       2a01:4f8:abcd:1234::1/64
  IPv6 gateway:      fe80::1
  IP family:         dual
  Rendezvous IP:     78.46.123.45
```
````

- [ ] **Step 3: Add a README pointer to the interactive examples**

In `README.md`, after the IPv6/dual-stack flag table, add:

```markdown
For interactive IPv6-only and dual-stack prompt examples, see
[EXAMPLE-SESSION.md](EXAMPLE-SESSION.md#ipv6-and-dual-stack-interactive-variants).
```

- [ ] **Step 4: Verify docs match prompt strings**

Run:

```bash
rg -n "IP family|IPv6 address with prefix|IPv6 gateway|ipv6-and-dual-stack-interactive-variants" README.md EXAMPLE-SESSION.md
```

Expected: output includes the README link, the new EXAMPLE heading, the updated main transcript `IP family` line, and the IPv6-only/dual-stack prompt examples.

- [ ] **Step 5: Commit the documentation update**

Run:

```bash
git add EXAMPLE-SESSION.md README.md
git commit -m "Document interactive IPv6 prompt flow"
```

Expected: commit succeeds with only the two markdown files staged.

---

### Task 4: Final Verification

**Files:**
- Verify only; no file edits expected.

**Interfaces:**
- Consumes: all changes from Tasks 1-3.
- Produces: evidence that tests pass, whitespace is clean, and only intended files changed.

- [ ] **Step 1: Run whitespace validation**

Run:

```bash
git diff --check HEAD~3..HEAD
```

Expected: no output and exit 0.

- [ ] **Step 2: Run the prepare-script test suite**

Run:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh
```

Expected: exit 0. The output includes:

```text
ok - prompt_for_missing_config orders family before addresses
ok - prompt_for_missing_config blank family prompts IPv4 only
ok - prompt_for_missing_config v4 family prompts IPv4 only
ok - prompt_for_missing_config v6 family prompts IPv6 only
ok - prompt_for_missing_config dual family prompts both families
ok - print_replay_command includes ipv6 flags
```

- [ ] **Step 3: Verify replay noise is absent**

Run:

```bash
bash tests/test-hetzner-sno-prepare-pxe.sh 2>&1 | grep 'unbound variable'
```

Expected: no output and exit 1 from `grep`.

- [ ] **Step 4: Inspect git status**

Run:

```bash
git status --short
```

Expected: no tracked-file changes. Untracked `.claude/` may appear if it existed before this work; leave it untouched.
