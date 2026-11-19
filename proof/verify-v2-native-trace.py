"""Offline synthetic V2 trace map; no commands, subprocesses, app or network actions."""
import argparse
import hashlib
import json
from pathlib import Path
import re

PREFIX = 'PROVIDER_V2_FIXTURE '
UUID = r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}'
METHODS = [
    'testProviderV2ApplyAndStartStaySeparate',
    'testProviderV2ApplyAtAccessibilityLargeKeepsReviewReachable',
    'testProviderV2ApplyDoesNotImplyStartCapability',
    'testProviderV2LostApplyStaysUnknownAfterReopeningAndEqualRead',
    'testProviderV2LostStartNeverRequestsAnotherStart',
]
MODES = ['success', 'success', 'no-start', 'lost-apply', 'lost-start']


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def verify(events, actual_method_order):
    require(actual_method_order == ['CompanionPreviewSmokeTests/' + name + '()' for name in METHODS],
            'Wrong/missing/extra/reordered native methods')
    cursor = 0
    apply_ids, start_ids, groups = [], [], []
    def take(pattern):
        nonlocal cursor
        require(cursor < len(events), 'Missing event/group')
        match = re.fullmatch(PREFIX + pattern, events[cursor])
        require(match is not None, 'Unexpected identity/order/state/count at event ' + str(cursor))
        cursor += 1
        return match
    for method, mode in zip(METHODS, MODES):
        first = cursor
        take('preview provider=codex-cli saved=claude-code unknown=false starts=0')
        apply_id = take(r'apply id=(' + UUID + r') starts=0')[1]
        apply_ids.append(apply_id)
        if mode in ('success', 'lost-start'):
            # Fresh current witness BEFORE enabling, then AGAIN after explicit confirmation.
            take('preview provider=codex-cli saved=codex-cli unknown=false starts=0')
            take('preview provider=codex-cli saved=codex-cli unknown=false starts=0')
            start = take(r'start id=(' + UUID + r') apply=(' + UUID + r') starts=1')
            require(start[2] == apply_id and start[1] != apply_id, 'Start not bound to its separate Apply')
            start_ids.append(start[1])
        if mode in ('lost-apply', 'lost-start'):
            count = '0' if mode == 'lost-apply' else '1'
            take('preview provider=codex-cli saved=codex-cli unknown=true starts=' + count)
        groups.append({'method': method, 'mode': mode, 'event_count': cursor - first,
                       'apply_id': apply_id, 'start_id': start_ids[-1] if mode in ('success', 'lost-start') else None})
    require(cursor == len(events), 'Extra event/group/mutation')
    require(len(set(apply_ids)) == 5 and len(set(start_ids)) == 3 and not set(apply_ids).intersection(start_ids),
            'Reused/conflicting command identity')
    return {'groups': groups, 'counts': {'preview': 13, 'apply': 5, 'start': 3, 'replay': 0},
            'scope': 'Synthetic fixture trace order/identity/count only; native originals/cancellation/visual and actual transport zero-redispatch require independent evidence.'}


def classify(ticket):
    """Inspect every exported diagnostic stdout; do not trust a prefix-filtered saved projection."""
    files = sorted((ticket / 'diagnostics').rglob('StandardOutputAndStandardError-com.Agent-Clubhouse.Go.txt'))
    require(len(files) == 1, 'Missing/extra diagnostic stdout files')
    path = files[0]
    raw = path.read_bytes()
    events = [line for line in raw.decode('utf-8', errors='strict').splitlines() if PREFIX in line]
    order = json.loads((ticket / 'actual-order.json').read_text())
    result = verify(events, order)
    return dict(result, diagnostic_sha256=hashlib.sha256(raw).hexdigest(),
                order_sha256=hashlib.sha256((ticket / 'actual-order.json').read_bytes()).hexdigest(),
                verifier_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ticket', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        result = dict(classify(args.ticket), accepted=True)
    except (ValueError, KeyError, TypeError, OSError, UnicodeError) as error:
        result = dict(accepted=False, error=str(error))
    with args.output.open('x') as output:
        output.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['accepted'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
