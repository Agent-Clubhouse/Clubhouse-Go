"""Pure synthetic negative probes. No subprocess, simulator, original logs or app actions."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('scoped', Path(__file__).with_name('verify-integration-614-trace.py'))
scoped = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scoped)
A = '11111111-1111-1111-1111-111111111111'
B = '22222222-2222-2222-2222-222222222222'
C = '33333333-3333-3333-3333-333333333333'


def fixture():
    return [scoped.PREFIX + s for s in [
        'preview proposed=codex-cli saved=claude-code starts=0',
        f'change id={A} saved=codex-cli starts=0',
        f'replay change id={A}',
        'preview proposed=codex-cli saved=codex-cli starts=0',
        f'start id={B} expected=codex-cli starts=1']]


class ScopedTraceTests(unittest.TestCase):
    def test_valid_frozen_single_group(self):
        self.assertEqual(scoped.verify_events(fixture(), A, B), scoped.COUNTS)

    def test_mismatched_replay(self):
        events = fixture(); events[2] = events[2].replace(A, C)
        with self.assertRaises(ValueError): scoped.verify_events(events, A, B)

    def test_new_disjoint_start_id(self):
        events = fixture(); events[4] = events[4].replace(B, C)
        with self.assertRaises(ValueError): scoped.verify_events(events, A, B)

    def test_start_reuses_apply_id(self):
        events = fixture(); events[4] = events[4].replace(B, A)
        with self.assertRaises(ValueError): scoped.verify_events(events, A, B)

    def test_missing_start_or_entire_group(self):
        for events in (fixture()[:-1], []):
            with self.subTest(events=events), self.assertRaises(ValueError): scoped.verify_events(events, A, B)

    def test_extra_group_or_mutation(self):
        for events in (fixture() * 2, fixture() + [fixture()[-1]], fixture() + [scoped.PREFIX + 'unknown mutation']):
            with self.subTest(events=events), self.assertRaises(ValueError): scoped.verify_events(events, A, B)

    def test_wrong_order(self):
        events = fixture(); events[2], events[3] = events[3], events[2]
        with self.assertRaises(ValueError): scoped.verify_events(events, A, B)

    def test_start_before_explicit_start_state(self):
        events = fixture(); events[3] = events[3].replace('starts=0', 'starts=1')
        with self.assertRaises(ValueError): scoped.verify_events(events, A, B)


if __name__ == '__main__': unittest.main()
