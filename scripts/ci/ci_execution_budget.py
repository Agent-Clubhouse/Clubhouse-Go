#!/usr/bin/env python3
"""Reproduce the eight-lane estimate; estimates never select or waive tests.

Latest same-source full-run terminal attempt totals take precedence, then the
accepted historical all-attempt median, then 60 seconds per unsampled method.
Only the source-comparable sampled Live E2E offline guard is costed as a skip;
every other unknown remains 60 seconds. Actual completion and
coverage on the exact hosted head remain mandatory.
"""
import argparse
import heapq
import json
from pathlib import Path
import ui_scope
import ui_shards

ROOT = Path(__file__).resolve().parents[2]


def costs(root=ROOT, fallback=60, offline=True):
    inventory = ui_scope.Inventory(root)
    measured = json.loads((root / 'scripts/ci/ui_execution_observations.json').read_text())['observed_attempt_seconds']
    if offline:
        skips = json.loads((root / 'scripts/ci/offline_skip_observations.json').read_text())
        measured.update({'CompanionLiveE2ETests/' + k: v for k, v in
                         skips['conservative_method_seconds_including_suite_overhead'].items()})
    classes = {}
    for cls, methods in inventory.methods.items():
        row = dict(measured_s=0, historical_s=0, unknown_s=0, unknown_methods=0, methods=len(methods))
        for method in methods:
            key = cls + '/' + method
            if key in measured:
                row['measured_s'] += measured[key]
            elif method in inventory.timings.get(cls, {}):
                row['historical_s'] += inventory.timings[cls][method][0]
            else:
                row['unknown_s'] += fallback
                row['unknown_methods'] += 1
        row['body_s'] = sum(row[k] for k in ('measured_s', 'historical_s', 'unknown_s'))
        classes[cls] = row
    return classes


def assignment(classes, suggest=False):
    if suggest:
        # Hosted bundle runs before UI in exactly one job. Its measured 620s
        # span plus the second runner startup is budgeted separately from UI.
        loads, groups = [0.0] * 8, [[] for _ in range(8)]
        loads[6] = 713
        for cls in sorted(classes, key=lambda c: (-classes[c]['body_s'], c)):
            slot = min(range(8), key=lambda i: (loads[i], i))
            groups[slot].append(cls)
            loads[slot] += classes[cls]['body_s']
        return groups
    groups = [list(s['tests'] or []) for s in ui_shards.SHARDS]
    groups[7] = sorted(set(classes) - {c for group in groups for c in group})
    return groups


def five_slot_schedule(durations, order):
    # A plausible work-conserving five-macOS-slot schedule, NOT an observation
    # or a GitHub queue guarantee. Build, packages and Release are ready first.
    active = [(264, 'build'), (299, 'packages'), (477, 'Release')]
    heapq.heapify(active)
    pending, ready, now, queues = [], False, 0, {}
    while active or pending:
        if pending and len(active) < 5:
            name = pending.pop(0)
            queues[name] = now - 264
            heapq.heappush(active, (now + durations[name], name))
            continue
        now, name = heapq.heappop(active)
        if name == 'build':
            ready = True
            pending = list(order)
    assert ready
    return dict(execution_plus_resource_wait_s=7 + now + 4,
                max_resource_wait_s=max(queues.values()), resource_wait_by_job_s=queues)


def report(root=ROOT, fallback=60, overhead=430, extra_retry=0, suggest=False, offline=True):
    classes = costs(root, fallback, offline)
    groups = assignment(classes, suggest)
    lanes = []
    for i, group in enumerate(groups):
        row = dict(name=ui_shards.SHARDS[i]['name'], classes=sorted(group))
        for field in ('measured_s', 'historical_s', 'unknown_s', 'unknown_methods', 'methods', 'body_s'):
            row[field] = round(sum(classes[c][field] for c in group), 3)
        row['hosted_and_second_startup_s'] = 713 if i == 6 else 0
        row['modeled_execution_s'] = round(row['body_s'] + overhead + row['hosted_and_second_startup_s'] + extra_retry, 3)
        row['dominant_classes'] = sorted(((c, round(classes[c]['body_s'], 3)) for c in group), key=lambda x: -x[1])[:3]
        lanes.append(row)
    durations = {r['name']: r['modeled_execution_s'] for r in lanes}
    durations['iPad'] = 1223
    cp = 7 + max(299, 477, 264 + max(durations.values())) + 4
    return dict(assumptions=dict(unknown_method_s=fallback, measured_offline_skip=offline, per_ui_job_overhead_s=overhead,
                                 extra_retry_per_ui_lane_s=extra_retry, slots=5,
                                 prePlan_and_external_queue='excluded, record separately on actual run'),
                inventory_classes=len(classes), inventory_methods=sum(c['methods'] for c in classes.values()),
                lanes=lanes, modeled_queue_excluded_cp_s=round(cp, 3),
                plausible_five_slot_schedules={
                    'matrix_then_ipad': five_slot_schedule(durations, list(durations)),
                    'ipad_then_longest': five_slot_schedule(durations, ['iPad'] + sorted((k for k in durations if k != 'iPad'), key=lambda k: -durations[k])),
                })


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unknown-seconds', type=float, default=60)
    parser.add_argument('--overhead-seconds', type=float, default=430)
    parser.add_argument('--extra-retry-seconds', type=float, default=0)
    parser.add_argument('--suggest', action='store_true', help='show deterministic whole-class LPT placement instead')
    parser.add_argument('--without-skip-sample', action='store_true', help='retain 60s fallback for the 15 sampled offline skips too')
    args = parser.parse_args()
    print(json.dumps(report(fallback=args.unknown_seconds, overhead=args.overhead_seconds,
                            extra_retry=args.extra_retry_seconds, suggest=args.suggest,
                            offline=not args.without_skip_sample), indent=2))
