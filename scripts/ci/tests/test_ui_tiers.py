"""The scheduled run keeps a fast complete core and covers every other UI test within the rotation."""
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/ci"))
spec = importlib.util.spec_from_file_location("ui_tiers", ROOT / "scripts/ci/ui_tiers.py")
tiers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tiers)
scope = tiers.ui_scope
inventory = scope.Inventory(ROOT)


class ScheduledTierTests(unittest.TestCase):
    def test_the_fast_core_exists_and_fits_one_shard(self):
        self.assertEqual([s for s in tiers.fast() if not inventory.exists(s)], [])
        self.assertEqual(len(scope.pack(tiers.fast(), True, inventory)["include"]), 1)

    def test_the_rotation_runs_every_ui_method_and_the_core_daily(self):
        everything = {f"{c}/{m}" for c, methods in inventory.methods.items() for m in methods}
        days = [set(tiers.plan(inventory, day)) for day in range(tiers.ROTATION_DAYS)]
        self.assertEqual(set().union(*days), everything)
        for selected in days:
            self.assertTrue(set(tiers.fast()) <= selected)

    def test_buckets_are_stable_when_tests_come_and_go(self):
        self.assertEqual(tiers.bucket("CompanionSearchUITests/testX"), tiers.bucket("CompanionSearchUITests/testX"))
        self.assertEqual(tiers.plan(inventory, 3), tiers.plan(inventory, 3 + tiers.ROTATION_DAYS))

    def test_output_runs_every_lane_with_the_hosted_bundle_once(self):
        out = io.StringIO()
        tiers.main(["--day", "2"], stdin=io.StringIO('ui-shards={"include":[]}'), stdout=out, stderr=io.StringIO())
        result = dict(line.split("=", 1) for line in out.getvalue().splitlines())
        self.assertEqual({result[k] for k in ("ui", "ipad", "release", "unit")}, {"true"})
        self.assertEqual(sum(e["unit"] for e in json.loads(result["ui-shards"])["include"]), 1)

    def test_the_schedule_plans_with_this_script(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn('elif [ "$GITHUB_EVENT_NAME" = schedule ]', workflow)
        self.assertIn("python3 scripts/ci/ui_tiers.py --manifest impact-manifest.json", workflow)


if __name__ == "__main__":
    unittest.main()
