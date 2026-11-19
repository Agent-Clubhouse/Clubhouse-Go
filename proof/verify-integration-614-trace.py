"""Offline one-group classification. Never edits or overrides the native ticket verdict."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

PREFIX = 'PROVIDER_APPLY_FIXTURE '
SELECTORS = [
    'CompanionPreviewSmokeTests/testProviderApplyLostReceiptStaysLockedUntilItsResultIsChecked()',
    'CompanionReadingOpeningUITests/testPausedTranscriptArchiveHeaderStillOpensAndClosesAfterStreaming()',
]
COUNTS = {'preview': 2, 'change': 1, 'replay': 1, 'start': 1}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_events(events, expected_apply, expected_start):
    """IDs come from a frozen reviewed scope, never learned from the tested events."""
    for value in (expected_apply, expected_start):
        require(isinstance(value, str) and re.fullmatch(r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}', value),
                'Invalid frozen command identity')
    require(expected_apply != expected_start, 'Apply and Start must be distinct')
    expected = [
        PREFIX + 'preview proposed=codex-cli saved=claude-code starts=0',
        PREFIX + f'change id={expected_apply} saved=codex-cli starts=0',
        PREFIX + f'replay change id={expected_apply}',
        PREFIX + 'preview proposed=codex-cli saved=codex-cli starts=0',
        PREFIX + f'start id={expected_start} expected=codex-cli starts=1',
    ]
    require(events == expected, 'Not the exact frozen one-group event order/IDs/state/count')
    return COUNTS.copy()


def read_pinned(root, pin):
    relative = Path(pin['path'])
    require(not relative.is_absolute() and '..' not in relative.parts, 'Pin must remain inside proof root')
    path = (root / relative).resolve()
    require(path.is_relative_to(root.resolve()), 'Pin escapes proof root')
    data = path.read_bytes()
    require(hashlib.sha256(data).hexdigest() == pin['sha256'], 'Input hash mismatch: ' + str(relative))
    return data


def verify(root, scope):
    require(scope['schema'] == 1, 'Unknown scope')
    inputs = {key: read_pinned(root, pin) for key, pin in scope['inputs'].items()}
    manifest = json.loads(inputs['manifest'])
    receipt = json.loads(inputs['receipt'])
    trace = json.loads(inputs['trace_index'])
    order = json.loads(inputs['actual_order'])
    summary = json.loads(inputs['summary'])
    require(manifest['head'] == receipt['head'] == scope['head'], 'Wrong source head')
    require(receipt['manifest_sha256'] == scope['inputs']['manifest']['sha256'], 'Wrong executed manifest')
    require(receipt['runner_sha256'] == scope['runner_sha256'], 'Wrong executed core runner')
    require(receipt['rc'] == 1 and receipt['fixture_order_identity_ok'] is False and bool(receipt['stop']),
            'Original ticket STOP must remain intact')
    require(all(receipt[key] == 0 for key in ('test_rc', 'summary_rc', 'tests_rc', 'audit_rc',
                                             'attachments_rc', 'diagnostics_rc')), 'Native extraction/test failure')
    require(all(receipt[key] is True for key in ('exact_identifiers_ok', 'order_ok', 'outcome_map_ok')),
            'Original selector audit mismatch')
    require(order == SELECTORS, 'Wrong/missing/extra/reordered method identities')
    require(summary == receipt['summary'], 'Summary projection mismatch')
    require(summary['totalTestCount'] == summary['passedTests'] == 2 and summary['result'] == 'Passed',
            'Not two native passes')
    require(all(summary[key] == 0 for key in ('failedTests', 'expectedFailures', 'skippedTests')),
            'Unexpected native outcome')
    require(len(trace) == 1 and receipt['synthetic_command_trace_files'] == 1, 'Missing/extra trace groups')
    require(trace[0]['sha256'] == scope['inputs']['diagnostic']['sha256'], 'Trace diagnostic pin mismatch')
    require(Path(trace[0]['path']).resolve() == (root / scope['inputs']['diagnostic']['path']).resolve(),
            'Trace diagnostic path mismatch')
    raw = inputs['diagnostic'].decode('utf-8', errors='strict')
    events = [line for line in raw.splitlines() if PREFIX in line]
    require(events == trace[0]['events'], 'Trace projection differs from retained original')
    counts = verify_events(events, scope['apply_id'], scope['start_id'])
    require(receipt['fixture_counts'] == counts, 'Original receipt counts mismatch')
    require(receipt['fixture_command_ids'] == {'changes': [scope['apply_id']], 'starts': [scope['start_id']],
                                             'replays': [scope['apply_id']]}, 'Receipt command identity mismatch')
    return {'classification': 'scoped_one_group_trace_pass', 'original_ticket_rc': receipt['rc'],
            'original_ticket_stop': receipt['stop'], 'native_selectors': SELECTORS,
            'counts': counts, 'apply_id': scope['apply_id'], 'replay_id': scope['apply_id'],
            'start_id': scope['start_id'], 'scope_limits':
            'Offline synthetic trace only; original-container/visual/cleanup/main identity require separate review. '
            'No native rerun, V2 recovery, payload-byte, real-session or blanket ticket-PASS claim.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('scope', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    scope_bytes = args.scope.read_bytes()
    result = {'scope_sha256': hashlib.sha256(scope_bytes).hexdigest(),
              'verifier_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    try:
        result.update(verify(args.root, json.loads(scope_bytes)))
        result['accepted'] = True
    except (ValueError, KeyError, TypeError, OSError, UnicodeError) as error:
        result.update(accepted=False, error=str(error))
    with args.output.open('x') as output:
        output.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['accepted'] else 1


if __name__ == '__main__':
    sys.exit(main())
