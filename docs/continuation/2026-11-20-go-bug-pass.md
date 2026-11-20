# go-bug-pass continuation, 2026-11-20

**Incomplete diagnostic work, not a cure or landing report.**

Repository: `Agent-Clubhouse/Clubhouse-Go`. Current owner: `go-bug-pass`.
The parent has identified a Mini member, but successor readiness is blocked.
Hold successor messages/wakes until parent/Tael verifies readiness. Ownership
remains here until an authorized direct message confirms both the recipient's
exact remote fetches and explicit acceptance. No worktree handoff, restart,
release, or deletion is authorized by this note.

Begin wrapping by 05:00 Pacific; hard cutoff is 06:15 Pacific / 14:15 UTC.
The 03:30 and 04:30 Pacific snapshots remain useful.

## Remotely preserved implementation

Both normal branches below were pushed and independently read back with
`git ls-remote`. Their tracked worktrees were clean. Their diffs contain only
approved test diagnostics, not private logs, screenshots, credentials, or
generated products. Neither has its own PR: these are components for the
integration owner's next normal revision, not standalone CI triggers.

| Assignment | Branch and exact remote SHA | Status |
| --- | --- | --- |
| Transport waiter diagnosis, #611 / #622 | `bold-gazelle/diagnose-transport-progress` at `c53876fb2ddf0ed5128132a659277b3389c6663b` | Reviewed instrumentation; root cause open |
| Hosted Settings / History diagnosis, #620 | `bold-gazelle/diagnose-hosted-ipad` at `f47cfeff3b54fb4fdaf9028fd72d1e03c31d9d78` | Reviewed probes; local non-reproduction only |

The continuation note has its own normal branch:
`bold-gazelle/go-bug-pass-nov20-continuation`. Its final commit SHA and remote
readback will be supplied by direct message; do not infer a transfer from the
existence of any branch.

## Evidence and remaining acceptance

Private originals and full review JSONs remain local. The local Git blob
references below are evidence identifiers, **not promises that those objects
are remotely fetchable**. An authorized private transfer is still needed if a
successor must independently inspect them. Do not upload their raw contents or
copy raw probe arrays into public notes.

### Transport

The original #622 job `136123195225`, run `44686861649`, failed
`snapshotFailureKeepsCommandsUsableDuringGraceThenRecoversThroughBackoff` with
one poll in the existing ten-second waiter. Its first failure is retained;
#611 describes the same under-sampled family. Neither issue is resolved.

The `c538` change measures predicate time, requested-sleep/resumption time,
total wait time, and post-timeout diagnostic-state time. It preserves the
ten-second deadline, one-millisecond throwing sleep, predicate, and assertions.
Timing alone does not identify an actor or a product root cause.

Independent source review: local blob
`15e4ddce47adbfe7f5345d73146af416f989d919`.
Independent focused originals review: local blob
`cae9c460e78d0b8bb2c925c1c2f6643a647e1a3c`,
SHA256 `940fe1d8a1f536fa432b9027980f1dceae79dc9fcc1ebf199f3d6d6ba18488b0`.
Three selected cases passed once; the timeout did not reproduce, so no timeout
phase counters were emitted.

The focused run used Testing Library 1085, three cases, and no coverage.
The original hosted run used Testing Library 1902, the full 1,746 tests /
208 suites, and coverage. This is not a controlled comparison. The real local
Swift Testing XML was `tests-swift-testing.xml`, not the requested `tests.xml`.

**Next:** integration owner `go-feedback-review` carries the exact diagnostic
helper into the next normal full-suite coverage revision. Preserve concurrency,
deadlines, and all assertions. Retain actual XML, complete stdout, actual command
and toolchain identities. No standalone trigger or additional focused rerun.

### Hosted Settings / History

Original #620 source:
`ab6c7149416e50ca259aa135289e5d7b668427dc`, run `44685281882`,
iPad job `136135075192`.
The Settings failure occurs during initial Name-field realization, before
editing or canonical acknowledgement. History fails after remount with
unmounted / exhausted restoration, missing geometry, and an offset reset.
The original failures remain open.

