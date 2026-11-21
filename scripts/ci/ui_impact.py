#!/usr/bin/env python3
"""Narrow the macOS lanes only where a change's owner is explicit and verified; run everything otherwise.

Input: the `ui-shards=<json>` line from ui_shards.py on stdin, and a file of `git diff --name-status -M` lines (or bare
paths) for the change. Output for $GITHUB_OUTPUT: `ui-shards=<json>`, `ui`, `ipad`, `release` and `unit` (true/false).
A summary goes to stderr; --manifest PATH writes the full decision.

Narrowing is allowed only for:
- paths that never build into the app (changes.py DOCS and SWIFT lanes): no macOS app lanes from them;
- a UI test file that declares exactly one test class and nothing else, owned by exactly one whole-class entry of the
  current shard matrix (or by the catch-all). The app is unchanged, so only that class can change. If the iPad job runs
  that class, the iPad lane runs too;
- a hosted unit test file: the ClubhouseGoTests bundle, in the unit shard and in the iPad job, which runs it too.
Everything else runs every lane and class, including any product, project, workflow or script change; a shared or mixed
UI file; a deleted or renamed test file; and a class the matrix doesn't own exactly once or selects by method.
"""
import importlib.util
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


def parse_changes(text):
    """[(status, path, previous)] from `git diff --name-status -M` letters, or bare paths."""
    entries = []
    for line in text.splitlines():
        parts = [part for part in line.rstrip("\n").split("\t") if part]
        if not parts:
            continue
        if len(parts) == 1:
            entries.append(("modified", parts[0], None))
            continue
        status = parts[0].upper()
        if status.startswith("R") or status.startswith("C"):
            entries.append(("renamed" if status.startswith("R") else "copied", parts[2], parts[1]))
        elif status == "D":
            entries.append(("removed", parts[1], None))
        elif status == "A":
            entries.append(("added", parts[1], None))
        else:
            entries.append(("modified", parts[1], None))
    return entries


def ui_test_class(root, path):
    """The one test class a UI file declares, or None if it is shared, mixed, empty or gone."""
    source = root / path
    if not source.is_file():
        return None
    text = source.read_text(errors="replace")
    classes = TEST_CLASS.findall(text)
    if len(classes) != 1 or len(TOP_LEVEL_TYPE.findall(text)) != 1 or not re.search(r"\bfunc\s+test\w+\s*\(\s*\)", text):
        return None
    return classes[0]


def ipad_ui_classes(root):
    """UI classes the iPad job selects, read from the workflow so the two can't drift."""
    workflow = (root / ".github/workflows/ci.yml").read_text()
    start = workflow.find("\n  ipad-tests:")
    end = workflow.find("\n  ci-result:", start)
    block = workflow[start:end] if start >= 0 else ""
    return set(re.findall(rf"-only-testing:{UI_TARGET}/(\w+)", block))


def owners(matrix):
    """({class: entry index}, catch-all index) for a whole-class partition, or None if the topology is unsupported."""
    owned, catch_all, skipped = {}, None, set()
    for index, entry in enumerate(matrix["include"]):
        for flag in entry["selection"].split():
            mode, selector = flag.split(":", 1)
            target, _, rest = selector.partition("/")
            if target != UI_TARGET:
                continue
            if "/" in rest:
                return None  # a method-level selector: whole-class narrowing can't be verified
            if mode == "-only-testing" and not rest:
                if catch_all is not None:
                    return None
                catch_all = index
            elif mode == "-only-testing":
                if rest in owned:
                    return None
                owned[rest] = index
            elif mode == "-skip-testing":
                skipped.add(rest)
    if catch_all is None or skipped != set(owned):
        return None  # the catch-all must skip exactly the classes listed elsewhere
    return owned, catch_all


