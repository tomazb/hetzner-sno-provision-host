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
printf 'rustc 1.99.1 (fixture)\\n'
RUSTC
cat > "$HOME/.cargo/bin/cargo" <<'CARGO'
#!/bin/sh
printf 'cargo %s\\n' "$*" >> "$CALLS"
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
                self.assertEqual(calls, '')

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
