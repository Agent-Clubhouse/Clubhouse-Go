"""The pre-merge UI scope stays small by design and widens only where a change's risk calls for it."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("ui_scope", ROOT / "scripts/ci/ui_scope.py")
scope = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scope)
changes = scope.load_changes(ROOT)
SMOKE = set(scope.SMOKE)


def plan(lines):
    return scope.plan(scope.parse_changes(lines), ROOT, changes)


class PreMergeScopeTests(unittest.TestCase):
    def test_every_configured_test_exists(self):
        inventory = scope.Inventory(ROOT)
        self.assertEqual([s for s in scope.configured_selectors() if not inventory.exists(s)], [])

    def test_docs_and_package_changes_run_no_ui(self):
        decision = plan("M\tdocs/testing.md\nM\tTests/X/YTests.swift\n")
        self.assertEqual(decision["ui"], [])
        self.assertFalse(decision["release"] or decision["unit"] or decision["ipad"])

    def test_a_ui_class_change_runs_smoke_and_that_class_without_release(self):
        decision = plan("M\tAnnex/AnnexUITests/CompanionTerminalUITests.swift\n")
        self.assertEqual(set(decision["ui"]) - SMOKE, {"CompanionTerminalUITests"})
        self.assertFalse(decision["release"] or decision["unit"])

    def test_hosted_tests_run_smoke_and_the_bundle_with_ipad_left_to_the_daily_run(self):
        decision = plan("M\tAnnex/AnnexTests/CompanionDeinitTests.swift\n")
        self.assertEqual(set(decision["ui"]), SMOKE)
        self.assertTrue(decision["unit"])
        self.assertFalse(decision["ipad"])

    def test_a_mapped_product_file_runs_smoke_its_journeys_hosted_and_release(self):
        decision = plan("M\tAnnex/Annex/Companion/Views/CompanionTerminalView.swift\n")
        self.assertEqual(set(decision["ui"]) - SMOKE, set(scope.JOURNEYS["terminal"][1]))
        self.assertTrue(decision["unit"] and decision["release"])
        self.assertFalse(decision["broad"])

    def test_critical_areas_run_their_whole_proof_classes(self):
        privacy = plan("M\tAnnex/Annex/Companion/Views/CompanionFeedbackPresenter.swift\n")
        self.assertTrue({"FeedbackDiagnosticsWireUITests", "FramebriarShakeUITests"} <= set(privacy["ui"]))
        self.assertTrue(privacy["ipad"])
        security = plan("M\tAnnex/Annex/Companion/Views/CompanionConversationGrantRequests.swift\n")
        self.assertTrue({"CompanionPermissionMenuUITests", "CompanionGrantRequestUITests"} <= set(security["ui"]))

    def test_hubs_unmapped_removed_and_build_inputs_escalate_to_the_broad_tier(self):
        for lines in ("M\tAnnex/Annex/Companion/Domain/CompanionStore.swift\n",
                      "M\tAnnex/Annex/Companion/Domain/CompanionOrchestration.swift\n",
                      "D\tAnnex/Annex/Companion/Views/CompanionTerminalView.swift\n",
                      "M\tAnnex/Annex.xcodeproj/project.pbxproj\n",
                      "M\tAnnex/AnnexUITests/UITestSupport.swift\n"):
            decision = plan(lines)
            self.assertTrue(decision["broad"], lines)
            selected = set(decision["ui"])
            for rep in (rep for _, (_, _, _, rep) in scope.JOURNEYS.items() if rep):
                self.assertTrue(rep in selected or rep.split("/")[0] in selected, f"{lines}: {rep}")

    def test_transport_runs_smoke_with_hosted_and_release(self):
        decision = plan("M\tAnnex/Annex/Transport/AnnexWire.swift\n")
        self.assertEqual(set(decision["ui"]), SMOKE)
        self.assertTrue(decision["unit"] and decision["release"])

    def test_shards_stay_under_the_budget_and_carry_the_bundle_once(self):
        decision = plan("M\tAnnex/Annex/Companion/Views/CompanionFeedbackPresenter.swift\n"
                        "M\tAnnex/Annex/Companion/Views/CompanionConversationComposer.swift\n")
        matrix = scope.pack(decision["ui"], decision["unit"], scope.Inventory(ROOT))
        self.assertTrue(all(entry["minutes"] <= scope.SHARD_TEST_MINUTES + scope.HOSTED_MINUTES for entry in matrix["include"]))
        self.assertEqual(sum(entry["unit"] for entry in matrix["include"]), 1)
        planned = {s for e in matrix["include"] for s in e["selection"].split() if s.startswith("-only-testing:ClubhouseGoUITests/")}
        self.assertEqual(planned, {f"-only-testing:ClubhouseGoUITests/{s}" for s in decision["ui"]})

    def test_main_output_contract_and_placeholder(self):
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / "changed.txt"
            changed.write_text("M\tdocs/testing.md\n")
            out = io.StringIO()
            daily = {"include": [{"name": "UI tests (other)", "selection": "-only-testing:ClubhouseGoUITests", "unit": False}]}
            scope.main([str(changed)], stdin=io.StringIO("ui-shards=" + json.dumps(daily)), stdout=out, stderr=io.StringIO())
            result = dict(line.split("=", 1) for line in out.getvalue().splitlines())
            self.assertEqual(result["ui"], "false")
            self.assertEqual(len(json.loads(result["ui-shards"])["include"]), 1)

    def test_the_workflow_plans_with_this_script(self):
        self.assertIn("python3 scripts/ci/ui_scope.py changed-files.txt", (ROOT / ".github/workflows/ci.yml").read_text())


if __name__ == "__main__":
    unittest.main()
