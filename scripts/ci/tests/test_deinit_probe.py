"""Observation failures must retain evidence and never become test outcomes."""
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("deinit_probe", ROOT / "scripts/observe-isolated-deinit-runtime.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class RuntimeObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (ROOT / "build").mkdir(exist_ok=True)

    def test_partial_output_and_even_a_pass_marker_survive_timeout_as_timeout(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as tmp:
            log = pathlib.Path(tmp) / "outside.log"
            result = probe.run_logged([sys.executable, "-c",
                'import time; print("PROBE passed mode=outside", flush=True); time.sleep(10)'], log, 0.5)
            text = log.read_text()
        self.assertIn("PROBE passed mode=outside", text)
        self.assertTrue(result["timedOut"])
        self.assertEqual(probe.classify("outside", result, text), "timeout")

    def test_only_successful_command_and_matching_completion_can_pass(self):
        result = {"timedOut": False, "returncode": 0}
        self.assertEqual(probe.classify("inside", result, "malloc: abort"), "incomplete")
        self.assertEqual(probe.classify("inside", result, "PROBE passed mode=outside"), "incomplete")
        self.assertEqual(probe.classify("async", result, "PROBE passed mode=async task=true"), "passed")
        self.assertEqual(probe.classify("inside", dict(result, returncode=1), "PROBE passed mode=inside"), "command_failed")

    def test_timeout_continues_other_modes_and_persists_summary(self):
        def command(argv, path, timeout):
            name = path.stem
            output = {"devices": json.dumps({"devices": {"iOS-26-5": [{"udid": "own-sim", "state": "Booted", "name": "test"}]}}),
                      "sdk": "/fake/sdk"}.get(name, "")
            if name in probe.MODES and name != "outside":
                output = f"PROBE passed mode={name}"
            path.write_text("{}\n" + output + "\nOBSERVER {}\n")
            return {"timedOut": name == "outside", "returncode": 0}

        with tempfile.TemporaryDirectory(dir=ROOT / "build") as tmp, \
                mock.patch.object(probe, "run_logged", side_effect=command), \
                mock.patch.object(probe, "timeout_diagnostics") as diagnostics, redirect_stdout(io.StringIO()):
            out = pathlib.Path(tmp)
            result = probe.observe("own-sim", out)
            self.assertEqual(result, json.loads((out / "summary.json").read_text()))
            self.assertEqual([x["outcome"] for x in result["modes"]], ["timeout"] + ["passed"] * 7)
            diagnostics.assert_called_once_with("own-sim", out, "outside")

    def test_setup_failure_retains_logs_for_every_unrun_mode(self):
        with tempfile.TemporaryDirectory(dir=ROOT / "build") as tmp, \
                mock.patch.object(probe, "run_logged", side_effect=OSError("no tool")), redirect_stdout(io.StringIO()):
            out = pathlib.Path(tmp)
            result = probe.observe("own-sim", out)
            self.assertEqual(result["setup"], "failed")
            self.assertIn("no tool", (out / "observer-error.log").read_text())
            for mode in probe.MODES:
                self.assertIn("not_run", (out / f"{mode}.log").read_text())
            self.assertTrue(all(x["outcome"] == "not_run" for x in result["modes"]))

    def test_ci_runs_observation_after_tests_and_their_artifacts_without_gating(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        tests = workflow.index("- name: Run tests")
        artifacts = workflow.index("- name: Upload test results")
        observation = workflow.index("- name: Observe installed runtime isolated-deinit control")
        upload = workflow.index("- name: Upload runtime observation")
        self.assertLess(tests, artifacts)
        self.assertLess(artifacts, observation)
        self.assertLess(observation, upload)
        self.assertIn("continue-on-error: true", workflow[observation:upload])
        self.assertIn("timeout-minutes: 6", workflow[observation:upload])
        self.assertIn("build/isolated-deinit-runtime/*.log", workflow[upload:])
        self.assertIn("build/isolated-deinit-runtime/summary.json", workflow[upload:])


if __name__ == "__main__":
    (ROOT / "build").mkdir(exist_ok=True)
    unittest.main()