Independent `f47` source review: local blob
`0f2b1b1decd3a578d0cd8e417077e6783b4742d8`,
SHA256 `13aa1d318988517c3ef396f3a2ede1ef3de520d4ed6213fa631aca8b10458e5f`.
Fresh build originals were independently reviewed by both go-bug-pass and the
orchestrator. An old runtime reviewer allowlist rejected go-bug-pass before
entry; a genuine orchestrator review resolved that constraint without aliasing
the reviewer, editing runtime bytes, or rerunning the build.

Independent first native originals review: local blob
`d4e416b2f45144a92256ac451e3af2d210f63918`,
SHA256 `6e4838957eeaef3fb577c1e4ce139ec73ca43355e98c6d0db5d80ee156971595`.
All 124 original entries / 243,963,559 bytes, complete five compiled products,
source/config bindings, and raw SQLite records were checked. Exactly two cases
passed once: Settings 2.370937 seconds and History 1.190320 seconds. Native,
audit, export, and lifecycle statuses were zero; actual after-FIFO duration was
77.531275 seconds under the 900-second bound.

This was local iPad Air M3 / iOS 26.0, not original hosted iPad Pro M4 / iOS 26.5
with the full hosted workload. No screenshots or movies were supplied or
credited. The local trace establishes actual clearing **before** the incoming
mount and successful restoration and refresh on that run. It does not establish
a repair of the suspected late-old-view teardown race.

**Next:** parent approved carrying the exact two test-only `f47` files into the
next normal hosted full-suite run. Capture Name realization and old/new mount
ordering, including actual post-clear geometry. The unmounted callback is
pre-clear, and the 96 ordinary-sample cap may omit needed future evidence.
Missing timings/geometry means the cause stays open. Five-second waits,
one-point alignment, and existing deadlines/assertions remain unchanged.

### Native input mismatch comparison

Diagnosis only; no typing helper/product changes or tolerant comparisons.

| Original | Evidence/status |
| --- | --- |
| #620 PinnedDecision `testRequestArrivingWhileTypingAtStandardTextNeverCollapsesTheTray`, job `136135075543` | First 84.597-second failure: exact expected `Keep this draft`, actual `Keep this raft`; retry pass does not replace it. Original artifact `14612970082`, ZIP SHA256 `79b2fbc4854a1c6d29876891b47d72c83bae157a7c2ce22bd7d19355b9661b6c`. Full local artifact materialized; exact first activities and media exported. |
| Prior #616 composer `testComposerCentresOneLineAtLargeText`, head `37d5b595fef266131b71f00fed92c3a4ca59401a`, run `44624001013`, job `135954651616` | First 35.556-second failure: `He` versus exact `Hey`; later pass is separate. Original artifact `14595083360`, ZIP SHA256 `33c424a7a2b18ef583e93efaf2c03c02501ee436d3895b9df80b78d55e821889`. Full local six-entry handoff checked; unfinished original lacks Info.plist, so finalized native-export credit is unavailable. |

The PinnedDecision synthesized event is one aggregate text event containing
the entire requested string, not a per-character KEY_DOWN/KEY_UP trace.
Do not infer a lost key phase or a shared product cause from that record.
The `--only-failures` export returned no attachments. The full export retains
the original first recording at repetition 1, marked
`isAssociatedWithFailure=false`, although that first run failed and the
aggregate result was retry-green. Select actual first-run evidence by repetition
identity rather than relying on that failure-only filter.

**Next:** compare actual native events and current text state before/after
typing and before/after the late request. Inspect original first media without
renaming/reconstructing incomplete bundles. A common symptom is not a proven
duplicate cause. Keep exact draft equality.

### Dispatcher routed-burst copy/draft mismatch

Parent newly assigned initial diagnosis of #620
`testARoutedBurstShowsEachSenderAndMessageSeparately`, job `136135075405`,
run `44685281882`, source `ab6c7149`.
The first failure at line 325 takes 167.825 seconds and concerns preserving the
entire raw delivery in the draft after navigation. The next failure at line 316
is a different near-allowance failure before composer tapping; the third pass
does not cure either first failure.

