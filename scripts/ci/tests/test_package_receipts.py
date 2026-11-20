"""Execute the actual package-step shell with an inert Swift command to guard pipefail."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]


class PackageReceiptTests(unittest.TestCase):
    def run_package_step(self, exit_code, tee_exit=None):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Test transport package\n", 1)[1].split("\n      #", 1)[0]
        self.assertIn("shell: bash {0}", step)
        script = step.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in script.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fake = root / "swift"
            fake.write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > actual-argv.txt\n"
                            "printf 'inert stdout receipt probe\\n'\n"
                            "printf 'inert stderr receipt probe\\n' >&2\n"
                            "printf '<inert-probe/>\\n' > swift-package-results.xml\n"
                            "exit \"$PROBE_EXIT\"\n")
            fake.chmod(0o755)
            if tee_exit is not None:
                tee = root / "tee"
                tee.write_text('#!/bin/sh\n/bin/cat > "$1"\nexit "$PROBE_TEE_EXIT"\n')
                tee.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"], PROBE_EXIT=str(exit_code),
                       PROBE_TEE_EXIT=str(tee_exit))
            result = subprocess.run(["/bin/bash", "-c", script], cwd=root, env=env, text=True, capture_output=True)
            self.assertEqual((root / "actual-argv.txt").read_text().splitlines(),
                             ["test", "--enable-code-coverage", "--xunit-output", "swift-package-results.xml"])
            log = (root / "swift-package-tests.log").read_text()
            self.assertIn("inert stdout receipt probe", log)
            self.assertIn("inert stderr receipt probe", log)
            self.assertEqual((root / "swift-package-results.xml").read_text(), "<inert-probe/>\n")
        upload = workflow.split("      - name: Upload original package test receipts\n", 1)[1].split("\n  build:", 1)[0]
        self.assertIn("if: always()", upload)
        for path in ["swift-test-toolchain.log", "swift-package-tests.log", "swift-package-results.xml"]:
            self.assertIn(path, upload)
        return result

    def test_failed_toolchain_command_cannot_be_hidden_by_tee(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Report Swift test toolchain\n", 1)[1].split("      - name: Test transport package", 1)[0]
        self.assertIn("shell: bash {0}", step)
        script = step.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in script.splitlines())
        with tempfile.TemporaryDirectory() as directory:
            prefix = ("swift() { printf 'inert toolchain failure probe\\n'; return 13; }\n"
                      "xcodebuild() { printf 'unexpected later command\\n'; }\n"
                      "sw_vers() { printf 'unexpected later command\\n'; }\n")
            result = subprocess.run(["/bin/bash", "-c", prefix + script], cwd=directory, text=True, capture_output=True)
            self.assertEqual(result.returncode, 13)
            log = (pathlib.Path(directory) / "swift-test-toolchain.log").read_text()
            self.assertIn("inert toolchain failure probe", log)
            self.assertNotIn("unexpected later command", log)

    def test_failed_package_retains_receipts_and_nonzero_exit(self):
        self.assertEqual(self.run_package_step(65).returncode, 65)

    def test_original_test_failure_wins_when_receipt_writer_also_fails(self):
        self.assertEqual(self.run_package_step(65, tee_exit=74).returncode, 65)

    def test_receipt_writer_failure_still_fails_a_passing_test_step(self):
        self.assertEqual(self.run_package_step(0, tee_exit=74).returncode, 74)

    def test_passing_package_retains_receipts_and_success(self):
        self.assertEqual(self.run_package_step(0).returncode, 0)


if __name__ == "__main__":
    unittest.main()
