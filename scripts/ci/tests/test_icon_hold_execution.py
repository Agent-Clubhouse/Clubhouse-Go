"""The execution gate must reject silent availability skips and partial argument sets."""
import importlib.util
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("check_icon_hold_execution", Path(__file__).resolve().parents[1] / "check_icon_hold_execution.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def complete_log():
    return "\n".join(f"✔ Test {name}{'(omission:)' if cases else '()'}{cases} passed after 0.123 seconds."
                     for name, cases in check.REQUIRED.items())


class IconHoldExecutionTests(unittest.TestCase):
    def test_accepts_all_required_passes_with_color(self):
        self.assertEqual(check.missing_passes("\x1b[32m" + complete_log() + "\x1b[0m"), [])

    def test_started_or_skipped_records_do_not_count(self):
        log = "\n".join(f"◇ Test {name}() started.\n✘ Test {name}() skipped."
                        for name in check.REQUIRED)
        self.assertEqual(check.missing_passes(log), list(check.REQUIRED))

    def test_requires_all_four_icon_map_cases(self):
        log = complete_log().replace("with 4 test cases", "with 3 test cases")
        self.assertEqual(check.missing_passes(log), [next(iter(check.REQUIRED))])

    def test_failure_summary_does_not_count_as_a_pass(self):
        log = complete_log().replace("passed after", "failed after")
        self.assertEqual(check.missing_passes(log), list(check.REQUIRED))

    def run_workflow_step(self, helper_exit):
        root = Path(__file__).resolve().parents[3]
        workflow = (root / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Verify icon holds on a constrained cooperative pool\n", 1)[1].split("\n      - ", 1)[0]
        block = step.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in block.splitlines()) + "\n"
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            scripts = work / "scripts/ci"
            scripts.mkdir(parents=True)
            shutil.copyfile(root / "scripts/ci/check_icon_hold_execution.py", scripts / "check_icon_hold_execution.py")
            (scripts / "run_icon_hold_probe.py").write_text(f"print({complete_log()!r})\nraise SystemExit({helper_exit})\n")
            # Resolve the actual workflow command without launching a build.
            fake_bin = work / "bin"
            fake_bin.mkdir()
            swift = fake_bin / "swift"
            swift.write_text("#!/bin/sh\nprintf '%s\\n' /tmp/icon-hold-test-bin\n")
            swift.chmod(0o755)
            environment = dict(os.environ, PATH=str(fake_bin) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", "-c", script], cwd=work, env=environment, capture_output=True, text=True)
            log = (work / "icon-hold-tests.log").read_text()
            self.assertEqual(check.missing_passes(log), [])
            return result

    def test_workflow_rejects_nonzero_exit_after_complete_pass_output(self):
        result = self.run_workflow_step(124)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)

    def test_workflow_accepts_successful_host_with_complete_pass_output(self):
        result = self.run_workflow_step(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
