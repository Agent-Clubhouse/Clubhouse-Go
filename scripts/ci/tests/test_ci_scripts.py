"""Tests for the CI helper scripts. Run: python3 -m unittest discover -s scripts/ci/tests"""
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

SCRIPTS = pathlib.Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


changes = load("changes", SCRIPTS / "ci" / "changes.py")
ui_shards = load("ui_shards", SCRIPTS / "ci" / "ui_shards.py")
verify = load("verify_xcresult", SCRIPTS / "verify-xcresult.py")


class ChangesTests(unittest.TestCase):
    def run_main(self, paths, argv=()):
        out = io.StringIO()
        with redirect_stdout(out):
            changes.main(list(argv), io.StringIO("\n".join(paths) + "\n"))
        return dict(line.split("=") for line in out.getvalue().split())

    def test_docs_only_runs_nothing(self):
        self.assertEqual(self.run_main(["README.md", "docs/testing.md"]),
                         {"swift": "false", "app": "false"})

    def test_scheduled_workflow_files_run_nothing(self):
        self.assertEqual(self.run_main([".github/workflows/e2e-nightly.yml", "scripts/e2e-live.sh",
                                        "scripts/e2e-live/desktop-fixture.spec.ts",
                                        ".github/workflows/annex-contract-drift.yml"]),
                         {"swift": "false", "app": "false"})

    def test_package_tests_run_swift_only(self):
        self.assertEqual(self.run_main(["Tests/ClubhouseTransportTests/PinnedIOTests.swift", "docs/x.md"]),
                         {"swift": "true", "app": "false"})
        self.assertEqual(self.run_main(["Vendor/Framebriar/Tests/FramebriarTests/A.swift"]),
                         {"swift": "true", "app": "false"})
        self.assertEqual(self.run_main(["coverage-baseline.json", "scripts/coverage.sh",
                                        "scripts/sync-annex-fixtures.sh", "Tests/Fixtures/AnnexContract/pty.json"]),
                         {"swift": "true", "app": "false"})

    def test_any_vendored_framebriar_change_runs_the_vendor_check(self):
        # The SwiftPM lane runs scripts/verify-framebriar-vendor.sh, so even a README edit must reach it.
        for path in ["Vendor/Framebriar/README.md", "Vendor/Framebriar/SOURCE.json", "Vendor/Framebriar/.gitignore",
                     "Vendor/Framebriar/Tests/FramebriarTests/Fixtures/otlp-logs.json",
                     "scripts/verify-framebriar-vendor.sh"]:
            self.assertEqual(self.run_main([path]), {"swift": "true", "app": "false"}, path)
        for path in ["Vendor/Framebriar/Sources/Framebriar/Telemetry.swift", "Vendor/Framebriar/Package.swift"]:
            self.assertEqual(self.run_main([path]), {"swift": "true", "app": "true"}, path)

    def test_app_and_build_inputs_run_everything(self):
        for path in ["Annex/Annex/Companion/Domain/X.swift", "Annex/AnnexUITests/Y.swift",
                     "Vendor/Framebriar/Sources/Framebriar/Z.swift", "Package.swift", "Package.resolved",
                     ".github/workflows/ci.yml", "scripts/verify-xcresult.py"]:
            self.assertEqual(self.run_main([path]), {"swift": "true", "app": "true"}, path)

    def test_unknown_paths_run_everything(self):
        self.assertEqual(self.run_main(["something/new.yml"]), {"swift": "true", "app": "true"})

    def test_all_flag_and_empty_list(self):
        self.assertEqual(self.run_main([], ["--all"]), {"swift": "true", "app": "true"})
        self.assertEqual(self.run_main([]), {"swift": "false", "app": "false"})


