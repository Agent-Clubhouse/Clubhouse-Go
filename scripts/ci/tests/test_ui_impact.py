"""Impact selection must run what a change can affect and fall back to everything when it can't tell."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("ui_impact", ROOT / "scripts/ci/ui_impact.py")
impact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(impact)


def write(root, path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(textwrap.dedent(text))


class Fixture:
    """A small tree: two screens, a shared container, a fixture, a transport file and UI test classes."""

    def __init__(self):
        self.directory = tempfile.TemporaryDirectory()
        root = self.root = Path(self.directory.name)
        (root / "scripts/ci").mkdir(parents=True)
        (root / "scripts/ci/changes.py").write_text((ROOT / "scripts/ci/changes.py").read_text())
        write(root, "Annex/Annex/Companion/Views/SearchScreen.swift", """
            struct SearchScreen: View { var body: some View { Text("x").accessibilityIdentifier("search-field-box") } }
            """)
        write(root, "Annex/Annex/Companion/Views/SearchRow.swift", """
            struct SearchRow: View { var body: some View { Text("row") } }
            extension SearchScreen { var row: SearchRow { SearchRow() } }
            """)
        write(root, "Annex/Annex/Companion/Views/TerminalScreen.swift", """
            struct TerminalScreen: View { var body: some View { Text("t").accessibilityIdentifier("terminal-done-key") } }
            """)
        write(root, "Annex/Annex/Companion/Views/OrphanThing.swift", """
            struct OrphanThing { let value = 1 }
            """)
        write(root, "Annex/Annex/Companion/Views/CompanionPermissionBadge.swift", """
            struct CompanionPermissionBadge: View { var body: some View { Text("p") } }
            """)
        write(root, "Annex/Annex/Transport/AnnexWire.swift", """
            struct AnnexWire { let bytes = 0 }
            """)
        write(root, "Annex/Annex/Companion/Adapters/CompanionPreviewService.swift", """
            final class CompanionPreviewService {
                func hosts() {
                    shared()
                    if ProcessInfo.processInfo.arguments.contains("--companion-preview-search-fixture") {
                        searchOnly()
                    }
                }
            }
            """)
        write(root, "Annex/AnnexUITests/UITestSupport.swift", """
            class ReliableUITestCase: XCTestCase {}
            """)
        write(root, "Annex/AnnexUITests/SearchUITests.swift", """
            final class SearchUITests: ReliableUITestCase {
                func testSearch() { app.launchArguments = ["--companion-preview-search-fixture"]; _ = app.textFields["search-field-box"] }
            }
            """)
        write(root, "Annex/AnnexUITests/TerminalUITests.swift", """
            final class TerminalUITests: ReliableUITestCase {
                func testTerminal() { _ = app.buttons["terminal-done-key"] }
            }
            """)
        write(root, "Annex/AnnexUITests/MixedUITests.swift", """
            final class MixedUITests: ReliableUITestCase {
                func testMixed() {}
            }
            extension ReliableUITestCase { func helper() {} }
            """)
        write(root, "Annex/AnnexUITests/CompanionPermissionMenuUITests.swift", """
            final class CompanionPermissionMenuUITests: ReliableUITestCase {
                func testMenu() {}
            }
            """)
        write(root, "Annex/AnnexTests/StoreTests.swift", "final class StoreTests: XCTestCase { func testStore() {} }\n")
        self.matrix = {"include": [
            {"name": "UI (search)", "selection": "-only-testing:ClubhouseGoUITests/SearchUITests", "unit": False},
            {"name": "UI (unit)", "selection": "-only-testing:ClubhouseGoUITests/TerminalUITests -only-testing:ClubhouseGoTests", "unit": True},
            {"name": "UI (other)", "selection": "-only-testing:ClubhouseGoUITests -skip-testing:ClubhouseGoUITests/SearchUITests "
                                               "-skip-testing:ClubhouseGoUITests/TerminalUITests", "unit": False},
        ]}

    def run(self, changed, diff=None):
        (self.root / "changed.txt").write_text(changed)
        argv = [str(self.root / "changed.txt")]
        if diff is not None:
            (self.root / "changes.diff").write_text(diff)
            argv += ["--diff", str(self.root / "changes.diff")]
        out, err = io.StringIO(), io.StringIO()
        impact.main(argv, stdin=io.StringIO("ui-shards=" + json.dumps(self.matrix)), stdout=out, stderr=err, root=self.root)
        lines = dict(line.split("=", 1) for line in out.getvalue().splitlines())
        lines["ui-shards"] = json.loads(lines["ui-shards"])
        lines["summary"] = err.getvalue()
        return lines

    def selected(self, result):
        return [entry["selection"] for entry in result["ui-shards"]["include"]]


class ImpactSelectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()

    def tearDown(self):
        self.fixture.directory.cleanup()

    def assertFull(self, result):
        self.assertEqual(result["ui-shards"], self.fixture.matrix)
        self.assertEqual([result[k] for k in ("ui", "ipad", "release", "unit")], ["true"] * 4)

    def test_a_ui_test_class_change_runs_exactly_that_class(self):
        result = self.fixture.run("M\tAnnex/AnnexUITests/TerminalUITests.swift\n")
        self.assertEqual(self.fixture.selected(result), ["-only-testing:ClubhouseGoUITests/TerminalUITests"])
        self.assertEqual((result["release"], result["ipad"], result["unit"]), ("false", "false", "false"))

    def test_a_new_class_in_the_catch_all_runs_from_the_catch_all_shard(self):
        write(self.fixture.root, "Annex/AnnexUITests/NewUITests.swift",
              "final class NewUITests: ReliableUITestCase {\n    func testNew() {}\n}\n")
        result = self.fixture.run("added\tAnnex/AnnexUITests/NewUITests.swift\n")
        self.assertEqual(self.fixture.selected(result), ["-only-testing:ClubhouseGoUITests/NewUITests"])

    def test_shared_ui_helpers_mixed_files_and_deleted_tests_run_everything(self):
        self.assertFull(self.fixture.run("M\tAnnex/AnnexUITests/UITestSupport.swift\n"))
        self.assertFull(self.fixture.run("M\tAnnex/AnnexUITests/MixedUITests.swift\n"))
        self.assertFull(self.fixture.run("D\tAnnex/AnnexUITests/GoneUITests.swift\n"))
        self.assertFull(self.fixture.run("R100\tAnnex/AnnexUITests/OldUITests.swift\tAnnex/AnnexUITests/TerminalUITests.swift\n"))

    def test_hosted_tests_run_only_the_unit_bundle(self):
        result = self.fixture.run("M\tAnnex/AnnexTests/StoreTests.swift\n")
        self.assertEqual(self.fixture.selected(result), ["-only-testing:ClubhouseGoTests"])
        self.assertEqual(result["unit"], "true")

    def test_a_product_file_selects_its_identifiers_and_its_consumers(self):
        result = self.fixture.run("M\tAnnex/Annex/Companion/Views/SearchScreen.swift\n")
        self.assertEqual(self.fixture.selected(result),
                         ["-only-testing:ClubhouseGoUITests/SearchUITests", "-only-testing:ClubhouseGoTests"])
        self.assertEqual((result["release"], result["unit"]), ("true", "true"))
        # SearchRow has no identifier of its own; SearchScreen, which uses it, names the scenario.
        row = self.fixture.run("M\tAnnex/Annex/Companion/Views/SearchRow.swift\n")
        self.assertIn("-only-testing:ClubhouseGoUITests/SearchUITests", self.fixture.selected(row))

    def test_untraceable_new_or_removed_product_files_run_everything(self):
        self.assertFull(self.fixture.run("M\tAnnex/Annex/Companion/Views/OrphanThing.swift\n"))
        self.assertFull(self.fixture.run("D\tAnnex/Annex/Companion/Views/Gone.swift\n"))
        self.assertFull(self.fixture.run("renamed\tAnnex/Annex/Companion/Views/SearchScreen.swift\tAnnex/Annex/Old.swift\n"))

    def test_critical_scenarios_run_even_without_identifiers(self):
        result = self.fixture.run("M\tAnnex/Annex/Companion/Views/CompanionPermissionBadge.swift\n")
        self.assertIn("-only-testing:ClubhouseGoUITests/CompanionPermissionMenuUITests", " ".join(self.fixture.selected(result)))
        self.assertIn("security", result["summary"])

    def test_transport_runs_package_and_hosted_tests_without_ui(self):
        result = self.fixture.run("M\tAnnex/Annex/Transport/AnnexWire.swift\n")
        self.assertEqual(self.fixture.selected(result), ["-only-testing:ClubhouseGoTests"])
        self.assertEqual(result["release"], "true")

    def test_a_flag_gated_fixture_edit_selects_the_flag_users_and_shared_code_runs_everything(self):
        path = "Annex/Annex/Companion/Adapters/CompanionPreviewService.swift"
        gated = f"+++ b/{path}\n@@ -5,0 +6,1 @@\n+        searchOnly()\n"
        result = self.fixture.run(f"M\t{path}\n", gated)
        self.assertEqual(self.fixture.selected(result),
                         ["-only-testing:ClubhouseGoUITests/SearchUITests", "-only-testing:ClubhouseGoTests"])
        shared = f"+++ b/{path}\n@@ -3,0 +4,1 @@\n+        shared()\n"
        self.assertFull(self.fixture.run(f"M\t{path}\n", shared))
        self.assertFull(self.fixture.run(f"M\t{path}\n"))  # no line diff: can't bound it

    def test_docs_and_package_only_changes_add_no_macos_ui_work(self):
        result = self.fixture.run("M\tdocs/testing.md\nM\tTests/X/YTests.swift\n")
        self.assertEqual(result["ui"], "false")
        self.assertEqual(len(result["ui-shards"]["include"]), 1, "GitHub rejects an empty matrix even for a skipped job")

    def test_unknown_paths_and_the_project_run_everything(self):
        self.assertFull(self.fixture.run("M\tAnnex/Annex.xcodeproj/project.pbxproj\n"))
        self.assertFull(self.fixture.run("M\tscripts/ci/ui_shards.py\n"))

    def test_status_parsing(self):
        self.assertEqual(impact.parse_changes("R087\told.swift\tnew.swift\nremoved\tgone.swift\nplain.swift\n"),
                         [("renamed", "new.swift", "old.swift"), ("removed", "gone.swift", None), ("modified", "plain.swift", None)])
        self.assertEqual(impact.parse_changes("renamed\tnew.swift\told.swift\n"), [("renamed", "new.swift", "old.swift")])


class ImpactWorkflowTests(unittest.TestCase):
    def test_the_workflow_feeds_statuses_previous_names_and_line_diffs(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("previous_filename", workflow)
        self.assertIn("scripts/ci/ui_impact.py changed-files.txt --diff changes.diff", workflow)
        self.assertIn("fetch-depth: 2", workflow)

    def test_the_daily_and_labelled_runs_take_every_lane(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("schedule:", workflow)
        self.assertIn("ci:full", workflow)


if __name__ == "__main__":
    unittest.main()
