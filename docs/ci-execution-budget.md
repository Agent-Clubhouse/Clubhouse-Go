# CI execution budget and early failure signal

This change redistributes the same eight iPhone jobs and streams the first failed
attempt of each item while the tests are running. It adds no runner capacity,
removes no test, and changes no retry, timeout, fixture, settings, credentials,
Release, package, live-contract or iPad requirement. The <60-minute all-checks
execution critical path and <10-minute actionable failure feedback targets remain
**unproven until the exact full hosted run completes**. Queue and pre-Plan latency
are separate measurements. A failed item late in a suite cannot be reported before
it executes; annotations do not promise every workflow failure within ten minutes.

## Evidence and placement

Baseline main is `b1ff00b4ea3ca612b47925c47b4e402646b91b8e` (#627/#628 merged).
The source under both Annex test directories is byte-identical to full run
[44937056133](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/44937056133),
head `4cd77e4d34fa17350f0c608248e02f12e4c336ef`. Plan 7s, Build 264s,
Release 477s, packages 299s, iPad 1223s and result 4s came from job timestamps.
The catch-all had 33 classes and reached only five before cancellation; its 3411s
job gives `7 + 264 + 3411 + 4 = 3686s` (61m26) **through cancellation**, not a
complete full-suite result. The other job failures/retries are retained failures,
not a speed success. The eight raw log lengths/digests and measured terminal
attempt totals are in `scripts/ci/ui_execution_observations.json`.

The ordinary offline Live E2E guard is sampled separately in jobs 132398496998,
132587983438 and 132681935037 (logs in the accepted shared timing asset). All 15
current identities skipped in each: attempt totals 1.386/1.716/1.237s; whole suite
spans 1.391/1.759/1.243s. All used Xcode 26.5. The fetched actual merge sources
have the identical `super.setUpWithError()` then `XCTSkipUnless` condition and
reason, and neither old nor current ReliableUITestCase overrides setup/teardown.
The emitted skip reason proves the live fixture predicate was false; ordinary CI
supplies neither live fixture variable. Other bodies/helper paths differ and are
unreached by this guard. The model uses the maximum sampled time for each method
plus the maximum suite overhead apportioned per case: 1.870005s total, rather than
assuming zero or converting another unknown to a skip. This supplies no live
execution coverage and changes no live-contract workflow. Pins, source hashes and
per-method samples are in `scripts/ci/offline_skip_observations.json`.

`python3 scripts/ci/ci_execution_budget.py --suggest` reproduces longest-first
whole-class placement. Latest same-source full-run all-attempt totals take
precedence over the accepted historical timing table; **all remaining 114
unknown methods retain 60s each**, including other unmeasured guarded tests.
Failed attempts are already included in observed totals. The default per-job
setup/runner/verification/upload allowance is 430s: seven non-hosted baseline
residuals range 346.502..651.657s, median 405.675s, so this is a model, not an
upper bound. The hosted lane additionally budgets 713s: measured ~620s hosted
span plus ~93s for the second runner startup. The iPad stays 1223s separately.

| Retained job name | Classes | UI methods | Unknown methods | Modeled execution seconds |
| --- | ---: | ---: | ---: | ---: |
| UI tests (preview, project pages) | 8 | 47 | 10 | 3451.383 |
| UI tests (feedback, needs you) | 9 | 53 | 0 | 3447.694 |
| UI tests (dispatcher, terminal) | 10 | 54 | 21 | 3449.470 |
| UI tests (unicode, home) | 11 | 49 | 18 | 3437.957 |
| UI tests (search, permissions) | 10 | 55 | 32 | 3440.709 |
| UI tests (composer, sheets) | 12 | 73 | 8 | 3432.633 |
| UI tests (reading, grants) + unit tests | 9 | 47 | 20 | 3443.884 |
| UI tests (other) | 10 | 48 | 5 | 3450.098 |

The longest modeled lane is preview/project pages: 3451.383s, including measured
Preview Smoke 1866.312s, unknown CombinedLinkedHome 300s and measured SessionModel
292.094s. Its total includes 10 unknown methods (600s); no observed skip is a
passing native behavior. Names are retained check identities, not a promise that
every assigned class still matches the historical name.

The queue-excluded DAG critical path is **3726.383s (62m06.383)**:
`Plan + max(packages, Release, Build + max(iPhone jobs, iPad)) + result`.
The modeled longest lane is also above its unchanged 55m timeout. Redistribution
cannot remove the aggregate uncertainty; missing durations justify one complete
exact-head measurement after independent delta review, not a claim of completion.
The average modeled iPhone workload is **3444.228s per lane**, an aggregate
lower bound independent of placement, versus the unchanged 3300s job limit.
Total modeled excess over eight 55m slots is **1153.828s**.
The largest indivisible UI class is PreviewSmoke at 1866.312s (31m06), which fits
within a lane; splitting it would not solve this aggregate lower bound. No method
split is introduced without evidence that placement rather than unknown costs is
the limiting factor.

No shared setup conversion was introduced: build products are already reused and
both hosted device invocations remain necessary native proof.

A plausible work-conserving **five-macOS-slot makespan** is a different quantity:
119m36.481s for matrix order then iPad, or 119m52.103s for iPad then longest job.
The simulator starts build/packages/Release together, then admits ready UI/iPad
jobs when a slot is free. It is not GitHub scheduling evidence or a queue bound;
external queue/pre-Plan delays can extend it further. No sixth slot is assumed.

Sensitivity on this fixed placement (do not subtract costs from the old maximum):

| Assumption | Modeled queue-excluded CP |
| --- | ---: |
| Remaining unknown methods 60s | 3726.383s |
| Remaining unknown methods 90s | 4675.709s |
| One additional 240s retry in each iPhone lane | 3966.383s |
| No comparable offline skip sample; all 15 revert to 60s | 4605.763s |

Use `--unknown-seconds`, `--extra-retry-seconds`, `--overhead-seconds` and
`--without-skip-sample` to reproduce these sensitivities. Rebalancing under a new
assumption is explicit (`--suggest`); it does not mutate CI or waive inventory.

## Inventory and first failure semantics

Source checks partition all 79 current UI classes / 426 zero-argument methods
once over the eight iPhone jobs, retain the future-class catch-all, and verify
exactly three intentional iPad UI repeats. The entire hosted bundle remains
selected once on iPhone and once on iPad; its strict no-retry policy is unchanged.
Actual SDK discovery/parameterized hosted cases and complete runtime coverage
remain exact-run evidence, not a Python simulation claim.

The catch-all now verifies every selected source UI method, respecting explicit
exclusions and only existing documented skip guards. Both iPhone and iPad run
inventory verification even if complete-result verification fails. No partial or
missing xcresult is accepted. The iPad selection has one source for invocation
and inventory. No method bodies or native source changed.

`report_test_failures.py` forwards stdout unchanged and emits an escaped GitHub
warning at the first XCTest assertion or Swift Testing issue for an item, with a
terminal-failure fallback when no assertion is available. The method and original
assertion remain intact. Properties and messages escape `%`, CR/LF (and property
colon/comma); untrusted diagnostics cannot inject another annotation. JSONL
captures monotonic stream/item latency, known attempt and observation UTC; absent
item starts have **null**, not invented timing. Passing retries never erase the
first failure. This is advisory and never decides the final test result.

Explicit Bash `pipefail` retains package failures. Native pipelines record all
three exit statuses. The existing xcodebuild-65 exception still requires a complete
passing result and inventory; tee/reporter failure cannot turn green. Complete
xcresult, strict hosted/iPad no-retry and required aggregate checks remain the
verdict authorities. Raw tee logs, events and statuses remain in result artifacts.

Controls replay a sanitized actual first assertion/failure/retry-pass sequence
(run/job/full-log SHA beside the fixture), a delayed item start, Swift Testing
issues without a start, hostile diagnostic text, upstream nonzero status and both
actual workflow verifier tails against fake tools. These are Python/shell controls,
not native or SDK execution. Preserve first-annotation vs post-xcresult timestamps,
actual inventory/skips/attempts, job execution, queue/pre-Plan, artifact closure
and all retained checks in the single full hosted validation report.
