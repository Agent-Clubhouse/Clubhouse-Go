#!/usr/bin/env python3
"""Choose the macOS lanes and UI classes a change needs before merge.

Input: the `ui-shards=<json>` line from ui_shards.py on stdin, and a changed-path file with one entry per line:
`<status>\\t<path>[\\t<previous path>]` (GitHub PR file statuses or `git diff --name-status -M` letters), or bare paths.
Output on stdout, for $GITHUB_OUTPUT: `ui-shards=<json>`, `ui=true|false`, `ipad=true|false`, `release=true|false`,
`unit=true|false`. A readable summary goes to stderr and, with --manifest PATH, a JSON record of every decision.

Decisions, in order. Any rule that cannot bound a change's impact runs everything:
1. Paths that never build into the app (changes.py DOCS and SWIFT lanes) add no macOS UI work.
2. UI test class files select exactly their class. The app is unchanged by them, so other classes' results can't
   change. A shared UI helper, a file with extensions or extra types, or a deleted/renamed-away file runs everything.
3. Hosted unit test files select the ClubhouseGoTests bundle only.
4. Product Swift files:
   - explicit critical scenarios (CRITICAL below: privacy, security, destructive actions, data integrity) always run,
     whatever else is selected, and can require the iPad lane;
   - otherwise the file's own accessibility identifiers and preview flags, and those of the non-hub files that
     directly use its types, select the UI classes that reference them. Hub consumers (the root, chat and preview
     containers) render everything and name no scenario, so they don't widen the selection;
   - a preview fixture edit selects only the UI tests passing the launch flags that govern every changed line
     (needs --diff with `git diff -U0`); a change to shared fixture code runs everything;
   - a hub (many direct consumers, or referenced by most classes), a file with no traceable UI, a new product file
     with no consumers yet, or a deleted/renamed product file runs everything.
   Any product change also runs the hosted unit tests and the Release build. The iPad lane runs for iPad-specific
   code and the critical scenarios that need it.
5. Anything else (project, plist, assets, CI router, scripts the build uses) runs everything.
The coalesced daily run (`changes.py --all`) still runs every lane and class.
"""
import fnmatch
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
UI_DIR = "Annex/AnnexUITests/"
HOSTED_DIR = "Annex/AnnexTests/"
PRODUCT_DIR = "Annex/Annex/"
UI_TARGET = "ClubhouseGoUITests"
UNIT_TARGET = "ClubhouseGoTests"
HUB_CONSUMERS = 20
HUB_CLASS_FRACTION = 0.3
LITERAL_SPREAD = 6
# Files the build job's deinit policy check reads; no UI or hosted test depends on them.
BUILD_ONLY = ("scripts/isolated-deinit-policy.json", "scripts/check-isolated-deinits.py", "scripts/deinit_surface.py",
              "scripts/deinit/*")
# Pure-Python CI controls run in the Linux Plan job.
PLAN_ONLY = ("scripts/ci/tests/*", "scripts/ci/*_controls.py", "scripts/ci/*_controls.sh")
# The UI suite runs the socket-free preview service, so transport changes are proven by package and hosted tests.
NO_UI = ("Annex/Annex/Transport/*",)
CRITICAL = [
    {"name": "privacy: feedback capture, diagnostics and screenshots",
     "paths": ["Annex/Annex/*Feedback*", "Annex/Annex/*Framebriar*", "Annex/Annex/*Diagnostic*", "Vendor/Framebriar/Sources/*"],
     "ui": ["FeedbackDiagnosticsWireUITests", "FeedbackTriggersUITests", "FeedbackMenuAttachmentUITests",
            "FramebriarShakeUITests", "FramebriarShakeDiagnosticsUITests"],
     "ipad": True},
    {"name": "security: permission levels, grants and approvals",
     "paths": ["Annex/Annex/*Permission*", "Annex/Annex/*Grant*", "Annex/Annex/*Approval*", "Annex/Annex/*AccessLevel*"],
     "ui": ["CompanionPermissionMenuUITests", "CompanionPermissionStatusUITests", "CompanionGrantRequestUITests",
            "QA368GrantLayoutUITests"]},
    {"name": "destructive: Dispatcher reset, recovery, sleep and stop",
     "paths": ["Annex/Annex/*DispatcherSettings*", "Annex/Annex/*Recovery*", "Annex/Annex/*Dispose*", "Annex/Annex/*Sleep*"],
     "ui": ["CompanionDispatcherUITests", "CompanionRecoveryIntegrationUITests"]},
    {"name": "data integrity: drafts, Unicode and paste",
     "paths": ["Annex/Annex/*Composer*", "Annex/Annex/*Draft*", "Annex/Annex/*Unicode*", "Annex/Annex/*Paste*"],
     "ui": ["CompanionUnicodeFocusUITests", "CompanionCompactComposerUITests", "CompanionComposerPasteUITests"]},
]
# Preview fixtures: most edits add code under a launch flag only tests passing that flag can reach.
FIXTURES = ("Annex/Annex/Companion/Adapters/CompanionPreviewService.swift", "Annex/Annex/Companion/Views/CompanionPreviewRoot.swift")
FLAG = re.compile(r'"(--companion-[a-z0-9-]+)"')
IPAD_MARKERS = re.compile(r"horizontalSizeClass|userInterfaceIdiom|NavigationSplitView|\.pad\b")
TEST_CLASS = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*(?:ReliableUITestCase|XCTestCase)\b", re.M)
TOP_LEVEL_TYPE = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*"
                            r"(class|struct|enum|actor|protocol|extension)\s+\w+", re.M)
