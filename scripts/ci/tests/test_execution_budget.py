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

    def test_five_slot_model_exposes_resource_wait_separately(self):
        # Six equal ready jobs: five start at build completion, sixth waits 100s.
        durations = {str(i): 100 for i in range(6)}
        result = budget.five_slot_schedule(durations, list(durations))
        self.assertEqual(result['max_resource_wait_s'], 100)
        self.assertEqual(result['execution_plus_resource_wait_s'], 7 + 477 + 4)
        # Release still determines completion despite UI resource waiting.
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