def decide(entries, root, changes, matrix):
    full = lambda reason: {"full": True, "reason": reason}
    topology = owners(matrix)
    classes, unit, app, ipad = set(), False, False, False
    for status, path, previous in entries:
        for candidate in [path] + ([previous] if previous else []):
            if changes.classify(candidate) != changes.APP:
                continue
            if candidate.startswith(UI_DIR):
                if status in ("removed", "renamed", "copied"):
                    return full(f"{candidate} was {status}")
                cls = ui_test_class(root, candidate)
                if cls is None:
                    return full(f"{candidate} is shared, mixed or not a single UI test class")
                if topology is None:
                    return full("the shard matrix has no verified whole-class partition")
                classes.add(cls); app = True
                ipad |= cls in ipad_ui_classes(root)
                continue
            if candidate.startswith(HOSTED_DIR) and candidate.endswith(".swift"):
                if status in ("renamed", "copied"):
                    return full(f"{candidate} was {status}")
                unit = app = ipad = True  # the unit shard and the iPad job both run ClubhouseGoTests
                continue
            return full(f"{candidate} has no verified narrow owner")
    if (classes or unit) and topology is None:
        return full("the shard matrix has no verified whole-class partition")
    return {"full": False, "ui": sorted(classes), "unit": unit, "app": app, "ipad": ipad, "release": False}


def narrow(matrix, classes, unit):
    owned, catch_all = owners(matrix)
    result = []
    for index, entry in enumerate(matrix["include"]):
        mine = {c for c in classes if owned.get(c, catch_all) == index}
        runs_unit = unit and entry.get("unit", False)
        if not mine and not runs_unit:
            continue
        flags = [f"-only-testing:{UI_TARGET}/{c}" for c in sorted(mine)] + ([f"-only-testing:{UNIT_TARGET}"] if runs_unit else [])
        result.append({"name": entry["name"] + " (selected)", "selection": " ".join(flags), "unit": runs_unit})
    planned = {c for entry in result for c in re.findall(rf"-only-testing:{UI_TARGET}/(\w+)", entry["selection"])}
    if planned != classes or (unit and not any(entry["unit"] for entry in result)):
        return None  # never drop a requested class or the hosted bundle
    return {"include": result}


def load_changes(root=ROOT):
    spec = importlib.util.spec_from_file_location("changes", root / "scripts/ci/changes.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, root=ROOT):
    manifest = argv[argv.index("--manifest") + 1] if "--manifest" in argv else None
    args = [a for i, a in enumerate(argv) if a != "--manifest" and (i == 0 or argv[i - 1] != "--manifest")]
    line = stdin.read().strip()
    if not line.startswith("ui-shards="):
        raise SystemExit("Expected a ui-shards= line on stdin")
    matrix = json.loads(line[len("ui-shards="):])
    entries = parse_changes(Path(args[0]).read_text()) if args else []
    decision = decide(entries, root, load_changes(root), matrix) if entries else {"full": True, "reason": "no changed paths"}
    narrowed = None if decision["full"] else narrow(matrix, set(decision["ui"]), decision["unit"])
    if not decision["full"] and narrowed is None:
        decision = {"full": True, "reason": "a requested class or the hosted bundle has no owner in the matrix"}
    if decision["full"]:
        outputs = {"ui-shards": matrix, "ui": True, "ipad": True, "release": True, "unit": True}
        print(f"Impact selection: every lane ({decision['reason']})", file=stderr)
    else:
        outputs = {"ui-shards": narrowed, "ui": bool(narrowed["include"]), "ipad": decision["ipad"],
                   "release": decision["release"], "unit": decision["unit"]}
        print(f"Impact selection: UI classes {', '.join(decision['ui']) or 'none'}; hosted unit {decision['unit']}; "
              f"iPad {decision['ipad']}; Release {decision['release']}; {len(narrowed['include'])} of "
              f"{len(matrix['include'])} shards", file=stderr)
    if manifest:
        Path(manifest).write_text(json.dumps({"changes": entries, "decision": decision, "outputs": outputs}, indent=1))
    shards = outputs["ui-shards"] if outputs["ui-shards"]["include"] else {"include": matrix["include"][:1]}
    print(f"ui-shards={json.dumps(shards, separators=(',', ':'))}", file=stdout)
    for key in ("ui", "ipad", "release", "unit"):
        print(f"{key}={'true' if outputs[key] else 'false'}", file=stdout)


if __name__ == "__main__":
    main(sys.argv[1:])
