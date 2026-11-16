#!/usr/bin/env python3
"""Require pass records for the macOS-15+ icon-hold tests on CI's macOS-26 host."""
import re
import sys
from pathlib import Path

REQUIRED = {
    "queuedCompleteIconMapDistinguishesOmissionFromRemoval": " with 4 test cases",
    "progressFloodBypassesBlockedIconsAndQueuedSnapshotsCannotRegressIt": "",
    "qaNewEpochCannotPublishThePreviousEpochsApprovalWhileSnapshotWaitsForIcons": "",
}


def missing_passes(log):
    log = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", log)
    return [name for name, cases in REQUIRED.items()
            if not re.search(rf"^✔ Test {re.escape(name)}\([^\n)]*\){cases} passed after [0-9.]+ seconds\.$", log, re.MULTILINE)]


def main(argv):
    missing = missing_passes(Path(argv[0]).read_text())
    for name in missing:
        print(f"::error::Required icon-hold test did not pass (missing or skipped): {name}")
    if not missing:
        print("All three icon-hold methods executed and passed (six cases).")
    return bool(missing)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
