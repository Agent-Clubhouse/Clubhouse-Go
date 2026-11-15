"""Run the real E2E retry policy with inert commands, never a desktop or simulator."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class RetryPolicyTests(unittest.TestCase):
    def run_policy(self, strict=False, crash=False):
        source = (ROOT / "scripts/e2e-live.sh").read_text()
        policy = source[source.index("run_tests() {"):]
        stubs = r'''
set -euo pipefail
ROOT=unused
DERIVED=unused
DEST=unused
UDID=unused
FIXTURE_DIR=unused
ONLY=("-only-testing:ClubhouseGoUITests/CompanionLiveE2ETests/test2ChatStreamApprovalsAndQuestion")
fixture() { printf fixture; }
log() { :; }
xcodebuild() {
  printf 'xcodebuild %s\n' "$*" >> "$OUT/calls"
  if [[ "$CRASH" == 1 ]]; then printf 'Test runner exited\n'; return 65; fi
}
xcrun() { printf 'xcrun %s\n' "$*" >> "$OUT/calls"; }
python3() { printf 'verify %s\n' "$*" >> "$OUT/calls"; }
'''
        with tempfile.TemporaryDirectory() as folder:
            env = dict(os.environ, OUT=folder, CRASH="1" if crash else "0",
                       E2E_NO_RETRIES="1" if strict else "0", E2E_ICON_FIXTURE="0")
            result = subprocess.run(["bash", "-c", stubs + policy], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return (pathlib.Path(folder) / "calls").read_text().splitlines()

    def test_default_keeps_failed_test_and_simulator_crash_retries(self):
        calls = self.run_policy(crash=True)
        builds = [line for line in calls if line.startswith("xcodebuild ")]
        self.assertEqual(len(builds), 2)
        for build in builds:
            self.assertIn("-retry-tests-on-failure -test-iterations 2", build)
        self.assertTrue(any(line.startswith("xcrun simctl boot ") for line in calls))
        self.assertNotIn("--no-retries-in", calls[-1])

    def test_strict_runs_once_even_after_crash_and_requires_no_retries(self):
        for crash in [False, True]:
            with self.subTest(crash=crash):
                calls = self.run_policy(strict=True, crash=crash)
                builds = [line for line in calls if line.startswith("xcodebuild ")]
                self.assertEqual(len(builds), 1)
                self.assertNotIn("-retry-tests-on-failure", builds[0])
                self.assertNotIn("-test-iterations", builds[0])
                self.assertFalse(any(line.startswith("xcrun ") for line in calls))
                self.assertTrue(calls[-1].endswith("ClubhouseGoUITests --no-retries-in ClubhouseGoUITests"))


if __name__ == "__main__":
    unittest.main()
