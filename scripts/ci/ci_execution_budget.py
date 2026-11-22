#!/usr/bin/env python3
"""Reproduce measured whole-class placement without treating a model as proof.

Keep all completed failed/passing attempts. Budget the eleven missing f7a IDs
explicitly: ten prior same-source samples, one 60s unknown. Setup and a 120s
verification reserve are visible; no unmeasured correction receives a discount.
"""
import argparse
import heapq
import json
from pathlib import Path
import ui_scope
import ui_shards

ROOT = Path(__file__).resolve().parents[2]
# Known first-failure classes are the alphabetically earliest current class in
# these lanes. XCTest's observed alphabetical order is not a scheduling API.
# The hosted lane accepts earlier passing classes; future classes stay catch-all.
EARLY_CLASSES = {
    0: 'CompanionHeaderReflowUITests',
    1: 'CompanionAgentRowMenuUITests',
    2: 'CompanionAppUpdateUITests',
    3: 'CompanionComposerFooterSurfaceUITests',
}


def profile(root=ROOT):
    return json.loads((root / 'scripts/ci/full_execution_observations.json').read_text())


def costs(root=ROOT, fallback=60, offline=True):
    inventory, observed = ui_scope.Inventory(root), profile(root)
    current = observed['completed_attempt_seconds']
    prior = observed['prior_same_source_seconds']
    classes = {}
    for cls, methods in inventory.methods.items():
        row = dict(measured_s=0, historical_s=0, unknown_s=0, unknown_methods=0,
                   measured_methods=0, historical_methods=0, methods=len(methods))
        for method in methods:
            key = cls + '/' + method
            if not offline and cls == 'CompanionLiveE2ETests':
                row['unknown_s'] += fallback
                row['unknown_methods'] += 1
            elif key in current:
                row['measured_s'] += current[key]
                row['measured_methods'] += 1
            elif key in prior:
                row['historical_s'] += prior[key]
                row['historical_methods'] += 1
            else:
                row['unknown_s'] += fallback
                row['unknown_methods'] += 1
        row['body_s'] = sum(row[k] for k in ('measured_s', 'historical_s', 'unknown_s'))
        classes[cls] = row
    return classes


def assignment(classes, suggest=False, hosted_s=None):
    if suggest:
        loads, groups = [0.0] * 8, [[] for _ in range(8)]
        loads[6] = profile()['hosted_and_second_startup_s'] if hosted_s is None else hosted_s
        for slot, cls in EARLY_CLASSES.items():
            if cls in classes:
                groups[slot].append(cls)
                loads[slot] += classes[cls]['body_s']
        anchored = {c for group in groups for c in group}
        for cls in sorted(set(classes) - anchored, key=lambda c: (-classes[c]['body_s'], c)):
            # Preserve early-class placement under the observed lexical order.
            eligible = [i for i in range(8) if i not in EARLY_CLASSES or cls > EARLY_CLASSES[i]]
            slot = min(eligible, key=lambda i: (loads[i], i))
            groups[slot].append(cls)
            loads[slot] += classes[cls]['body_s']
        # Deterministic bounded local improvement: swaps/moves may lower the
        # maximum without splitting a class or displacing an early anchor.
        def allowed(cls, slot):
            return slot not in EARLY_CLASSES or cls > EARLY_CLASSES[slot]
        for _ in range(100):
            before = (max(loads), sum(v*v for v in loads))
            best = None
            for left in range(8):
                for cls in sorted(groups[left]):
                    if cls == EARLY_CLASSES.get(left):
                        continue
                    for right in range(8):
                        if left == right or not allowed(cls, right):
                            continue
                        for other in [None] + sorted(groups[right]):
                            if other == EARLY_CLASSES.get(right) or (other and not allowed(other, left)):
                                continue
                            delta = classes[cls]['body_s'] - (classes[other]['body_s'] if other else 0)
                            trial = loads.copy()
                            trial[left] -= delta
                            trial[right] += delta
                            objective = (max(trial), sum(v*v for v in trial))
                            if objective[0] < before[0] - 0.000001 and (best is None or objective < best[0]):
                                best = (objective, left, cls, right, other, trial)
            if best is None:
                break
            _, left, cls, right, other, loads = best
            groups[left].remove(cls)
            groups[right].append(cls)
            if other:
                groups[right].remove(other)
                groups[left].append(other)
        return [sorted(group) for group in groups]
    groups = [list(s['tests'] or []) for s in ui_shards.SHARDS]
    groups[7] = sorted(set(classes) - {c for group in groups for c in group})
    return groups


def five_slot_schedule(durations, order, observed=None):
    """Plausible work-conserving schedule, not a GitHub queue guarantee."""
    observed = profile() if observed is None else observed
    build = observed['build_s']
    active = [(build, 'build'), (observed['packages_s'], 'packages'), (observed['release_s'], 'Release')]
    heapq.heapify(active)
    pending, ready, now, queues = [], False, 0, {}
    while active or pending:
        if pending and len(active) < 5:
            name = pending.pop(0)
            queues[name] = now - build
            heapq.heappush(active, (now + durations[name], name))
            continue
        now, name = heapq.heappop(active)
        if name == 'build':
            ready = True
            pending = list(order)
    assert ready
    return dict(execution_plus_resource_wait_s=observed['plan_s'] + now + observed['result_s'],
                max_resource_wait_s=max(queues.values()), resource_wait_by_job_s=queues)


