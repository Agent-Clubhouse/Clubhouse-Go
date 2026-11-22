#!/usr/bin/env python3
"""Plan the scheduled run: the fast complete core every day, plus one rotating slice of the extended UI inventory.

FAST (every scheduled run, every lane): the pre-merge smoke and one cheap representative journey per area, with the
hosted bundle, Release, Swift packages and iPad. EXTENDED: every other UI test method, split into ROTATION_DAYS stable
buckets by a hash of its selector (adding or removing a test never moves another), so each one runs at least once
every ROTATION_DAYS days. A `ci:full` label or a manual run still takes every UI test at once (ui_shards.py).

Input: `ui-shards=<json>` on stdin (the everything matrix; unused but keeps the planners' contract).
Output for $GITHUB_OUTPUT: `ui-shards`, `ui`, `ipad`, `release`, `unit`.
Usage: ui_tiers.py [--day N] [--manifest path] [--summary]
"""
import datetime
import json
from pathlib import Path
import sys
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui_scope  # noqa: E402

ROTATION_DAYS = 7


def fast():
    reps = {rep for _, (_, _, _, rep) in ui_scope.JOURNEYS.items() if rep}
    return sorted(set(ui_scope.SMOKE) | reps)


def bucket(selector):
    return zlib.crc32(selector.encode()) % ROTATION_DAYS


def extended(inventory):
    core = set(fast())
    return sorted(f"{cls}/{method}" for cls, methods in inventory.methods.items() for method in methods
                  if f"{cls}/{method}" not in core)


def plan(inventory, day):
    """Today's selectors: the fast core plus extended bucket `day % ROTATION_DAYS`."""
    today = [s for s in extended(inventory) if bucket(s) == day % ROTATION_DAYS]
    return fast() + today


def today():
    return (datetime.datetime.now(datetime.timezone.utc).date() - datetime.date(1970, 1, 1)).days


def main(argv, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, root=ui_scope.ROOT):
    value = lambda name: argv[argv.index(name) + 1] if name in argv else None
    day = int(value("--day")) if value("--day") is not None else today()
    manifest = value("--manifest")
    line = stdin.read().strip()
    if not line.startswith("ui-shards="):
        raise SystemExit("Expected a ui-shards= line on stdin")
    inventory = ui_scope.Inventory(root)
    missing = [s for s in fast() if not inventory.exists(s)]
    if missing:
        raise SystemExit(f"ui_tiers.py names UI tests that don't exist: {missing}")
    selectors = plan(inventory, day)
    matrix = ui_scope.pack(selectors, True, inventory)
    slices = [sum(inventory.minutes(s) for s in extended(inventory) if bucket(s) == b) for b in range(ROTATION_DAYS)]
    print(f"Scheduled run, day {day} (bucket {day % ROTATION_DAYS} of {ROTATION_DAYS}): fast core {len(fast())} methods "
          f"~{sum(inventory.minutes(s) for s in fast()):.1f} test-min, extended slice {len(selectors) - len(fast())} methods "
          f"~{slices[day % ROTATION_DAYS]:.1f} test-min, {len(matrix['include'])} shard(s); "
          f"slices {', '.join(f'{m:.0f}' for m in slices)}", file=stderr)
    if manifest:
        Path(manifest).write_text(json.dumps({"day": day, "bucket": day % ROTATION_DAYS, "selectors": selectors,
                                              "matrix": matrix}, indent=1))
    print(f"ui-shards={json.dumps({'include': [{k: v for k, v in e.items() if k != 'minutes'} for e in matrix['include']]}, separators=(',', ':'))}", file=stdout)
    for key in ("ui", "ipad", "release", "unit"):
        print(f"{key}=true", file=stdout)


if __name__ == "__main__":
    main(sys.argv[1:])
