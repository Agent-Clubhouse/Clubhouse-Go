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

The two successor execution-only CONFIG gates are also closed by genuine
go-bug-pass originals, not A or native acceptance. Linked504b manifest
`a1e8ca40e8a1b54f9305bfb78fdee05228fc3486b85c464792074d78f69a4987`
has local canonical `3a4b19a2894777a07732e304faea583d13c4b725`,
5,116 bytes, SHA256
`3fc977eeb627d2a2a29b322aeeaf413a64a25e48229d4a7786a6b0ac63182ab0`.
Senderbc40 manifest
`cc28642fd7e457ce9fd97e15ba5aa7480b6f979e40472cac5b4507e5616a23de`
has local canonical `20d45fe38099e9c1671e5d8f4a69484aa4eb7641`,
5,168 bytes, SHA256
`3ad8e135ae48a1f2b3b9e2673dd280841033203d79a51b69efdf6dd7dcdfe2e8`.
All14/15 packet entries and current758 source modes/blobs/full-byte hashes,
full diff, whole closure and166 package/139 native test files were verified.
Full8 runtime bytes match each genuine accepted predecessor; every remaining
execution field matches after artifact-root normalization. Fresh private nonce
and source/data/pin changes do not carry old A/T credit. Existing phase labels
remain a-r1/t-r1 while new roots and exact manifest identify each successor.
No import, worker, FIFO, build or simulator action occurred during review.
Owners must install exact current gates and obtain fresh independent A/current
actualfive before one native case once under original240/360 allowances and
900-second bounds. Full private path-bearing reports remain local; source and
configuration pins here do not imply runtime success or loosen any earlier limit.

Sender's first corrected-component native attempt atbc40 is subsequently
reported failed once46.593s before Cedar's first fold; its original failure is
retained separately from3dda. A new source-only edge-representation child
`4fde2a033976ce6ca969889b8ed0f1764aa99c8a` / tree
`32a63fc52424d42f9820ef400fff62f463e544b4` is independently accepted by
canonical `2e5bb15b3d1905ccfc4c14918ba03e64e3a78ec2`,3,966 bytes, SHA256
`69f5b6c3675d904c78fb2c20b22bfa2e12e23173386f906972e241b06a83dfb2`.
Only comparator/comments and direct docs differ; reversing the block exactly
reconstructs the entirebc40 test. All eight raw components must be finite and
dimensions positive; corresponding computed rectangle edges must be finite
and agree within the same4*maxULP bound. Initial/live/final strict containment,
real identity/exists/hittability and fresh hierarchy are unchanged. Full selected
native test log/session/excerpt bytes reconcile six actual hosted-frame
conversion records with six contained snapshot/live pairs, not native success.
Own extracted CoreGraphics Swift76 controls and exact-file parse/diff passed.
This supersedesbc40 as the next source-review target only: fresh exact CONFIG,
A/current actualfive and first native360/T900 are still required. No full90-entry
negative-run acceptance, cure or microscopic-movement/simultaneous-revision
guarantee is inferred. Linked504b first31.7096s/two-launch T pass remains an owner
report pending separate originals acceptance; no shared Reading/Copy scope changes.

The exact4fde r3 execution-only CONFIG is subsequently accepted:
manifest `fc61891ae41c32dd77488cf1ad3e7cdae6cfb34a10c58d2b8059973103ec0bc0`,
local canonical `71d51e30ff7cb4bdfc832ce6b6e000ecda86f828`,
5,197 bytes, SHA256
`72994c5247c6c71c9c82eb02f27b9d92a9d5e2e90feecc9ad9ed8949bac5cbcd`.
All15 immutable originals563,381 bytes, current758 source modes/blobs/bytes,
full diff/closure/166 package/139 native tests and current source verdict were
verified. Full8 runtime remains exactly genuine20d45/r2, including original360
worker, and all other execution fields match after r3/r2 root normalization.
Only disclosed source/data/pin, scope/status/failure-description and fresh-root
nonce differences exist. This closes CONFIG only, not new A/currentfive or T.
No imports, worker, FIFO or native actions occurred; both prior first reds,
privacy, strict oracles and all normal measured admission/cleanup gates persist.