def report(root=ROOT, fallback=60, overhead=315, verification=120, extra_retry=0, suggest=False, offline=True):
    observed = profile(root)
    classes = costs(root, fallback, offline)
    groups = assignment(classes, suggest, observed['hosted_and_second_startup_s'])
    lanes = []
    for i, group in enumerate(groups):
        row = dict(name=ui_shards.SHARDS[i]['name'], classes=sorted(group))
        for field in ('measured_s', 'historical_s', 'unknown_s', 'unknown_methods',
                      'measured_methods', 'historical_methods', 'methods', 'body_s'):
            row[field] = round(sum(classes[c][field] for c in group), 6)
        row['hosted_and_second_startup_s'] = observed['hosted_and_second_startup_s'] if i == 6 else 0
        row['modeled_execution_s'] = round(row['body_s'] + overhead + verification + row['hosted_and_second_startup_s'] + extra_retry, 6)
        row['remaining_job_budget_s'] = round(3300 - row['modeled_execution_s'], 6)
        row['earliest_current_class'] = min(group)
        row['dominant_classes'] = sorted(((c, round(classes[c]['body_s'], 3)) for c in group), key=lambda x: -x[1])[:3]
        lanes.append(row)
    durations = {r['name']: r['modeled_execution_s'] for r in lanes}
    durations['iPad'] = observed['ipad_s']
    cp = observed['plan_s'] + max(observed['packages_s'], observed['release_s'], observed['build_s'] + max(durations.values())) + observed['result_s']
    total_work = sum(r['body_s'] + r['hosted_and_second_startup_s'] for r in lanes)
    usable = 8 * (3300 - overhead - verification)
    target_lane_s = 3600 - observed['plan_s'] - observed['build_s'] - observed['result_s']
    target_body_budget = 8 * (target_lane_s - overhead - verification)
    envelopes = [r['remaining_non_test_envelope_s'] for r in observed['lanes']]
    return dict(assumptions=dict(unknown_method_s=fallback, measured_offline_skip=offline,
                                 preparation_runner_upload_s=overhead, verification_reserve_s=verification,
                                 extra_retry_per_ui_lane_s=extra_retry, slots=5,
                                 unmeasured_Footer_export_and_metadata_savings_s=0,
                                 prePlan_and_external_queue='excluded, record separately on actual run'),
                source_baseline=dict(run=observed['run'], head=observed['head'], status=observed['status']),
                inventory_classes=len(classes), inventory_methods=sum(c['methods'] for c in classes.values()),
                observed_non_test_envelope_s=dict(min=min(envelopes), max=max(envelopes), mean=sum(envelopes)/8,
                                                note='Includes any completed verification; cancellation can omit it. The fixed total reserve is not added to this envelope.'),
                lower_bound=dict(total_body_plus_hosted_s=round(total_work, 6), average_body_plus_hosted_s=round(total_work/8, 6),
                                 usable_eight_lane_body_budget_s=round(usable, 6), body_excess_over_usable_budget_s=round(max(0, total_work-usable), 6),
                                 sixty_minute_target_lane_s=target_lane_s,
                                 modeled_aggregate_reduction_needed_for_sixty_minute_CP_s=round(max(0, total_work-target_body_budget), 6),
                                 average_execution_CP_lower_bound_s=round(observed['plan_s'] + observed['build_s'] + observed['result_s'] + total_work/8 + overhead + verification, 6)),
                lanes=lanes, modeled_queue_excluded_cp_s=round(cp, 6),
                plausible_five_slot_schedules={
                    'matrix_then_ipad': five_slot_schedule(durations, list(durations), observed),
                    'ipad_then_longest': five_slot_schedule(durations, ['iPad'] + sorted((k for k in durations if k != 'iPad'), key=lambda k: -durations[k]), observed),
                })


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unknown-seconds', type=float, default=60)
    parser.add_argument('--overhead-seconds', type=float, default=315, help='preparation, runner, upload and cleanup allowance; excludes explicit verification reserve')
    parser.add_argument('--verification-seconds', type=float, default=120)
    parser.add_argument('--extra-retry-seconds', type=float, default=0)
    parser.add_argument('--suggest', action='store_true', help='repack whole classes while keeping known failure classes earliest in current lexical order')
    parser.add_argument('--without-skip-sample', action='store_true', help='revert the 15 sampled offline skips to unknown fallback')
    args = parser.parse_args()
    if min(args.unknown_seconds, args.overhead_seconds, args.verification_seconds, args.extra_retry_seconds) < 0:
        parser.error('budgets must be nonnegative')
    print(json.dumps(report(fallback=args.unknown_seconds, overhead=args.overhead_seconds,
                            verification=args.verification_seconds, extra_retry=args.extra_retry_seconds,
                            suggest=args.suggest, offline=not args.without_skip_sample), indent=2))
