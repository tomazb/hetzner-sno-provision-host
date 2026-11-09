#!/bin/bash
# Engine calls are external side effects; use isolated fake engines, never a daemon.
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
RUNNER = ROOT / 'scripts/test-debian-container.sh'
WRAPPER = ROOT / 'scripts/test-debian12-container.sh'


class ContainerRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='debian-runner-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for tool in ('bash', 'dirname'):
            (self.bin / tool).symlink_to(shutil.which(tool))
        self.env = dict(PATH=str(self.bin), ENGINE_LOG=str(self.root), HOME=str(self.root))

    def engine(self, name):
        path = self.bin / name
        path.write_text('''#!/bin/bash
set -eu
counter=0
if [[ -f "$ENGINE_LOG/count" ]]; then read -r counter < "$ENGINE_LOG/count"; fi
counter=$((counter + 1))
printf '%s\\n' "$counter" > "$ENGINE_LOG/count"
printf '%s\\0' "${0##*/}" "$@" > "$ENGINE_LOG/$counter.args"
for arg in "$@"; do
  if [[ -n "${FAIL_IMAGE:-}" && "$arg" == "$FAIL_IMAGE" ]]; then exit 17; fi
done
''')
        path.chmod(0o755)

    def run_script(self, *args, wrapper=False):
        proc = subprocess.run([BASH, str(WRAPPER if wrapper else RUNNER), *args],
                              env=self.env, text=True, capture_output=True, timeout=15)
        calls = [p.read_bytes().decode().rstrip('\0').split('\0')
                 for p in sorted(self.root.glob('*.args'), key=lambda p: int(p.stem))]
        return proc, calls

    def assert_images(self, calls, images, engine='podman'):
        self.assertEqual(len(calls), len(images), calls)
        for call, image in zip(calls, images):
            self.assertEqual(call[:5], [engine, 'run', '--rm', '--user', '0'])
            self.assertIn('docker.io/library/' + image, call)
            mount = call[call.index('-v') + 1]
            self.assertEqual(mount, f'{ROOT}:/work' + (':Z' if engine == 'podman' else ''))
            self.assertEqual(call[call.index('-w') + 1], '/work')
            self.assertNotIn('--privileged', call)
            self.assertNotIn('--cap-drop', call)
            payload = call[-1]
            self.assertIn('./tests/test-hetzner-sno-prepare-pxe.sh', payload)
            self.assertIn('./tests/test-hetzner-sno-hardening.sh', payload)
            self.assertIn('./tests/test-debian-container-runner.sh', payload)
            self.assertIn('./tests/test-prepare-dependencies.sh', payload)

    def test_default_runs_both_images_and_prefers_podman(self):
        self.engine('podman')
        self.engine('docker')
        proc, calls = self.run_script()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assert_images(calls, ['debian:12-slim', 'debian:13-slim'])

    def test_all_runs_both_images(self):
        self.engine('podman')
        proc, calls = self.run_script('all')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assert_images(calls, ['debian:12-slim', 'debian:13-slim'])

    def test_specific_versions_run_only_requested_image(self):
        self.engine('podman')
        for version in ('12', '13'):
            with self.subTest(version=version):
                for path in self.root.glob('*.args'):
                    path.unlink()
                proc, calls = self.run_script(version)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assert_images(calls, [f'debian:{version}-slim'])

    def test_docker_fallback(self):
        self.engine('docker')
        proc, calls = self.run_script('13')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assert_images(calls, ['debian:13-slim'], 'docker')

    def test_invalid_and_extra_arguments_never_launch_engine(self):
        self.engine('podman')
        for args in (('14',), ('13', 'extra'), ('',)):
            with self.subTest(args=args):
                proc, calls = self.run_script(*args)
                self.assertNotEqual(proc.returncode, 0)
                self.assertIn('Usage:', proc.stderr)
                self.assertEqual(calls, [])

    def test_missing_engines_is_clear_error(self):
        proc, calls = self.run_script('13')
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('podman or docker', proc.stderr)
        self.assertEqual(calls, [])

    def test_failed_leg_does_not_skip_other_image_or_return_success(self):
        self.engine('podman')
        for image in ('debian:12-slim', 'debian:13-slim'):
            with self.subTest(failed=image):
                for path in self.root.glob('*.args'):
                    path.unlink()
                self.env['FAIL_IMAGE'] = 'docker.io/library/' + image
                proc, calls = self.run_script('all')
                self.assertNotEqual(proc.returncode, 0)
                self.assert_images(calls, ['debian:12-slim', 'debian:13-slim'])
                self.assertIn('FAIL: ' + image, proc.stderr)

    def test_legacy_wrapper_only_runs_bookworm(self):
        self.engine('podman')
        proc, calls = self.run_script(wrapper=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assert_images(calls, ['debian:12-slim'])

    def test_legacy_wrapper_preserves_ignored_arguments(self):
        self.engine('podman')
        proc, calls = self.run_script('13', wrapper=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assert_images(calls, ['debian:12-slim'])

    def test_container_payload_stops_after_apt_failure(self):
        self.engine('podman')
        proc, calls = self.run_script('12')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        # Run the actual container payload against harmless local stand-ins.
        # Without errexit a failed apt command would be masked by later tests.
        (self.bin / 'apt-get').write_text('#!/bin/bash\nexit 19\n')
        (self.bin / 'apt-get').chmod(0o755)
        (self.bin / 'shellcheck').write_text('#!/bin/bash\nprintf reached >> "$ENGINE_LOG/later"\n')
        (self.bin / 'shellcheck').chmod(0o755)
        (self.root / 'scripts').mkdir()
        (self.root / 'tests').mkdir()
        (self.root / 'fixture.sh').write_text('true\n')
        (self.root / 'scripts/fixture.sh').write_text('true\n')
        for name in ('test-debian-container-runner.sh', 'test-prepare-dependencies.sh',
                     'test-hetzner-sno-prepare-pxe.sh', 'test-hetzner-sno-hardening.sh'):
            path = self.root / 'tests' / name
            path.write_text('#!/bin/bash\nprintf reached >> "$ENGINE_LOG/later"\n')
            path.chmod(0o755)
        payload = subprocess.run([BASH, '-c', calls[0][-1]], cwd=self.root,
                                 env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(payload.returncode, 19, payload.stderr)
        self.assertFalse((self.root / 'later').exists())


unittest.main(verbosity=2)
PY
