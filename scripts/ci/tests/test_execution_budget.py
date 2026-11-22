"""Cost uncertainty and resource waiting must not masquerade as measured speed."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts/ci'))
import ci_execution_budget as budget


class ExecutionBudgetTests(unittest.TestCase):
    def test_only_sampled_offline_guard_can_replace_unknown_fallback(self):
        with_sample = budget.costs()
        without = budget.costs(offline=False)
        changed = {c for c in with_sample if with_sample[c] != without[c]}
        self.assertEqual(changed, {'CompanionLiveE2ETests'})
        self.assertEqual(with_sample['CompanionLiveE2ETests']['unknown_methods'], 0)
        self.assertEqual(without['CompanionLiveE2ETests']['unknown_methods'], 15)
        self.assertEqual(without['CompanionLiveE2ETests']['body_s'], 15 * 60)
        # No sampled success, failed retry or another unknown receives this discount.
        changed_fallback = budget.costs(fallback=90)
        for cls, row in with_sample.items():
            self.assertAlmostEqual(changed_fallback[cls]['body_s'] - row['body_s'],
                                   row['unknown_methods'] * 30)

    def test_current_missing_inventory_and_failed_attempt_costs_are_explicit(self):
        observed = budget.profile()
        self.assertEqual(len(observed['completed_attempt_seconds']), 415)
        self.assertEqual(len(observed['prior_same_source_seconds']), 10)
        self.assertEqual(observed['unknown_methods'], [
            'FeedbackMenuAttachmentUITests/testReopeningSettingsCapturesANewPreSettingsScreenshot'])
        rows = budget.costs()
        self.assertEqual(sum(r['unknown_methods'] for r in rows.values()), 1)
        self.assertEqual(sum(r['historical_methods'] for r in rows.values()), 10)
        self.assertEqual(sum(r['measured_methods'] for r in rows.values()), 415)
        self.assertAlmostEqual(sum(r['body_s'] for r in rows.values()), 22150.907)
        # All six historical Footer attempts stay charged despite the source fix.
        self.assertAlmostEqual(sum(v for k,v in observed['completed_attempt_seconds'].items()
                                   if k.startswith('CompanionComposerFooterSurfaceUITests/testDark') or
                                      k.startswith('CompanionComposerFooterSurfaceUITests/testLight')), 312.293)
        self.assertEqual(budget.report()['assumptions']['unmeasured_Footer_export_and_metadata_savings_s'], 0)

    def test_pinned_route_reproduces_packing_and_early_classes_without_a_false_budget_pass(self):
        classes = budget.costs()
        suggested = budget.assignment(classes, suggest=True)
        current = budget.assignment(classes)
        self.assertEqual(current, suggested)
        for lane, cls in budget.EARLY_CLASSES.items():
            self.assertEqual(min(current[lane]), cls)
        # Existing setup and unknown retries still preclude a speed claim.
        result = budget.report()
        self.assertGreater(result['lower_bound']['average_execution_CP_lower_bound_s'], 3600)
        self.assertGreater(result['lower_bound']['modeled_aggregate_reduction_needed_for_sixty_minute_CP_s'], 600)
        reserved = budget.report(verification=180)
        self.assertAlmostEqual(reserved['modeled_queue_excluded_cp_s'] - result['modeled_queue_excluded_cp_s'], 60)
        self.assertAlmostEqual(reserved['lower_bound']['usable_eight_lane_body_budget_s'],
                               result['lower_bound']['usable_eight_lane_body_budget_s'] - 8*60)

    def test_five_slot_model_exposes_resource_wait_separately(self):
        # Six equal ready jobs: five start at build completion, sixth waits 100s.
        durations = {str(i): 100 for i in range(6)}
        result = budget.five_slot_schedule(durations, list(durations))
        self.assertEqual(result['max_resource_wait_s'], 100)
        self.assertEqual(result['execution_plus_resource_wait_s'], 10 + 562 + 3)
        # The sixth device ends at build + 200s; queue is still separate.
        self.assertGreater(result['max_resource_wait_s'], 0)

    def test_repacking_and_retry_sensitivity_retain_complete_inventory(self):
        classes = budget.costs()
        groups = budget.assignment(classes, suggest=True)
        flattened = [c for group in groups for c in group]
        self.assertEqual(set(flattened), set(classes))
        self.assertEqual(len(flattened), len(classes))
        ordinary = budget.report()
        retried = budget.report(extra_retry=240)
        self.assertEqual(ordinary['inventory_methods'], sum(v['methods'] for v in classes.values()))
        self.assertAlmostEqual(retried['modeled_queue_excluded_cp_s'] - ordinary['modeled_queue_excluded_cp_s'], 240)


if __name__ == '__main__':
    unittest.main()
