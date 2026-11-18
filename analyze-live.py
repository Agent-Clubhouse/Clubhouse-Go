#!/usr/bin/env python3
"""Offline #570 paired live gate; preserves all sites and every batch."""
import json, sys
from pathlib import Path

R = Path('/tmp/ux-528-visible-proof')
M = json.loads((R / 'manifest.json').read_text())

def load(receipt, index):
    row = receipt['runs'][index]
    root = Path(row['result_bundle']).parent
    manifest = json.loads((root / 'attachments/manifest.json').read_text())
    names = [a['exportedFileName'] for test in manifest for a in test['attachments']
             if a['suggestedHumanReadableName'].startswith('Home live-visible two-case stream measurement JSON_')]
    assert len(names) == 1, 'One actual JSON measurement attachment per invocation'
    return json.loads((root / 'attachments' / names[0]).read_text())

def deltas(window):
    previous = window['initial']
    result = []
    assert len(window['batches']) == 10
    for index, sample in enumerate(window['batches']):
        assert sample['batch'] == index
        current = sample['counts']
        delta = {key: current.get(key, 0) - previous.get(key, 0) for key in sorted(set(current) | set(previous))}
        assert all(value >= 0 for value in delta.values())
        result.append(delta)
        previous = current
    return result

before = json.loads((R / 'success-L-before.json').read_text())
after = json.loads((R / 'success-L-after.json').read_text())
assert before['rc'] == after['rc'] == 0 and after['head'] == M['head']
assert before['overlay']['method_sha256'] == after['overlay']['method_sha256'] == M['r2_method_sha256']
assert before['overlay']['additive_inverse_verified'] and after['overlay']['additive_inverse_verified']
assert len(before['runs']) == len(after['runs']) == 2
result = {'head': M['head'], 'base': before['head'], 'uncredited': True,
          'method_sha256': M['r2_method_sha256'], 'pairs': [], 'failures': [], 'bar_approval': 'Orchestrator t_mwkvyvft: visible b0 <=1 owner/inputs/content/layout and <=24 header; later/outside zero; other sites <=main'}
primary = ('owner', 'contentInputs', 'content', 'layout', 'header')
lines = ['# #570 paired live counts', '', 'Approved bar: visible b0 <=1 owner/inputs/content/layout and <=24 header; visible b1-9/outside all zero. Original zero-bar failure is preserved separately.',
         'All other sites retained and compared to paired main; no discarded or normalized samples.', '']
for index in range(2):
    b, a = load(before, index), load(after, index)
    assert b['scope'] == a['scope'] == 'synthetic-host-0'
    assert len(b['cases']) == len(a['cases']) == 2
    pair = {'run': index + 1, 'cases': []}
    for bc, ac in zip(b['cases'], a['cases']):
        assert bc['name'] == ac['name'] and bc['chunks'] == ac['chunks'] == 100
        case = {'name': bc['name'], 'windows': {}, 'gates': []}
        for window in ('idle', 'streaming'):
            case['windows'][window] = {'base': deltas(bc[window]), 'head': deltas(ac[window]),
                'cpu_seconds': {'base': bc[window]['processCPUSeconds'], 'head': ac[window]['processCPUSeconds']},
                'wall_seconds': {'base': bc[window]['wallSeconds'], 'head': ac[window]['wallSeconds']}}
        lines += [f"## Run {index+1}: {bc['name']}", '', '| Batch | Main owner/content/layout/header | Head owner/inputs/content/layout/header | Main/head dispatcherContent | Main/head rowMenu | Head menu modifier/native/items/terminal |',
                  '| --- | --- | --- | --- | --- | --- |']
        for batch, (base, head) in enumerate(zip(case['windows']['streaming']['base'], case['windows']['streaming']['head'])):
            limits = {key: (24 if key == 'header' else 1) if bc['name'] == 'visible-dispatcher' and batch == 0 else 0 for key in primary}
            gate = {'batch': batch, 'primary_zero': all(head.get(key, 0) == 0 for key in primary),
                    'approved_primary_pass': all(head.get(key, 0) <= limits[key] for key in primary), 'approved_limits': limits,
                    'other_sites_above_main': {key: {'main': base.get(key, 0), 'head': head.get(key, 0)}
                        for key in sorted(set(base) | set(head)) if key not in primary and head.get(key, 0) > base.get(key, 0)}}
            case['gates'].append(gate)
            if not gate['approved_primary_pass'] or gate['other_sites_above_main']:
                result['failures'].append({'run': index+1, 'case': bc['name'], **gate})
            def values(counts, keys): return '/'.join(str(counts.get(key, 0)) for key in keys)
            lines.append(f"| {batch} | {values(base, ('owner','content','layout','header'))} | {values(head, primary)} | {base.get('dispatcherContent',0)}/{head.get('dispatcherContent',0)} | {base.get('rowMenu',0)}/{head.get('rowMenu',0)} | {values(head, ('rowMenuModifier','rowMenuNative','rowMenuItems','rowMenuTerminal'))} |")
        pair['cases'].append(case)
        lines += ['', 'Idle controls, all other counters and process CPU/wall seconds are retained in live-gate.json.', '']
    result['pairs'].append(pair)
result['zero_primary_pass'] = all(gate['primary_zero'] for pair in result['pairs'] for case in pair['cases'] for gate in case['gates'])
result['primary_pass'] = all(gate['approved_primary_pass'] for pair in result['pairs'] for case in pair['cases'] for gate in case['gates'])
result['pass'] = not result['failures']
(R / 'live-gate.json').write_text(json.dumps(result, indent=2) + '\n')
(R / 'live-table.md').write_text('\n'.join(lines) + '\n')
print(json.dumps({key: value for key, value in result.items() if key != 'pairs'}, indent=2))
sys.exit(0 if result['pass'] else 1)
