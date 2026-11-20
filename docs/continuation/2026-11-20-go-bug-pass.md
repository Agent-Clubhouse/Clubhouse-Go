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

The parent verified the two unchanged PinnedDecision UTF-8 exports
(1,898 and 117,174 bytes) and routed a metadata manifest to Navi. No duplicate
manifest or private payload was sent by this agent. That routing is not exact
successor scope acceptance. The first recording and original binary events
remain local; their unavailable transfer still defers corresponding attribution.

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

## Independent review and runtime boundaries

| Scope | Exact candidate and current boundary |
| --- | --- |
| Combined iPad partition / Footer focus / Preview gesture / transport carry | SOURCE-only approved at `026688254361e5cb1ee09ee5430df6973462a179`, local review `ff8b4840abab3b37b7d763f21e0b236aa84dac0f` / SHA256 `0f2033b7f3a60ddb2b8c1c51b1add19f546bd490532706a7bed0b4ecb5aece90`. Two exact pure tests and three Swift parses passed, not native/cure acceptance. |
| Package original receipts | SOURCE-only closed at current `3980cf4445e51d9a554eb5ab08703ecfecd639d3`, exact workflow/tests bytes from `a90b24cb80ded7a501f73f7a5ae06151b49294b9`. Exact sanitized canonical `2026-11-20-go-bug-pass-receipts-carry-source.json`, Git `b1997508166c58f6543c6550a6d38b8896e6883a` / SHA256 `e0597d3e6d45e0f2e836678b0602f37a53de307f863e4594e56ff5c4923bec46`. Six actual inert shell tests passed; actual old artifact pattern fails the sidecar selection control. Test failure outranks concurrent writer failure; writer-only and toolchain failures remain nonzero. Full coverage/default concurrency/20-minute policy retained. No authentic next-run XML credit yet. |
| Additive hosted probes | Same combined SOURCE-only receipt closes exact two-file `f47` byte carry into `3980cf4` above `a90b24c`. Prior independent `0f2b` / `13aa` source verdict carried by exact blobs only, not self logic re-review or final-head native/cause proof. Parent approved next normal hosted run, not a standalone trigger. |
| Footer / Preview execution and first build | Frozen native candidate `0266882`; manifest `c781589bd9967365173abde5eef57298b9dd24c18740c67a2573acee1dbe4eb6`. CONFIG-only `87c5fd5697347ff5e39ee5d030d84974cb134c57` accepted. First actual A independently closed by `211ebecc51ff03d8bc8bb125e07ef28469c5cfe8` / SHA256 `cd5b6af6bf56fa0e60e6b20bf250649f63af425f146b1ae0e5bb357f42f29fe4`: all 47 originals / 243,376,757 bytes, entire actual five products, source759/current8/data/deinit/policy/raw guard/owned closure; actual after-FIFO 228.368739 seconds. Runner installed the genuine owner-excluding A gate and rehashed current five before beginning its first ordinary-FIFO T. Exactly five methods / seven launches / 36 strip reports and separate T-originals acceptance remain required. Keyboard presence alone is not native field-focus credit; no T/hosted/cure/Mini acceptance inferred. |
| Linked Home source/config | SOURCE-only `a343b26997e6f4b0b2e86ee2c62ac74335a072d1` / `239269c0e6b0bf3c3932fc59f6cc2a11809e9360` approved. CONFIG-only now closed at manifest `c62706138556933d7951d7dabfaa349a57e9499d1d928373d95fe87ceef29bfc`: canonical `f7dae7fa1d63eda6e071320b4ae89281756fccbe` / SHA256 `05f4412f397216e3650afeb08d1e08e17e410335933e75c455fa1c8182860326`. Entire common8 runtime unchanged; actual758 Git files, declared166 package tests and all139 native test sources bound. Fresh independent full-five A remains required before one native case once, two explicit launches, original240-second method allowance. UX owns ordering/execution; no native/collapse/cure credit. |
| Dispatcher sender-fold observer/config | SOURCE-only `3dda22673aff9b5c10c8e33518b04a5d27af6a60` / tree `59792d494e1b77672d730f0b8024beb93737b8bb` approved. Exact sanitized receipt `2026-11-20-go-bug-pass-sender-source.json`, Git `827fcadeb86ee3ff8c70dde6d784b1c7af1296ff` / SHA256 `0def951bf4032f0c736679de21c77ecaa2f99601938aeaaabb90c2592094fc47`. CONFIG-only manifest `88740e59a798b07336afbe07684294ebd9f48f29a28e8d3e880e4ee7ed315486` closed by `84adf0cfcbdf2c0f9dfee13459e22b7277c6b69b` / SHA256 `8154e60815c4ae4546c77c788f824e2ae63aa0c4c6f02051e69d531ea221dd3f`. Only worker change restores both command allowances240-to-original360 for this one case. Source helper plus seven IDs reconstruct the base file; routed-copy and generic helpers unchanged. Fresh independent full-five A required before one case once / one launch; actual native snapshot fit/hittability/timing and separate originals acceptance remain open. |

### Footer / Preview first-T originals closure

The first local T is now independently accepted, superseding the pending-T
status in the table: canonical local Git blob
`f7f24aabd68b1efdd2999152d3847102d76c1a79`, 10,128 bytes, SHA256
`af902f3a4ba90f0e9916821e070747177ac73c4ab2b3d23f8dc6b2ad40e0026f`.
Verdict `PASS_EXACT_OWNED_PROOF_ORIGINALS`, phase T / rc0, binds exact
`026688254361e5cb1ee09ee5430df6973462a179` / tree
`dc093496ee0c92ae3d375d60f7aee255ca5e92c0`, the same manifest/full8,
receipt SHA256 `2f79a6b91e1f44c9a4f76a2f9111446ee0138916353e2bca54cdeba44a3bc435`,
and external SHA256
`9efeae233749b64a5f9369e20d53d20a0ec25e29c7a65ed30088a8a7c9b7fb2b`.
The full report contains private host paths and remains local.

