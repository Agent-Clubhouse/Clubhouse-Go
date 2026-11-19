"""Synthetic pure probes only. No raw originals, subprocesses or native actions."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('v2trace', Path(__file__).with_name('verify-v2-native-trace.py'))
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
ORDER = ['CompanionPreviewSmokeTests/' + name + '()' for name in v.METHODS]


def events():
    lines = []
    for index, mode in enumerate(v.MODES, 1):
        aid, sid = f'{index:08X}-1111-1111-1111-111111111111', f'{index:08X}-2222-2222-2222-222222222222'
        lines += ['preview provider=codex-cli saved=claude-code unknown=false starts=0', f'apply id={aid} starts=0']
        if mode in ('success', 'lost-start'):
            lines += ['preview provider=codex-cli saved=codex-cli unknown=false starts=0'] * 2
            lines += [f'start id={sid} apply={aid} starts=1']
        if mode in ('lost-apply', 'lost-start'):
            lines += ['preview provider=codex-cli saved=codex-cli unknown=true starts=' + ('0' if mode == 'lost-apply' else '1')]
    return [v.PREFIX + line for line in lines]


class V2TraceTests(unittest.TestCase):
    def test_actual_pinned_packet_order_and_selectors_match_classifier(self):
        proof = Path(__file__).parent
        order = json.loads((proof / 'v2-native-r2-order.json').read_text())
        manifest = json.loads((proof / 'v2-native-r2-manifest.json').read_text())
        self.assertEqual(order, ORDER)
        for phase in ['TPHONE', 'TSE']:
            selectors = manifest['phases'][phase]['selectors']
            self.assertEqual([name.split('/', 1)[1] + '()' for name in selectors], order)
        self.assertEqual(v.verify(events(), order)['counts'], {'preview': 13, 'apply': 5, 'start': 3, 'replay': 0})

    def test_valid_all_five_groups(self):
        self.assertEqual(v.verify(events(), ORDER)['counts'], {'preview': 13, 'apply': 5, 'start': 3, 'replay': 0})

    def test_missing_pre_enable_witness_rejected(self):
        data = events(); del data[2]
        with self.assertRaises(ValueError): v.verify(data, ORDER)

    def test_start_bound_to_another_apply_rejected(self):
        data = events(); data[4] = data[4].replace('apply=00000001-', 'apply=00000002-')
        with self.assertRaises(ValueError): v.verify(data, ORDER)

    def test_reused_start_or_apply_id_rejected(self):
        for old, new in [('00000002-2222-', '00000001-2222-'), ('00000002-1111-', '00000001-1111-')]:
            data = [line.replace(old, new) for line in events()]
            with self.subTest(old=old), self.assertRaises(ValueError): v.verify(data, ORDER)

    def test_unknown_is_not_restored_by_equal_read(self):
        data = events(); data[-1] = data[-1].replace('unknown=true', 'unknown=false')
        with self.assertRaises(ValueError): v.verify(data, ORDER)

    def test_missing_extra_group_or_replay_rejected(self):
        for data in (events()[:-1], events() + events(), events() + [v.PREFIX + 'replay id=anything']):
            with self.subTest(data=data), self.assertRaises(ValueError): v.verify(data, ORDER)

    def test_unknown_start_never_gets_a_second_start(self):
        data = events(); data.append(data[-2])
        with self.assertRaises(ValueError): v.verify(data, ORDER)

    def test_wrong_method_or_order_rejected(self):
        for order in (ORDER[::-1], ORDER[:-1], ORDER + [ORDER[0]]):
            with self.subTest(order=order), self.assertRaises(ValueError): v.verify(events(), order)


if __name__ == '__main__': unittest.main()
