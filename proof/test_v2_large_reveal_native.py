import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location('scoped', ROOT / 'verify-v2-scoped-native.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SCOPES = json.loads((ROOT / 'v2-integration-r11-scopes.json').read_text())
PREFIX = module.PREFIX

def example(cases):
    events = []
    for i, case in enumerate(cases, 1):
        a, s = f'00000000-0000-4000-8000-{i:012X}', f'10000000-0000-4000-8000-{i:012X}'
        events.append(PREFIX + 'preview provider=codex-cli saved=claude-code unknown=false starts=0')
        if case['mode'] != 'preview-only': events.append(PREFIX + f'apply id={a} starts=0')
        if case['mode'] == 'success':
            events += [PREFIX + 'preview provider=codex-cli saved=codex-cli unknown=false starts=0'] * 2
            events.append(PREFIX + f'start id={s} apply={a} starts=1')
    return events

class LargeRevealTests(unittest.TestCase):
    def verify(self, phase='TSELARGE', events=None, order=None):
        cases = SCOPES[phase]
        return module.verify(example(cases) if events is None else events,
            [c['method'] for c in cases] if order is None else order, cases)
    def test_large_single_case(self):
        self.assertEqual(self.verify()['counts'], dict(preview=3, apply=1, start=1, replay=0))
    def test_capture_two_cases(self):
        for phase in ('VPHONE', 'VSE'):
            self.assertEqual(self.verify(phase)['counts'], dict(preview=2, apply=1, start=0, replay=0))
    def test_actual_packet_orders_selectors_and_counts(self):
        m = json.loads((ROOT / 'v2-integration-r11-manifest.json').read_text())
        self.assertNotIn('TSE3', m['phases'])
        self.assertNotIn('D', m['phases'])
        for phase, cases in SCOPES.items():
            cfg = m['phases'][phase]
            order = json.loads((ROOT / ('v2-integration-r11-' + Path(cfg['order_file']).name)).read_text())
            self.assertEqual(order, [c['method'] for c in cases])
            self.assertEqual(cfg['selectors'], ['ClubhouseGoUITests/' + c.removesuffix('()') for c in order])
            self.assertEqual(cfg['count'], len(order))
            self.assertEqual(cfg['expected_v2_counts'], self.verify(phase)['counts'])
    def test_missing_or_extra_events(self):
        for ev in (example(SCOPES['TSELARGE'])[:-1], example(SCOPES['TSELARGE']) + [PREFIX + 'preview provider=codex-cli saved=claude-code unknown=false starts=0']):
            with self.assertRaises(ValueError): self.verify(events=ev)
    def test_wrong_start_binding(self):
        ev = example(SCOPES['TSELARGE']); ev[-1] = ev[-1].replace('apply=00000000-0000-4000-8000-000000000001', 'apply=00000000-0000-4000-8000-000000000002')
        with self.assertRaises(ValueError): self.verify(events=ev)
    def test_start_cannot_reuse_apply_identity(self):
        ev = example(SCOPES['TSELARGE']); ev[-1] = ev[-1].replace('id=10000000', 'id=00000000')
        with self.assertRaises(ValueError): self.verify(events=ev)
    def test_wrong_state_or_replay(self):
        for value in ('preview provider=codex-cli saved=codex-cli unknown=true starts=0', 'replay id=00000000-0000-4000-8000-000000000001'):
            ev = example(SCOPES['TSELARGE']); ev[2] = PREFIX + value
            with self.assertRaises(ValueError): self.verify(events=ev)
    def test_missing_extra_or_wrong_method(self):
        order = [c['method'] for c in SCOPES['TSELARGE']]
        for bad in ([], order + order, ['CompanionPreviewSmokeTests/wrong()']):
            with self.assertRaises(ValueError): self.verify(order=bad)
    def test_capture_has_no_extra_mutation_or_start(self):
        for value in ('apply id=00000000-0000-4000-8000-000000000003 starts=0', 'start id=10000000-0000-4000-8000-000000000002 apply=00000000-0000-4000-8000-000000000002 starts=1'):
            ev = example(SCOPES['VPHONE']); ev.insert(1, PREFIX + value)
            with self.assertRaises(ValueError): self.verify('VPHONE', ev)
    def test_capture_group_reordering(self):
        ev = example(SCOPES['VSE'])
        with self.assertRaises(ValueError): self.verify('VSE', ev[1:] + ev[:1])

if __name__ == '__main__': unittest.main()