LITERAL = re.compile(r'"((?:--)?[a-z][a-z0-9]*(?:[-_.:][a-z0-9]+)+)')
DECLARED = re.compile(r"\b(?:class|struct|enum|protocol|actor)\s+([A-Z]\w+)")
TYPE_WORD = re.compile(r"\b[A-Z]\w+\b")


def parse_hunks(diff_text):
    """{path: [head line numbers]} from `git diff -U0`; a pure deletion marks the head lines around it."""
    hunks, path = {}, None
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
            if path is not None:
                hunks.setdefault(path, [])
        elif line.startswith("@@") and path is not None:
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
            start, count = int(m.group(1)), int(m.group(2) or "1")
            hunks[path].extend(range(start, start + count) if count else [max(1, start), start + 1])
    return hunks


def fixture_flags(text, lines):
    """The launch flags governing every changed line of a preview fixture, or None if any line is shared code."""
    rows = text.splitlines()
    properties = {}
    for match in re.finditer(r"(?:var|let)\s+(\w+)\b[^\n]*\{?[^\n]*\n?[^\n]*?(\"--companion-[a-z0-9-]+\")", text):
        segment = text[match.start():match.end()]
        if segment.count("\n") <= 1:
            properties[match.group(1)] = {match.group(2).strip('"')}

    def flags_in(row):
        found = set(FLAG.findall(row))
        for name, flags in properties.items():
            if re.search(rf"\b{name}\b", row) and not re.match(rf"\s*(?:static\s+|private\s+)*(?:var|let)\s+{name}\b", row):
                found |= flags
        return found

    indent = lambda row: len(row) - len(row.lstrip())
    governing = set()
    for number in lines:
        if not 1 <= number <= len(rows):
            continue
        index = number - 1
        row = rows[index]
        if not row.strip():
            continue
        found = flags_in(row) if row.strip() not in ("}",) else set()
        level = indent(row) if row.strip() not in ("}",) else indent(row) + 1
        cursor = index - 1
        while not found and cursor >= 0:
            above = rows[cursor]
            if above.strip() and indent(above) < level:
                found = flags_in(above)
                level = indent(above)
                if level == 0:
                    break
            cursor -= 1
        if not found:
            return None
        governing |= found
    return governing


def matches(path, patterns):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def parse_changes(text):
    """[(status, path, previous)] from GitHub statuses, git --name-status letters, or bare paths."""
    entries = []
    for line in text.splitlines():
        parts = [part for part in line.rstrip("\n").split("\t") if part]
        if not parts:
            continue
        if len(parts) == 1:
            entries.append(("modified", parts[0], None))
            continue
        status = parts[0].lower()
        if status in ("d", "removed", "deleted"):
            entries.append(("removed", parts[1], None))
        elif status.startswith("r"):  # git R100 old new, or GitHub renamed new old
            new, old = (parts[2], parts[1]) if status[1:].isdigit() or status == "r" else (parts[1], parts[2] if len(parts) > 2 else None)
            entries.append(("renamed", new, old))
        elif status in ("a", "added"):
            entries.append(("added", parts[1], None))
        else:
            entries.append(("modified", parts[1], parts[2] if len(parts) > 2 else None))
    return entries


