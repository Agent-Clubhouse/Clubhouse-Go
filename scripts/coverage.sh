#!/usr/bin/env bash
# Line coverage for the Swift package targets (ClubhouseTransport and CompanionDomain).
#
#   scripts/coverage.sh                    # swift test with coverage, then print the summary
#   scripts/coverage.sh --skip-tests       # reuse the last `swift test --enable-code-coverage` run
#   scripts/coverage.sh --check            # also fail if a target drops below coverage-baseline.json
#   scripts/coverage.sh --update-baseline  # raise the baseline to the current numbers (a deliberate commit)
#
# Reports land in .build/coverage/: report.txt (per file), coverage.json (llvm-cov export summary).
# The ratchet compares per-target line coverage to coverage-baseline.json, less its tolerance,
# so coverage may rise freely but only drops when someone lowers the baseline on purpose.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

RUN_TESTS=1
CHECK=0
UPDATE=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) RUN_TESTS=0 ;;
    --check) CHECK=1 ;;
    --update-baseline) UPDATE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$RUN_TESTS" = 1 ]; then
  swift test --enable-code-coverage
fi

BIN_PATH=$(swift build --show-bin-path)
PROFDATA="$BIN_PATH/codecov/default.profdata"
BINARY="$BIN_PATH/ClubhouseTransportPackageTests.xctest/Contents/MacOS/ClubhouseTransportPackageTests"
[ -f "$BINARY" ] || BINARY="$BIN_PATH/ClubhouseTransportPackageTests.xctest"
if [ ! -f "$PROFDATA" ]; then
  echo "No coverage data at $PROFDATA; run without --skip-tests." >&2
  exit 1
fi

OUT=.build/coverage
mkdir -p "$OUT"
xcrun llvm-cov export "$BINARY" -instr-profile="$PROFDATA" -summary-only \
  -ignore-filename-regex='(\.build|Tests|Vendor)/' > "$OUT/coverage.json"

python3 - "$OUT" "$CHECK" "$UPDATE" <<'PY'
import json, math, os, sys

out, check, update = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
# Source roots of each package target (see Package.swift).
TARGETS = {
    "ClubhouseTransport": "Annex/Annex/Transport/",
    "CompanionDomain": "Annex/Annex/Companion/",
}
BASELINE = "coverage-baseline.json"

files = json.load(open(os.path.join(out, "coverage.json")))["data"][0]["files"]
totals = {name: [0, 0] for name in TARGETS}
rows = []
for f in sorted(files, key=lambda f: f["filename"]):
    for name, root in TARGETS.items():
        if root in f["filename"]:
            lines = f["summary"]["lines"]
            totals[name][0] += lines["covered"]
            totals[name][1] += lines["count"]
            rel = f["filename"].split("Annex/Annex/", 1)[1]
            rows.append(f"{lines['percent']:6.1f}%  {lines['count'] - lines['covered']:5d} / {lines['count']:5d} missed  {rel}")

pct = {name: (100.0 * c / n if n else 100.0) for name, (c, n) in totals.items()}
summary = ["Line coverage by target:"] + [
    f"  {name:20s} {pct[name]:6.2f}%  ({c}/{n} lines)" for name, (c, n) in totals.items()
]
with open(os.path.join(out, "report.txt"), "w") as report:
    report.write("\n".join(summary + ["", "Per file:"] + rows) + "\n")
print("\n".join(summary))
print(f"Per-file report: {out}/report.txt")

if update:
    # Floor to a tenth so the committed number is one the current tree always meets.
    current = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {"tolerance": 0.5, "targets": {}}
    current["targets"] = {name: math.floor(pct[name] * 10) / 10 for name in TARGETS}
    with open(BASELINE, "w") as fh:
        json.dump(current, fh, indent=2)
        fh.write("\n")
    print(f"Updated {BASELINE}.")

if check:
    baseline = json.load(open(BASELINE))
    tolerance = baseline.get("tolerance", 0.0)
    failed = False
    for name, minimum in baseline["targets"].items():
        if pct.get(name, 0.0) + tolerance < minimum:
            print(f"::error::{name} line coverage {pct.get(name, 0.0):.2f}% is below the baseline {minimum}% (tolerance {tolerance}).")
            failed = True
        elif pct[name] >= minimum + 1:
            print(f"{name} is {pct[name] - minimum:.1f} points above its baseline; consider scripts/coverage.sh --update-baseline.")
    sys.exit(1 if failed else 0)
PY