class UIShardTests(unittest.TestCase):
    def test_every_listed_test_runs_exactly_once(self):
        include = ui_shards.matrix()["include"]
        only = [flag for entry in include for flag in entry["selection"].split() if flag.startswith("-only-testing:")]
        rest = next(entry for entry in include if entry["selection"].startswith(f"-only-testing:{ui_shards.UI_TARGET} "))
        skipped = [flag.split(":", 1)[1] for flag in rest["selection"].split() if flag.startswith("-skip-testing:")]
        explicit = [flag.split(":", 1)[1] for flag in only
                    if flag not in (f"-only-testing:{ui_shards.UI_TARGET}", f"-only-testing:{ui_shards.UNIT_TARGET}")]
        self.assertEqual(sorted(skipped), sorted(explicit))
        unit = [entry for entry in include if f"-only-testing:{ui_shards.UNIT_TARGET}" in entry["selection"].split()]
        self.assertEqual(unit, [entry for entry in include if entry["unit"]])
        self.assertEqual(len(unit), 1)

    def test_listed_classes_exist(self):
        sources = "\n".join(p.read_text() for p in (SCRIPTS.parent / "Annex" / "AnnexUITests").glob("*.swift"))
        for shard in ui_shards.SHARDS:
            for test in shard["tests"] or []:
                cls, _, method = test.partition("/")
                self.assertIn(f"class {cls}", sources, test)
                if method:
                    self.assertIn(f"func {method}(", sources, test)

    def test_duplicates_are_rejected(self):
        bad = [{"name": "a", "tests": ["X"], "unit": True}, {"name": "b", "tests": ["X"]}, {"name": "c", "tests": None}]
        with self.assertRaises(SystemExit):
            ui_shards.matrix(bad)

    def test_output_is_one_line_of_json(self):
        line = f"ui-shards={json.dumps(ui_shards.matrix(), separators=(',', ':'))}"
        self.assertNotIn("\n", line)


def case(name, result, repetitions=(), duration=1.0):
    node = {"nodeType": "Test Case", "name": name, "result": result, "durationInSeconds": duration,
            "nodeIdentifier": f"Suite/{name}"}
    if repetitions:
        node["children"] = [{"nodeType": "Repetition", "name": f"Run {i}", "result": r}
                            for i, r in enumerate(repetitions)]
    return node


TESTS_JSON = {"testNodes": [{"nodeType": "Test Plan", "name": "ClubhouseGo", "children": [
    {"nodeType": "UI test bundle", "name": "ClubhouseGoUITests", "children": [
        {"nodeType": "Test Suite", "name": "Suite", "children": [
            case("testSteady()", "Passed", duration=10),
            case("testFlaky()", "Passed", ["Failed", "Passed"], duration=30),
            case("testBroken()", "Failed", ["Failed", "Failed", "Failed"], duration=5),
        ]},
    ]},
    {"nodeType": "Unit test bundle", "name": "ClubhouseGoTests", "children": [
        {"nodeType": "Test Suite", "name": "UnitSuite", "children": [case("unitSteady()", "Passed", duration=0)]},
    ]},
]}]}


class VerifyXcresultTests(unittest.TestCase):
    def test_retried_passes_are_flaky(self):
        flaky = verify.flaky_tests(TESTS_JSON)
        self.assertEqual(flaky, [("Suite", "testFlaky()", 1)])

    def test_flaky_tests_by_bundle(self):
        self.assertEqual(verify.flaky_tests(TESTS_JSON, {"ClubhouseGoTests"}), [])
        self.assertEqual(len(verify.flaky_tests(TESTS_JSON, {"ClubhouseGoUITests"})), 1)

    def test_retried_test_in_strict_bundle_fails(self):
        summary = {"result": "Passed", "passedTests": 3, "failedTests": 0}
        fetch = lambda kind, path: summary if kind == "summary" else TESTS_JSON
        with mock.patch.object(verify, "xcresult", fetch), redirect_stdout(io.StringIO()), \
                mock.patch.dict("os.environ", {}, clear=True):
            verify.main("x.xcresult", "t", ["ClubhouseGoTests"])
            with self.assertRaises(SystemExit):
                verify.main("x.xcresult", "t", ["ClubhouseGoUITests"])

    def test_durations_by_class(self):
        self.assertEqual(verify.class_durations(TESTS_JSON), {"Suite": 45, "UnitSuite": 0})

    def test_report_writes_summary_and_annotations(self):
        with tempfile.NamedTemporaryFile("r+") as summary:
            out = io.StringIO()
            with redirect_stdout(out), mock.patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": summary.name}):
                verify.report("UI shard", TESTS_JSON)
            text = summary.read()
        self.assertIn("testFlaky()", text)
        self.assertIn("| Suite | 45 |", text)
        self.assertIn("::warning title=Flaky test::Suite/testFlaky() passed only after 1 failed attempt", out.getvalue())

    def test_no_flakes_no_annotation(self):
        steady = {"testNodes": [{"nodeType": "Test Suite", "name": "S", "children": [case("t()", "Passed")]}]}
        out = io.StringIO()
        with redirect_stdout(out), mock.patch.dict("os.environ", {}, clear=True):
            verify.report("x", steady)
        self.assertNotIn("::warning", out.getvalue())


if __name__ == "__main__":
    unittest.main()