class Index:
    """What the checked-out tree says about product files and UI test classes."""

    def __init__(self, root=ROOT):
        self.root = root
        self.product = {str(p.relative_to(root)): p.read_text(errors="replace") for p in (root / PRODUCT_DIR).rglob("*.swift")}
        self.ui = {}
        for path in sorted((root / UI_DIR).glob("*.swift")):
            text = path.read_text(errors="replace")
            classes = TEST_CLASS.findall(text)
            if classes and re.search(r"\bfunc\s+test\w+\s*\(\s*\)", text):
                self.ui[str(path.relative_to(root))] = (classes[0], set(LITERAL.findall(text)))
        self.classes = sorted({cls for cls, _ in self.ui.values()})
        owners = {}
        for path, text in self.product.items():
            for name in DECLARED.findall(text):
                owners.setdefault(name, set()).add(path)
        self.consumers = {path: set() for path in self.product}
        for path, text in self.product.items():
            for word in set(TYPE_WORD.findall(text)):
                for owner in owners.get(word, ()):
                    if owner != path:
                        self.consumers[owner].add(path)
        literals = {path: set(LITERAL.findall(text)) for path, text in self.product.items()}
        spread = {}
        for found in literals.values():
            for literal in found:
                spread[literal] = spread.get(literal, 0) + 1
        self.covers = {}
        for path, found in literals.items():
            distinctive = [literal for literal in found if spread[literal] <= LITERAL_SPREAD]
            self.covers[path] = {cls for cls, test_literals in self.ui.values()
                                 if any(lit in test_literals or any(t.startswith(lit) for t in test_literals) for lit in distinctive)}

    def is_hub(self, path):
        """Used by many product files, or referenced by many UI classes: a container, not one scenario."""
        return (len(self.consumers.get(path, ())) >= HUB_CONSUMERS
                or len(self.covers.get(path, ())) > HUB_CLASS_FRACTION * len(self.classes))

    def ui_class(self, path):
        """The single test class a UI file declares, or None if it is shared, mixed or gone."""
        entry = self.ui.get(path)
        if entry is None:
            return None
        text = (self.root / path).read_text(errors="replace")
        return entry[0] if len(TOP_LEVEL_TYPE.findall(text)) == 1 else None


def decide(entries, index, changes, hunks=None, head_texts=None):
    full = lambda reason: {"full": True, "reason": reason}
    chosen, critical, notes = set(), set(), []
    app = unit = ipad = release = False
    for status, path, previous in entries:
        for candidate in [path] + ([previous] if previous else []):
            lane = changes.classify(candidate)
            if lane != changes.APP:
                continue
            if matches(candidate, BUILD_ONLY):
                app = True
                continue
            if matches(candidate, PLAN_ONLY):
                continue
            if candidate.startswith(UI_DIR):
                cls = index.ui_class(candidate) if status != "removed" and candidate == path else None
                if cls is None:
                    return full(f"{candidate} is a shared UI test file, or was deleted or renamed")
                chosen.add(cls); app = True
                continue
            if candidate.startswith(HOSTED_DIR):
                if status == "removed" or candidate != path:
                    unit = app = True  # a removed hosted test can't affect what remains; the bundle still runs
                    continue
                unit = app = True
                continue
            if candidate.startswith(PRODUCT_DIR) and candidate.endswith(".swift"):
                app = unit = release = True
                rules = [rule for rule in CRITICAL if matches(candidate, rule["paths"])]
                for rule in rules:
                    critical.update(rule["ui"]); ipad |= rule.get("ipad", False)
                    notes.append(f"{candidate}: {rule['name']}")
                if status == "removed" or candidate != path:
                    return full(f"{candidate} was deleted or renamed; its former consumers can't be traced")
                if matches(candidate, NO_UI):
                    notes.append(f"{candidate}: transport, proven by package and hosted tests")
                    continue
                text = index.product.get(candidate, "")
                if candidate in FIXTURES and (hunks is None or candidate not in hunks):
                    return full(f"{candidate} is a shared preview fixture and no line diff bounds the change")
                if candidate in FIXTURES:
                    flags = fixture_flags((head_texts or {}).get(candidate, text), hunks[candidate])
                    if flags is None:
                        return full(f"{candidate} changes shared preview fixture code")
                    flagged = {cls for path, (cls, _) in index.ui.items()
                               if any(f'"{flag}"' in (index.root / path).read_text(errors="replace") for flag in flags)}
                    notes.append(f"{candidate}: preview flags {sorted(flags)} -> {sorted(flagged) or 'no UI test'}")
                    chosen |= flagged
                    continue
                ipad |= bool(IPAD_MARKERS.search(text))
                consumers = index.consumers.get(candidate, set())
                if len(consumers) >= HUB_CONSUMERS:
                    return full(f"{candidate} is used by {len(consumers)} product files")
                reach = set(index.covers.get(candidate, set()))
                for consumer in consumers:
                    ipad |= bool(IPAD_MARKERS.search(index.product.get(consumer, "")))
                    if not index.is_hub(consumer):
                        reach |= index.covers.get(consumer, set())  # a container (root, chat, preview) names no scenario
                if len(reach) > HUB_CLASS_FRACTION * len(index.classes):
                    return full(f"{candidate} reaches {len(reach)} of {len(index.classes)} UI classes")
                if not reach and not rules:
                    return full(f"{candidate} has no traceable UI test coverage")
                chosen |= reach
                continue
            return full(f"{candidate} needs every lane")
    return {"full": False, "ui": sorted(chosen | critical), "critical": sorted(critical), "app": app, "unit": unit,
            "ipad": ipad, "release": release, "notes": notes}