All 210 originals / 426,528,617 bytes, all 47 A originals, genuine independent
gates, source759/full8/data and the entire five A/pre/post/current products
were verified. Raw SQLite establishes five methods once, no repetitions or
issues; seven native SUT launches comprise six Footer and one Preview.
All 28 entire PNGs were individually viewed and byte-bound to raw result data.
All 36 strip pixel records were independently recomputed: maximum guarded
adjacent-row step 2.583333333333343 <= 3; 24 standard-room strips meet 4.
Overflow rows at/below keyboardTop-40 remain logged only, and pending/overflow
room colour is not guarded. No universal flat-colour/lower-overflow claim.

Native Preview records establish actual gutter gestures, two whole-link/current
clear-band midpoint taps once, expected opens, Done and swipe dismissals, and
Following1/pauses0 becoming and remaining Following0/pauses1 through the final
post-swipe observation. Actual Preview SUT live-tool labels advance; unrelated
Footer synthetic-update labels are not Preview evidence. Its two PNGs show
before-tap targets, not displayed-sheet or final-dismissal pixels.
Native field-focus remains **DEFERRED**: no direct flags recovered in complete
text/native exports; retained binary leaves do not prove blanket flag absence.
Keyboard, caret, typing and hierarchy-request titles are not substitute flags.

Admission/pretest raw measurements, 29 active swap deltas, QuickPath/20-second
stabilization, original240-second method allowance, all-zero closure, owned
simulator deletion and empty owned groups were checked. Actual after-FIFO
duration is 291.87338079186156 seconds, below900. This accepts the exact local
iPhone17/iOS26.0 first-T originals only, not hosted iOS26.5, real-device iOS27,
cause/cure, an integrated head, Mini transfer or landing.

UX subsequently reported successful first A closures for Linked Home
(228.547872 seconds, packet `136cfd6f` / SHA prefix `c9b13159`) and sender
(227.083134 seconds, packet `553046ea` / SHA prefix `b064ba08`). Those are
owner-reported milestones, not this agent's independent originals verdicts.
Runner owns the two separate independent A-original reviews; their T gates
remain held. Parent milestone delivery returned an explicit sleeping-agent
error; no wake, start or restart was attempted. UX later reported independent
A acceptance and first native submissions, followed by two retained first reds:
Linked Home fails the Search-selected oracle before reaching Home; sender fails
its first caption at the20-pan cap with tiny cross-representation frame
differences. Proposed narrow source children are not yet reviewed or accepted;
neither earlier source/config verdict implied runtime success.

The narrow successor SOURCE-only reviews are now closed, not their execution
configs or fresh native proofs. Linked Home
`504b9c926e33d8823a183155d675cf36b4f7bf3a` / tree
`474c84ec99f698011e65d5f24035bc27906da39b` is accepted by local canonical
`2ee818486a3e78c6d74fa92eea8ca2f54f401a0b` (1,841 bytes, SHA256
`f6526788339e12154bc08c5f451c87c6f04518532eba9e71e1532ba4b4c5f1b5`).
Only the invalid Search-selected assertion becomes the source-defined Search
navigation title wait5s AND current exact SearchField existence. Reversing that
assertion reconstructs the whole parent test file. Home selection, no-reexpand
reveal, Expanded/read-only cached-row and relaunch Collapsed checks are unchanged.
Selected original native tree/log/actualPTS bytes were checked; the earlier
video frame is not failure-instant evidence. Own child parse/diff checks passed.

Final sender SOURCE-only target
`bc40dbb0f435d6f2b4cd52e508ff60a7b756afc3` / tree
`58d9f5f6bafa533551853c79615f0326036ecebe` is accepted by local canonical
`467e7267effb54def6e6740ae5f3e11a1390f2c1` (2,189 bytes, SHA256
`40220451c0b48ab7037d938eaf44a9676a46c0516380d296147e9d2f85d4dc33`).
It adds only a documentation qualification above implementation-reviewed
`ef6506cc14cda7f6538460d8c8684eff598f4f7c`, whose canonical is
`40f5687e33cf7b40d94f06cad61d22e6236dab49` (2,700 bytes, SHA256
`5ea80b04392319cd9572a3e2ed7b3d32be12a4d21454859f54a1b00182a889ac`).
Finite per-component representation agreement permits at most4*maxULP;
unmodified snapshot/live frames still fit strict current bounds, with actual
ID/exists/hittability and a fresh complete final observation. No band inflation
or point epsilon is added. Own actual extracted-source Swift26 numeric controls
include original-pair fail-before, inclusive4/exclusive5ULP boundaries for all
components, nonfinite/real-displacement rejection and a1ULP band crossing still
rejected by containment. Parse/diff checks passed. The final docs child correctly
disclaims a guarantee about every mathematically nonzero displacement; prior
controls carry by byte identity, not a rerun. Generic helpers, Copy, semantic
sender case,20-pan/140 aggregate and360-second allowance remain unchanged.

Both successor source verdicts preserve the first native failures and require
new exact execution configurations and fresh independently accepted A/current
five before their first native T. They do not prove native timing, successful
folding, a cure or integrated/Mini acceptance. No Reading, Copy or typing repair
scope was added.

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