Original closed-job report: local blob
`bea09927d3cf0905fcfe25a7dcf99e2d26273ae5`,
SHA256 `dd88297505e43452dcf2083f5b1ab8bd09602af14848f3249d8c58b5e7e5a9c6`.
Original artifact `14614755434`, ZIP SHA256
`998ff84f08d401eaee5e51dd6225d5a6c72780b9571e206778cde77aeeb6e870`;
local materialization/native attribution is not complete yet.

**Next:** establish actual Copy raw action, clipboard/draft state, navigation,
and first-run evidence before relating this to dropped native typing characters.
Verify whether the canceled job's original result is complete. No shared focus
fix is justified yet. `ux-root` owns sender-message reveal at line 654 in the
shared Dispatcher UI file; coordinate any shared-helper/file edits directly.
No edit has been made here.

## Independent reviews still in progress

| Scope | Exact candidate and current boundary |
| --- | --- |
| Combined iPad partition / Footer focus / Preview gesture / transport carry | SOURCE-only approved at `026688254361e5cb1ee09ee5430df6973462a179`, local review `ff8b4840abab3b37b7d763f21e0b236aa84dac0f` / SHA256 `0f2033b7f3a60ddb2b8c1c51b1add19f546bd490532706a7bed0b4ecb5aece90`. Two exact pure tests and three Swift parses passed, not native/cure acceptance. |
| Package original receipts | Final candidate `a90b24cb80ded7a501f73f7a5ae06151b49294b9`; source review still pending. Captured PIPESTATUS preserves test failure over writer failure and still rejects writer-only failure. Reviewer found that the old artifact path omitted the real Swift Testing sidecar; final child uses `swift-package-results*.xml` with a fail-before pattern test. No actual next-run XML credit yet. |
| Additive hosted probes | Candidate `3980cf4445e51d9a554eb5ab08703ecfecd639d3`; exact two-file `f47` carry/head binding still pending. Parent approved next normal hosted run, not a standalone trigger. |
| Footer / Preview prospective execution config | Frozen native candidate remains `0266882`; config manifest `c781589bd9967365173abde5eef57298b9dd24c18740c67a2573acee1dbe4eb6`, private packet `2e216c01bda620a42858af232e74ddd9fd82f137`. Config review pending; no execution authorized. Owner proposes narrowing prior-A reviewers to go-bug-pass / orchestrator, excluding its executor. Require fresh A, independent complete-five acceptance/current-byte checks, then exactly five methods / seven launches under unchanged gates. Keyboard presence alone is not native field-focus credit. |
| Linked Home source/config | SOURCE-only approved at `a343b26997e6f4b0b2e86ee2c62ac74335a072d1`, local review `239269c0e6b0bf3c3932fc59f6cc2a11809e9360` / SHA256 `463debcfb26683835081b64c4e48c5700c11462e5d179ed104d239dceeb9e6bf`. Existing fold is revealed without tapping/re-expanding; explicit Expanded/Collapsed and disabled cached-row oracles retained. Prospective config packet `6a1d01715c35d41161f873f3697470a4b344dcee` remains unreviewed/unrun. UX owns execution after its review and independent fresh A gate. |

The iPad topology preserves one peak slot and 25 minutes **per job**, but changes
the aggregate allowance from 25 to 50 standard-runner minutes. Parent explicitly
approved that normal-run budget. Forecast is 40.91 total runner minutes, including
5.28 extra setup/cleanup minutes versus the same complete workload. These are
forecasts, not measured successor acceptance; no paid capacity/account changes.

Preserve the existing shared FIFO, admission and owned-cleanup policy. No retries,
assertion weakening, fixture shortcuts, unsafe reviewer aliases, human-gate
bypasses, protected/default pushes, or new standalone runs. Continue bounded
reviews and report real outcomes or concrete blockers. Private evidence transfer
and the exact Mini acceptance are still outstanding.