Linked504b's first31.7096449s/two-launch T is now reported independently accepted
by runner canonical47a74523,7,729 bytes, SHA256
`5046625c24c1d65454d7e2c06cee732b013826e3bad8be30318d66c56a906462`,
with owner-installed gate/current actualfive/full8 and qualified native/photos/
cleanup findings. This is runner's acceptance, not a second T audit here.
The ready Linked-only contribution is the ENTIREab6..504b range
`bc961baaf93f33954e480d676b02cfd2bba86a8f` ->
`a343b26997e6f4b0b2e86ee2c62ac74335a072d1` ->
`504b9c926e33d8823a183155d675cf36b4f7bf3a`;504b alone omits initial reveal
assertions. No product-collapse cause, initial cached full clearance, forced-tap
immunity, same-AX-revision, hosted/general-cure or integrated-head proof is
inferred. Source ownership remains UX; no integration or transfer was performed.

Feedback owner's additive Linked carry7540 onto3980 is independently accepted
SOURCE-only: exact `7540be2108510545899d5d4b60890a5118532a90` / tree
`f6c194326157760d950360c1eaf09ca5fcb6610a`, canonical
`aaa213e5ec0c64a3fcfb694532fc607fbd9c4d9b`,2,789 bytes, SHA256
`fea7e0ab9ba086dc3e95b3372cd89dfc6a2fa1535d6ae87364437fc84c68ed79`.
All761 Git paths/modes/blobs were compared: only Linked test modified and
its new directly related docs added; both are exactly504b. All166 package/
139 native test paths and unrelated3980 source remain unchanged. Own exact
Swift parse/diff passed; author44 CI checks were attributed, not rerun.
Actual full47a74523 source-T canonical bytes/hash/metadata were independently
checked, still source504b only and not a second native-originals audit.
Owner reports normal preservation push/readback complete; no PR620 head or CI
trigger was changed by this review, and sender4fde remains excluded.

New ordinary Reading hosted first-red attribution is separately closed:
ab6/run44685281882/job136135075427,
`testHistoryPrependStreamingKeyboardAndReturnKeepTheReadingEntry` guard387,
canonical `5804c42e22835b60ef7d8090c667e0ac8bc19c0a`,6,204 bytes, SHA256
`6db62c16eccfd4ffd222201d8b85ec537995fd3782f918bd003af38ee8345ca6`.
This is FIRST_RED_RETAINED_READINESS_SAMPLING_BUDGET_ATTRIBUTED, not green.
Complete original log677,791 bytes and test-results-10 artifact14621520848
ZIP392,534,146 bytes were verified; raw native runs match first77.644 and
retained72.579/67.925 failures. Readiness helper bytes equal scopedff8.
First attempt's sequential acquisition consumes at least7.172 recorded seconds
before its first complete sample, leaving at most0.828s inside8s, below the
required2.25s stability. Second repetition similarly7.045s; third is faster
5.037s and does not support that same first-window claim. Every observed
second acquisition completes past the latest possible8s deadline. These are
recorded native-activity/source-order bounds, not an exported uptime timeline
or simultaneous geometry. Observation budget starvation is supported; actual
frame movement/bookmark displacement and product cause are not established.
Later4pt/stream/keyboard/return assertions were not reached. No named restoration
timeline/four-point measurement attachment was retained in raw metadata; opaque
legacy snapshots/events/movie are not a blanket absence proof for geometry/focus.
Preserve8s/2.25s/0.5 comparator/4pt; any repair needs separate scope and actual
native acquisition evidence, not a bigger budget or expected-offset readiness.
No source changes, new native/worker/build/FIFO/export/classifier action, or
f47/local proof/ReadingOpening58/Chooser/typing/menu/Grant scope absorption.

