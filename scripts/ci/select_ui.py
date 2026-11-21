#!/usr/bin/env python3
"""Narrow the UI shard matrix for a pull request that changes only test files.

Reads the `ui-shards=<json>` line from ui_shards.py on stdin, and the PR's changed paths from the file argument.
Prints the same `ui-shards=<json>` line, narrowed only when the narrowing cannot miss a regression:

- If every changed path that builds into the app is a UI test class file, only those classes run, each in the
  shard that already runs it. The app and the other tests are byte-for-byte unchanged, so their results can't change.
- If only hosted unit test files (Annex/AnnexTests) changed, only the ClubhouseGoTests bundle runs.
- Anything else runs the full matrix: a product, project, workflow or script change; a shared UI test helper; a test
  file that also declares extensions or other types; a deleted or renamed test file.

Paths that never build into the app (docs, SwiftPM-only tests; see changes.py) are ignored here. A summary is
written to stderr. Usage: ui_shards.py | select_ui.py changed-files.txt
"""
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
UI_DIR = "Annex/AnnexUITests/"
HOSTED_DIR = "Annex/AnnexTests/"
UI_TARGET = "ClubhouseGoUITests"
UNIT_TARGET = "ClubhouseGoTests"
TEST_CLASS = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(?:ReliableUITestCase|XCTestCase)\b", re.M)
TOP_LEVEL_TYPE = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*"
                            r"(class|struct|enum|actor|protocol|extension)\s+\w+", re.M)


def builds_into_app(path, changes):
    return changes.classify(path) == changes.APP


def ui_test_class(path, root=ROOT):
    """The one test class a UI file declares, or None when the file is shared or declares anything else."""
    source = root / path
    if not source.is_file() or not path.endswith(".swift"):
        return None  # deleted, renamed away or not Swift: other tests may have used it
    text = source.read_text()
    classes = TEST_CLASS.findall(text)
    if len(classes) != 1 or not re.search(r"\bfunc\s+test\w+\s*\(\s*\)", text):
        return None
    if len(TOP_LEVEL_TYPE.findall(text)) != 1:
        return None  # extensions or helper types can be used by other classes
    return classes[0]


def plan(paths, changes, root=ROOT):
    """('full', reason) or ('narrow', ui_classes, unit_needed)."""
    app_paths = [path for path in paths if builds_into_app(path, changes)]
    if not app_paths:
        return ("full", "no app paths changed")
    classes, unit = set(), False
    for path in app_paths:
        if path.startswith(UI_DIR):
            cls = ui_test_class(path, root)
            if cls is None:
                return ("full", f"{path} is shared, not a single UI test class, or no longer exists")
            classes.add(cls)
        elif path.startswith(HOSTED_DIR):
            if not (root / path).is_file():
                return ("full", f"{path} was deleted or renamed")
            unit = True
        else:
            return ("full", f"{path} builds into the app")
    return ("narrow", classes, unit)


def shard_classes(entry, every_listed):
    """UI classes an entry runs; the catch-all runs those no other entry lists."""
    only, skipped, catch_all = set(), set(), False
    for flag in entry["selection"].split():
        mode, selector = flag.split(":", 1)
        target, _, cls = selector.partition("/")
        if target != UI_TARGET:
            continue
        if mode == "-only-testing":
            if cls:
                only.add(cls)
            else:
                catch_all = True
        elif mode == "-skip-testing":
            skipped.add(cls)
    return ("catch-all", skipped) if catch_all else ("listed", only)


def narrow(matrix, classes, unit):
    entries = matrix["include"]
    listed = set()
    for entry in entries:
        kind, value = shard_classes(entry, None)
        if kind == "listed":
            listed |= value
    result = []
    for entry in entries:
        kind, value = shard_classes(entry, None)
        mine = (classes & value) if kind == "listed" else {cls for cls in classes if cls not in listed and cls not in value}
        runs_unit = unit and entry.get("unit", False)
        if not mine and not runs_unit:
            continue
        flags = [f"-only-testing:{UI_TARGET}/{cls}" for cls in sorted(mine)]
        if runs_unit:
            flags.append(f"-only-testing:{UNIT_TARGET}")
        result.append({"name": entry["name"] + " (selected)", "selection": " ".join(flags), "unit": runs_unit})
    return {"include": result}


def main(argv, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, root=ROOT):
    import importlib.util
    spec = importlib.util.spec_from_file_location("changes", root / "scripts/ci/changes.py")
    changes = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(changes)

    line = stdin.read().strip()
    prefix = "ui-shards="
    if not line.startswith(prefix):
        raise SystemExit("Expected a ui-shards= line on stdin")
    matrix = json.loads(line[len(prefix):])
    paths = [p.strip() for p in Path(argv[0]).read_text().splitlines() if p.strip()] if argv else []
    decision = plan(paths, changes, root) if paths else ("full", "no changed-file list")
    if decision[0] == "narrow":
        narrowed = narrow(matrix, decision[1], decision[2])
        if narrowed["include"]:
            names = ", ".join(sorted(decision[1])) or "none"
            print(f"UI selection: test-only change; UI classes {names}; hosted unit tests "
                  f"{'yes' if decision[2] else 'no'}; {len(narrowed['include'])} of {len(matrix['include'])} shards",
                  file=stderr)
            matrix = narrowed
        else:
            print("UI selection: full matrix (nothing selected)", file=stderr)
    else:
        print(f"UI selection: full matrix ({decision[1]})", file=stderr)
    print(f"{prefix}{json.dumps(matrix, separators=(',', ':'))}", file=stdout)


if __name__ == "__main__":
    main(sys.argv[1:])
