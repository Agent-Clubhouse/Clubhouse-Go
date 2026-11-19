import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('scoped', ROOT / 'verify-v2-scoped-native.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SCOPES = json.loads((ROOT / 'v2-integration-r2-scopes.json').read_text())
PREFIX = module.PREFIX


def example(cases):
    events = []
    for index, case in enumerate(cases, 1):
        mode = case['mode']
        apply = f'00000000-0000-4000-8000-{index:012X}'
        start = f'10000000-0000-4000-8000-{index:012X}'
        events.append(PREFIX + 'preview provider=codex-cli saved=claude-code unknown=false starts=0')
        if mode != 'preview-only':
            events.append(PREFIX + f'apply id={apply} starts=0')
        if mode in ('success', 'lost-start'):
            events += [PREFIX + 'preview provider=codex-cli saved=codex-cli unknown=false starts=0'] * 2
            events.append(PREFIX + f'start id={start} apply={apply} starts=1')
        if mode in ('lost-apply', 'lost-start'):
            events.append(PREFIX + 'preview provider=codex-cli saved=codex-cli unknown=true starts=' + ('0' if mode == 'lost-apply' else '1'))
    return events


class ScopedNativeTests(unittest.TestCase):
    def verify(self, phase, events=None, order=None):
        cases = SCOPES[phase]
        return module.verify(example(cases) if events is None else events,
                             [case['method'] for case in cases] if order is None else order, cases)

    def test_three_affected_SE_cases(self):
        self.assertEqual(self.verify('TSE3')['counts'], dict(preview=9, apply=3, start=2, replay=0))

    def test_two_capture_cases_preserve_readonly_and_no_start(self):
        for phase in ('VPHONE', 'VSE'):
            result = self.verify(phase)
            self.assertEqual(result['counts'], dict(preview=2, apply=1, start=0, replay=0))
            self.assertEqual([group['event_count'] for group in result['groups']], [1, 2])

    def test_actual_frozen_packet_order_and_selectors(self):
        manifest = json.loads((ROOT / 'v2-integration-r2-manifest.json').read_text())
        for phase, cases in SCOPES.items():
            config = manifest['phases'][phase]
            order = json.loads((ROOT / ('v2-integration-r2-' + Path(config['order_file']).name)).read_text())
            self.assertEqual(order, [case['method'] for case in cases])
            self.assertEqual(config['selectors'], ['ClubhouseGoUITests/' + method.removesuffix('()') for method in order])
            self.assertEqual(config['count'], len(order))
            self.assertEqual(config['expected_v2_counts'], self.verify(phase)['counts'])
            self.assertNotIn('fixture_counts', config)

    def test_missing_or_extra_events_reject(self):
        for events in (example(SCOPES['TSE3'])[:-1], example(SCOPES['TSE3']) + [PREFIX + 'apply id=00000000-0000-4000-8000-000000000009 starts=0']):
            with self.assertRaises(ValueError): self.verify('TSE3', events)

    def test_extra_mutation_in_readonly_group_rejects(self):
        events = example(SCOPES['VPHONE'])
        events.insert(1, PREFIX + 'apply id=00000000-0000-4000-8000-000000000009 starts=0')
        with self.assertRaises(ValueError): self.verify('VPHONE', events)

    def test_any_start_in_unsupported_capture_rejects(self):
        events = example(SCOPES['VPHONE']) + [PREFIX + 'start id=10000000-0000-4000-8000-000000000002 apply=00000000-0000-4000-8000-000000000002 starts=1']
        with self.assertRaises(ValueError): self.verify('VPHONE', events)

    def test_wrong_start_binding_or_reused_identity_rejects(self):
        for replacement in (
            'start id=10000000-0000-4000-8000-000000000001 apply=00000000-0000-4000-8000-000000000009 starts=1',
            'start id=00000000-0000-4000-8000-000000000001 apply=00000000-0000-4000-8000-000000000001 starts=1'):
            events = example(SCOPES['TSE3'])
            events[4] = PREFIX + replacement
            with self.assertRaises(ValueError): self.verify('TSE3', events)

    def test_wrong_state_or_replay_rejects(self):
        for replacement in ('preview provider=codex-cli saved=codex-cli unknown=false starts=0',
                            'replay id=00000000-0000-4000-8000-000000000002'):
            events = example(SCOPES['TSE3'])
            events[7] = PREFIX + replacement
            with self.assertRaises(ValueError): self.verify('TSE3', events)

    def test_wrong_method_order_or_extra_group_rejects(self):
        order = [case['method'] for case in SCOPES['TSE3']]
        for bad in (order[::-1], order + [order[0]], order[:-1]):
            with self.assertRaises(ValueError): self.verify('TSE3', order=bad)

    def test_capture_event_group_reordering_rejects(self):
        events = example(SCOPES['VPHONE'])
        with self.assertRaises(ValueError): self.verify('VPHONE', events[1:] + events[:1])


if __name__ == '__main__':
    unittest.main()