Native Home menu candidate6179 is independently accepted SOURCE-only:
`6179b6c75c570c0a1f9ccb4bcd3ed5ff8dd17716` / tree
`208f75f7a1c7701ab374cba88c26acfefddec307`, canonical
`c1cc5870ee60add355b04196c373546ec59e22d2`,2,835 bytes, SHA256
`5f852c235f246496d63d4b08e37fdc874e5910d1ead4487fdf8b22d55350117f`.
Reversing only traversal/observation/live-return guards reconstructs the entire
reviewed7540 menu test. One collection snapshot per step locally traverses
descendant buttons; original menu-label indexes drive range/pan choices.
Original full label/order/uniqueness, collection/panel, strict full fit, eight
pans, actions/themes/two selectors/default240 remain. Returned live actions
must exist/be hittable/enabled and have finite positive actual geometry inside
the fresh clip; snapshot containment cannot substitute. Own extracted four
inert traversal controls and exact-file parse/diff passed. Actual native
snapshot/query membership/currentness, timings and complete action paths are
not credited; candidate remains UNBUILT/UNRUN without CONFIG/A/T/native cure.

Final ab6/run44685281882 outcomes are preserved as feedback owner's census,
not another independent aggregate or repaired-CI verdict. Run CLOSED/cancelled:
15 UI lanes,8 success/6 failure/1 cancelled; all442 intended source methods
have stdout starts,441 standard terminal outcomes, final Diagnostic root-tab
interrupted. Starts/skip/retries do not imply first passes. Aggregate job
elapsed574.0667m versus661.97585 forecast includes setup/retries/cleanup;
reported dispatcher57.1m tail and Preview47.58/Launcher53.4/Reading48.92/
Composer46.93 exceed their forecasts, not sole-cause timing attribution.
Final activity/permissions job136135075435 log
`59c4e8cea561aa513b0adbde1bb7d4425be7eb72`,893,302 bytes, SHA256
`262a395ba5e01c6765e0977baf6787e4e1b642b922f549cf5644952eb858a7ae`,
reports five HeaderReflow tests failing all repetitions: four lack100 samples
(actual5-25), push/pop lacks Back. No fixed-header product-reflow cause or owner
is inferred; permission family has no reported first-red signature.
Final author census `c4db2a4ca56d50097643116bcc1b964cc03d943c`, SHA256
`b0faf6400f975a34c736678ab9e90baa2908bb98d1cf75f72332bbc608a5fef0`.
No source/native/hosted gate conflation, new scope/run, parent wake or Mini contact.

NativeMenu6179 owned execution CONFIG is independently closed:
manifest `8fc2746bc694f5681c8de8bbd67aa12c030ff4d26235d19068b6dc36c7c3f2c2`,
local canonical `05db46adf2bc2ae887be9074b5f68c5a74cfcfe8`,
6,893 bytes, SHA256
`87883844bb69ec3048d8383d47d0aaa0b8a25abb15f954f283aa9fa89f5634be`.
All16 originals590,862 bytes and actual762 Git modes/blobs/full bytes/diff/
closure were verified. Declared166 package-test subset is not native coverage:
all321 test Swift files, including139 native files, are rehashed through the
full762 source binding. Full8 runtime equals genuine Footer026/87c5, with
executor/aliases excluded from original A/T review by unchanged e5 validator.
Exact freshA900/current independently accepted full actualfive precedesT900;
two methods once, alphabetical Accessibility then Default,4 launches/8 single
row presses/original240/8 pans/OS20/QuickPath/FIFO/active64/owned cleanup remain.
Actual snapshot/query membership/order/live full fit/actions/photos/prepostfive
are obligations, not new evidence. No execution, imports, peer-live reads or
old A/T carry occurred; private full CONFIG report remains local. Owner exact
installation/current checks and measured admission plus fresh A/T gates persist.

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
