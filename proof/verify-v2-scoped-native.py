"""Offline scoped synthetic traces; never starts apps, processes or commands."""
import argparse
import hashlib
import json
from pathlib import Path
import re

PREFIX = 'PROVIDER_V2_FIXTURE '
UUID = r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}'


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(events, order, cases):
    require(order == [case['method'] for case in cases], 'Wrong/missing/extra/reordered methods')
    require(len(set(order)) == len(order), 'Duplicate methods')
    cursor = 0
    applies, starts, groups = [], [], []

    def take(pattern):
        nonlocal cursor
        require(cursor < len(events), 'Missing event/group')
        result = re.fullmatch(PREFIX + pattern, events[cursor])
        require(result is not None, 'Unexpected identity/order/state/count at event ' + str(cursor))
        cursor += 1
        return result

    for case in cases:
        mode, first = case['mode'], cursor
        require(mode in ('success', 'lost-apply', 'lost-start', 'no-start', 'preview-only'), 'Unknown scope mode')
        apply_id = start_id = None
        take('preview provider=codex-cli saved=claude-code unknown=false starts=0')
        if mode != 'preview-only':
            apply_id = take(r'apply id=(' + UUID + ') starts=0')[1]
            applies.append(apply_id)
        if mode in ('success', 'lost-start'):
            take('preview provider=codex-cli saved=codex-cli unknown=false starts=0')
            take('preview provider=codex-cli saved=codex-cli unknown=false starts=0')
            match = take(r'start id=(' + UUID + ') apply=(' + UUID + ') starts=1')
            require(match[2] == apply_id and match[1] != apply_id, 'Start not bound to its separate Apply')
            start_id = match[1]
            starts.append(start_id)
        if mode in ('lost-apply', 'lost-start'):
            take('preview provider=codex-cli saved=codex-cli unknown=true starts=' + ('0' if mode == 'lost-apply' else '1'))
        groups.append(dict(method=case['method'], mode=mode, event_count=cursor - first,
                           apply_id=apply_id, start_id=start_id))
    require(cursor == len(events), 'Extra event/group/mutation')
    require(len(applies) == len(set(applies)) and len(starts) == len(set(starts))
            and not set(applies).intersection(starts), 'Reused/conflicting command identities')
    counts = dict(preview=sum(' preview ' in line for line in events), apply=len(applies), start=len(starts), replay=0)
    return dict(groups=groups, counts=counts)


def classify(manifest_path, phase, ticket):
    manifest = json.loads(manifest_path.read_text())
    require(digest(Path(__file__)) == manifest['scoped_v2_verifier_sha256'], 'Verifier pin mismatch')
    scope_path = Path(manifest['scoped_v2_map_path'])
    require(digest(scope_path) == manifest['scoped_v2_map_sha256'], 'Scope pin mismatch')
    cases = json.loads(scope_path.read_text())[phase]
    config = manifest['phases'][phase]
    require(config['selectors'] == ['ClubhouseGoUITests/' + c['method'].removesuffix('()') for c in cases], 'Selector/scope mismatch')
    require(config['count'] == len(cases), 'Count/scope mismatch')
    order_path = ticket / 'actual-order.json'
    order = json.loads(order_path.read_text())
    require(json.loads(Path(config['order_file']).read_text()) == order, 'Pinned/actual order mismatch')
    summary = json.loads((ticket / 'summary.json').read_text())
    require(summary['totalTestCount'] == summary['passedTests'] == len(cases)
            and summary['failedTests'] == summary['expectedFailures'] == summary['skippedTests'] == 0, 'Unexpected native outcomes')
    paths = sorted((ticket / 'diagnostics').rglob('StandardOutputAndStandardError-com.Agent-Clubhouse.Go.txt'))
    require(len(paths) == 1, 'Missing/extra complete diagnostic files')
    raw = paths[0].read_bytes()
    lines = raw.decode('utf-8', errors='strict').splitlines()
    require(not any('PROVIDER_APPLY_FIXTURE ' in line for line in lines), 'Unexpected legacy fixture command channel')
    events = [line for line in lines if PREFIX in line]
    result = verify(events, order, cases)
    require(result['counts'] == config['expected_v2_counts'], 'Declared/actual counts mismatch')
    return dict(result, source_head=manifest['head'], phase=phase,
                manifest_sha256=digest(manifest_path), scope_sha256=digest(scope_path),
                verifier_sha256=digest(Path(__file__)), diagnostic_sha256=hashlib.sha256(raw).hexdigest(),
                order_sha256=digest(order_path),
                scope='Exact synthetic fixture counts/order/identity only. Independent originals/visuals/cleanup and production transport evidence remain separate.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('phase')
    parser.add_argument('ticket', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        result = dict(classify(args.manifest, args.phase, args.ticket), accepted=True)
    except (ValueError, KeyError, TypeError, OSError, UnicodeError) as error:
        result = dict(accepted=False, error=str(error))
    with args.output.open('x') as output:
        output.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['accepted'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