def shard_classes(entry):
    only, skipped, catch_all = set(), set(), False
    for flag in entry["selection"].split():
        mode, selector = flag.split(":", 1)
        target, _, cls = selector.partition("/")
        if target != UI_TARGET:
            continue
        if mode == "-only-testing":
            catch_all |= not cls
            if cls:
                only.add(cls)
        else:
            skipped.add(cls)
    return ("catch-all", skipped) if catch_all else ("listed", only)


def narrow(matrix, classes, unit):
    listed = set()
    for entry in matrix["include"]:
        kind, value = shard_classes(entry)
        if kind == "listed":
            listed |= value
    result = []
    for entry in matrix["include"]:
        kind, value = shard_classes(entry)
        mine = (classes & value) if kind == "listed" else {c for c in classes if c not in listed and c not in value}
        runs_unit = unit and entry.get("unit", False)
        if not mine and not runs_unit:
            continue
        flags = [f"-only-testing:{UI_TARGET}/{c}" for c in sorted(mine)] + ([f"-only-testing:{UNIT_TARGET}"] if runs_unit else [])
        result.append({"name": entry["name"] + " (selected)", "selection": " ".join(flags), "unit": runs_unit})
    return {"include": result}


def load_changes(root=ROOT):
    spec = importlib.util.spec_from_file_location("changes", root / "scripts/ci/changes.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, root=ROOT):
    manifest = argv[argv.index("--manifest") + 1] if "--manifest" in argv else None
    diff = argv[argv.index("--diff") + 1] if "--diff" in argv else None
    options = {"--manifest", "--diff"}
    args = [a for i, a in enumerate(argv) if a not in options and (i == 0 or argv[i - 1] not in options)]
    hunks = parse_hunks(Path(diff).read_text(errors="replace")) if diff else None
    line = stdin.read().strip()
    if not line.startswith("ui-shards="):
        raise SystemExit("Expected a ui-shards= line on stdin")
    matrix = json.loads(line[len("ui-shards="):])
    entries = parse_changes(Path(args[0]).read_text()) if args else []
    decision = decide(entries, Index(root), load_changes(root), hunks) if entries else {"full": True, "reason": "no changed paths"}
    if decision["full"]:
        outputs = {"ui-shards": matrix, "ui": True, "ipad": True, "release": True, "unit": True}
        print(f"Impact selection: every lane ({decision['reason']})", file=stderr)
    else:
        narrowed = narrow(matrix, set(decision["ui"]), decision["unit"])
        outputs = {"ui-shards": narrowed, "ui": bool(narrowed["include"]), "ipad": decision["ipad"],
                   "release": decision["release"], "unit": decision["unit"]}
        print(f"Impact selection: {len(decision['ui'])} UI classes ({', '.join(decision['ui']) or 'none'}); "
              f"critical {decision['critical'] or 'none'}; hosted unit {decision['unit']}; iPad {decision['ipad']}; "
              f"Release {decision['release']}; {len(narrowed['include'])} of {len(matrix['include'])} shards", file=stderr)
        for note in decision["notes"]:
            print(f"  {note}", file=stderr)
    if manifest:
        Path(manifest).write_text(json.dumps({"changes": entries, "decision": decision, "outputs": outputs}, indent=1, default=list))
    shards = outputs["ui-shards"]
    if not shards["include"]:
        shards = {"include": matrix["include"][:1]}  # a valid placeholder; ui=false skips the job
    print(f"ui-shards={json.dumps(shards, separators=(',', ':'))}", file=stdout)
    for key in ("ui", "ipad", "release", "unit"):
        print(f"{key}={'true' if outputs[key] else 'false'}", file=stdout)


if __name__ == "__main__":
    main(sys.argv[1:])
