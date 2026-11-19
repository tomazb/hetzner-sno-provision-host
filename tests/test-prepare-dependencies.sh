#!/bin/bash
# Exercise real helpers with isolated toolchains; never download or install on the host.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop())
BASH = shutil.which('bash')
SCRIPT = ROOT / 'hetzner-sno-prepare-pxe.sh'


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='prepare-deps-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        for tool in ('basename', 'dirname', 'awk', 'head', 'sh', 'mkdir', 'chmod', 'cat'):
            (self.bin / tool).symlink_to(shutil.which(tool))
        self.log = self.root / 'calls'
        self.log.touch()
        self.env = dict(HOME=str(self.home), PATH=str(self.bin),
                        HSPPXE_TEST_MODE='1', CALLS=str(self.log),
                        WORKDIR=str(self.root / 'work'), SNO_CONFIG_FILE=str(self.root / 'config'))
        self.tool('cargo', 'printf "cargo %s\\n" "$*" >> "$CALLS"\nexit "${CARGO_STATUS:-0}"')
        self.tool('cc', 'exit 0')
        # Simulate only the remote rustup installer, preserving the helper's pipe/env handling.
        installer = self.root / 'rustup-installer'
        self.env['RUSTUP_FIXTURE'] = str(installer)
        installer.write_text('''set -eu
printf 'rustup %s\\n' "$*" >> "$CALLS"
if [ "${RUSTUP_STATUS:-0}" != 0 ]; then exit "$RUSTUP_STATUS"; fi
mkdir -p "$HOME/.cargo/bin"
printf 'export PATH="%s/.cargo/bin:$PATH"\\n' "$HOME" > "$HOME/.cargo/env"
cat > "$HOME/.cargo/bin/rustc" <<'RUSTC'
#!/bin/sh
printf 'rustc %s (fixture)\\n' "${RUSTUP_FIXTURE_VERSION:-1.99.1}"
RUSTC
cat > "$HOME/.cargo/bin/cargo" <<'CARGO'
#!/bin/sh
printf 'cargo %s\\n' "$*" >> "$CALLS"
exit "${FIXTURE_CARGO_STATUS:-0}"
CARGO
chmod +x "$HOME/.cargo/bin/rustc" "$HOME/.cargo/bin/cargo"
''')
        self.tool('curl', '''printf 'curl %s\\n' "$*" >> "$CALLS"
if [[ "${CURL_STATUS:-0}" != 0 ]]; then exit "$CURL_STATUS"; fi
cat "$RUSTUP_FIXTURE"
''')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    def rust(self, version):
        self.tool('rustc', f"printf 'rustc {version} (Debian source tarball)\\n'")

    def invoke(self, command):
        proc = subprocess.run([BASH, '-c', 'source "$1"; DRY_RUN=0; ' + command,
                               'dependency-test', str(SCRIPT)], env=self.env,
                              text=True, capture_output=True, timeout=15)
        return proc, self.log.read_text()

    def invoke_main(self, *args, omit=()):
        for tool in ('uname', 'lsblk', 'findmnt', 'python3', 'find', 'sort', 'grep',
                     'install', 'tar', 'gzip', 'sha256sum', 'mountpoint', 'rm', 'cp', 'ls'):
            if tool not in omit:
                (self.bin / tool).symlink_to(shutil.which(tool))
        self.env.update(BIN_DIR=str(self.bin), HSPPXE_ALLOW_NON_TTY_INTERACTIVE='1')
        proc = subprocess.run(
            [BASH, '-c', '''
                source "$1"
                shift
                require_root() { :; }
                has_ca_bundle() { [[ -z "${TEST_MISSING_CA:-}" || -f "$HOME/ca-installed" ]]; }
                prompt_for_missing_config() {
                    printf 'SETUP_REACHED interface=%s\n' "$NETWORK_INTERFACE_OVERRIDE"
                    exit 27
                }
                main "$@"
            ''', 'prepare-test', str(SCRIPT), *args],
            env=self.env, text=True, capture_output=True, timeout=15)
        return proc, self.log.read_text()

    def test_missing_curl_is_installed_before_interactive_setup(self):
        (self.bin / 'curl').chmod(0o644)
        self.tool('ip', 'exit 1')
        self.tool('apt-get', '''
printf 'apt-get %s\n' "$*" >> "$CALLS"
if [[ "$1" == install ]]; then chmod +x "${PATH%%:*}/curl"; fi
''')
        proc, calls = self.invoke_main('--interactive', '--yes')
        self.assertEqual(proc.returncode, 27, proc.stderr)
        self.assertIn('SETUP_REACHED', proc.stdout)
        self.assertEqual(calls, 'apt-get update\napt-get install -y --no-install-recommends curl ca-certificates\n')

    def test_missing_curl_without_apt_fails_before_interactive_setup(self):
        (self.bin / 'curl').unlink()
        self.tool('ip', 'exit 1')
        proc, calls = self.invoke_main('--interactive', '--yes')
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn('curl', proc.stderr)
        self.assertIn('ca-certificates', proc.stderr)
        self.assertNotIn('SETUP_REACHED', proc.stdout)
        self.assertFalse((self.root / 'config').exists())
        self.assertEqual(calls, '')

    def test_failed_apt_refresh_stops_before_setup(self):
        (self.bin / 'curl').unlink()
        self.tool('ip', 'exit 1')
        self.tool('apt-get', 'printf "apt-get %s\\n" "$*" >> "$CALLS"; exit 100')
        proc, calls = self.invoke_main('--interactive', '--yes')
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn('apt-get', proc.stderr)
        self.assertNotIn('SETUP_REACHED', proc.stdout)
        self.assertEqual(calls, 'apt-get update\n')

    def test_installs_missing_discovery_tools_and_build_dependencies_together(self):
        self.tool('cc', 'test -f "$HOME/libc-installed"')
        self.tool('apt-get', '''
printf 'apt-get %s\n' "$*" >> "$CALLS"
if [[ "$1" == install ]]; then
    : > "$HOME/libc-installed"
    for name in python3 ip; do
        printf '#!/bin/bash\nexit 0\n' > "${PATH%%:*}/$name"
        chmod +x "${PATH%%:*}/$name"
    done
fi
''')
        proc, calls = self.invoke_main('--interactive', '--yes', omit=('python3',))
        self.assertEqual(proc.returncode, 27, proc.stderr)
        self.assertEqual(calls, 'apt-get update\napt-get install -y --no-install-recommends python3 iproute2 gcc libc6-dev\n')

    def test_missing_ca_bundle_is_installed_with_existing_curl(self):
        self.env['TEST_MISSING_CA'] = '1'
        self.tool('ip', 'exit 1')
        self.tool('apt-get', '''
printf 'apt-get %s\n' "$*" >> "$CALLS"
if [[ "$1" == install ]]; then : > "$HOME/ca-installed"; fi
''')
        proc, calls = self.invoke_main('--interactive', '--yes')
        self.assertEqual(proc.returncode, 27, proc.stderr)
        self.assertEqual(calls, 'apt-get update\napt-get install -y --no-install-recommends ca-certificates\n')

    def test_preflight_skips_compiler_when_pinned_nmstatectl_is_installed(self):
        (self.bin / 'cc').unlink()
        self.tool('ip', 'exit 1')
        self.tool('nmstatectl', "printf 'nmstatectl 2.2.60\\n'")
        proc, calls = self.invoke_main('--interactive', '--yes')
        self.assertEqual(proc.returncode, 27, proc.stderr)
        self.assertEqual(calls, '')

    def test_apt_success_without_required_tool_still_fails_preflight(self):
        self.tool('ip', 'exit 1')
        self.tool('apt-get', 'printf "apt-get %s\\n" "$*" >> "$CALLS"')
        proc, calls = self.invoke_main('--interactive', '--yes', omit=('gzip',))
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn('gzip', proc.stderr)
        self.assertNotIn('SETUP_REACHED', proc.stdout)
        self.assertEqual(calls, 'apt-get update\napt-get install -y --no-install-recommends gzip\n')

    def test_dry_run_ignores_missing_curl_and_never_invokes_apt(self):
        (self.bin / 'curl').unlink()
        self.tool('ip', 'exit 1')
        self.tool('apt-get', 'printf "apt-get %s\\n" "$*" >> "$CALLS"')
        proc, calls = self.invoke_main('--interactive', '--yes', '--dry-run')
        self.assertEqual(proc.returncode, 27, proc.stderr)
        self.assertEqual(calls, '')

    def test_missing_explicit_interface_fails_before_interactive_setup(self):
        self.tool('ip', '''
if [[ "$*" == '-br link show' ]]; then
    printf 'lo UNKNOWN\nenp1s0 UP\n'
else
    printf 'Device "eth0" does not exist.\n' >&2
    exit 1
fi
''')
        proc, calls = self.invoke_main('--interactive', '--yes', '--network-interface', 'eth0')
        self.assertEqual(proc.returncode, 1, proc.stderr)
        self.assertIn("Network interface 'eth0'", proc.stderr)
        self.assertIn('enp1s0', proc.stderr)
        self.assertNotIn('SETUP_REACHED', proc.stdout)
        self.assertEqual(calls, '')

    def test_alternate_interface_name_resolves_to_primary_name(self):
        self.tool('ip', '''
[[ "$*" == '-o link show dev enx525400f207d6' ]]
printf '2: enp1s0: <UP> mtu 1500\n'
''')
        proc, calls = self.invoke_main('--interactive', '--dry-run', '--network-interface', 'enx525400f207d6')
        self.assertEqual(proc.returncode, 27, proc.stderr)
        self.assertIn('SETUP_REACHED interface=enp1s0', proc.stdout)
        self.assertEqual(calls, '')

    def test_old_debian_rust_is_upgraded_before_build(self):
        for version in ('1.84.1', '1.85.1', '1.87.0'):
            with self.subTest(version=version):
                self.rust(version)
                # Use a fresh fake HOME so an earlier rustup cannot mask the next version.
                shutil.rmtree(self.home)
                self.home.mkdir()
                self.log.write_text('')
                proc, calls = self.invoke('ensure_cargo_available; rustc --version')
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn('curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs', calls)
                self.assertIn('rustc 1.99.1', proc.stdout)

    def test_supported_rust_is_reused_including_debian_version_format(self):
        for version in ('1.88.0', '1.99.1', '2.0.0'):
            with self.subTest(version=version):
                self.rust(version)
                proc, calls = self.invoke('ensure_cargo_available')
                self.assertEqual(proc.returncode, 0, proc.stderr)
                # cargo --version is probed, but no install or download may happen
                self.assertNotIn('curl ', calls)
                self.assertNotIn('cargo install', calls)

    def test_missing_cargo_triggers_toolchain_install(self):
        self.rust('1.88.0')
        (self.bin / 'cargo').unlink()
        proc, calls = self.invoke('ensure_cargo_available; command -v cargo; ensure_nmstatectl')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('curl ', calls)
        self.assertIn(str(self.home / '.cargo/bin/cargo'), proc.stdout)
        self.assertIn('cargo install --locked --force --version 2.2.60 nmstatectl', calls)

    def test_missing_rust_triggers_toolchain_install(self):
        proc, calls = self.invoke('ensure_cargo_available; rustc --version')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('curl ', calls)
        self.assertIn('rustc 1.99.1', proc.stdout)

    def test_broken_or_empty_rust_version_recovers_via_rustup(self):
        for body in ('exit 1', 'exit 0'):
            with self.subTest(rustc=body):
                shutil.rmtree(self.home)
                self.home.mkdir()
                self.log.write_text('')
                self.tool('rustc', body)
                proc, calls = self.invoke('ensure_cargo_available; rustc --version')
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn('curl ', calls)
                self.assertIn('rustc 1.99.1', proc.stdout)

    def test_nonnumeric_rust_version_triggers_reinstall_instead_of_abort(self):
        # A non-numeric rustc version must be handled, not abort the shell via
        # arithmetic evaluation of an unbound name under set -u.
        self.tool('rustc', "printf 'rustc unknown (fixture)\\\\n'")
        proc, calls = self.invoke('ensure_cargo_available; rustc --version')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('curl ', calls)
        self.assertIn('rustc 1.99.1', proc.stdout)

    def test_installer_requests_stable_default_toolchain(self):
        proc, calls = self.invoke('ensure_cargo_available')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('rustup -y --profile minimal --default-toolchain stable', calls)

    def test_stale_pinned_toolchain_after_reinstall_fails_loudly(self):
        # rustup-init can leave an existing pinned default toolchain in place;
        # the script must re-verify the version after install and fail loudly.
        self.rust('1.85.1')
        self.env['RUSTUP_FIXTURE_VERSION'] = '1.85.1'
        proc, calls = self.invoke('ensure_cargo_available')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('--default-toolchain stable', calls)
        self.assertIn('still below 1.88', proc.stderr)

    def test_broken_cargo_executable_triggers_reinstall(self):
        # A cargo binary that exists but exits nonzero must not pass validation.
        self.rust('1.99.1')
        self.env['CARGO_STATUS'] = '101'
        proc, calls = self.invoke('ensure_cargo_available')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('curl ', calls)

    def test_cargo_still_broken_after_reinstall_fails_loudly(self):
        self.env['CARGO_STATUS'] = '101'
        self.env['FIXTURE_CARGO_STATUS'] = '101'
        proc, calls = self.invoke('ensure_cargo_available')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('not available or not executable', proc.stderr)

    def test_rustup_download_failure_stops_before_next_step(self):
        self.rust('1.84.0')
        self.env['CURL_STATUS'] = '23'
        proc, calls = self.invoke('ensure_cargo_available; printf "INSTALLER_REACHED\\n"')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('curl ', calls)
        self.assertNotIn('INSTALLER_REACHED', proc.stdout)

    def test_rustup_installer_failure_stops_before_next_step(self):
        self.env['RUSTUP_STATUS'] = '31'
        proc, calls = self.invoke('ensure_cargo_available; printf "INSTALLER_REACHED\\n"')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('rustup -y --profile minimal', calls)
        self.assertNotIn('INSTALLER_REACHED', proc.stdout)

    def test_matching_nmstatectl_is_reused_without_compiler_or_cargo(self):
        self.tool('nmstatectl', "printf 'nmstatectl 2.2.60\\n'")
        (self.bin / 'cargo').unlink()
        (self.bin / 'cc').unlink()
        proc, calls = self.invoke('ensure_nmstatectl')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('Reusing nmstatectl', proc.stdout)
        self.assertEqual(calls, '')

    def test_absent_or_mismatched_nmstatectl_installs_pinned_version(self):
        for existing in (None, '2.2.37'):
            with self.subTest(existing=existing):
                if existing:
                    self.tool('nmstatectl', f"printf 'nmstatectl {existing}\\n'")
                self.log.write_text('')
                proc, calls = self.invoke('ensure_nmstatectl')
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(calls, 'cargo install --locked --force --version 2.2.60 nmstatectl\n')

    def test_missing_compiler_fails_before_cargo_build(self):
        (self.bin / 'cc').unlink()
        proc, calls = self.invoke('ensure_nmstatectl; printf "INSTALLER_REACHED\\n"')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('gcc', proc.stderr)
        self.assertIn('libc6-dev', proc.stderr)
        self.assertEqual(calls, '')
        self.assertNotIn('INSTALLER_REACHED', proc.stdout)

    def test_cargo_failure_stops_before_next_step(self):
        self.env['CARGO_STATUS'] = '101'
        proc, calls = self.invoke('ensure_nmstatectl; printf "INSTALLER_REACHED\\n"')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('cargo install --locked --force', calls)
        self.assertNotIn('INSTALLER_REACHED', proc.stdout)

    def test_dry_run_does_not_install_or_require_compiler(self):
        (self.bin / 'cc').unlink()
        proc, calls = self.invoke('DRY_RUN=1; ensure_cargo_available; ensure_nmstatectl')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(calls, '')
        self.assertFalse((self.home / '.cargo').exists())


unittest.main(verbosity=2)
PY
