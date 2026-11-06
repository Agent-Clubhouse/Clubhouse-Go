# Compact recovery integration plan

Status: source implementation authorized against exactly
`d22b69bd6240b07fc223e988bb500c012e61b8ad` from PR #323, merged as an explicit
dependency. Caller wiring is a separate commit on the main-based recovery
integration branch. Header source remains separate on PR #318. Runtime/landing
acceptance is pending; the local shared Mac remains reserved by the parent.

## Narrow caller change after clearance

- Construct `CompanionRecoveryStatus` from the selected target's existing host
  connection and conversation `isLoading`, `requiresResync`, and `error` values.
  Render `CompanionRecoveryStatusView` where the current connection banner sits.
  Include connected first/history loading, even before resync becomes true.
- Bind each actual retry callback to an immutable copy of the presented target:
  reconnect calls only `store.reconnect(hostID:)`; refresh calls only
  `store.load(target, force: true)`. Do not derive a destination from a mutable
  selection when the task executes. Add no general async dispatcher API.
- Scope only the recovery row/sheet identity to its target and selected/visible
  state. Moving between retained Review pages must dismiss the previous recovery
  details rather than silently retarget its action. Keep the timeline/root
  identity, bookmark, focus and lifecycle scheduling unchanged.
- Remove the duplicate first-load transcript spinner and large timeline error
  panel when the recovery presentation owns the same state. Preserve complete
  errors and retry access in Details. Suppress the large empty-conversation
  prompt during recovery; retain archive and earlier-history links. Update
  `hasTimelineHeader` to describe only the remaining transcript header content.
- Keep the small existing composer captions unchanged. Keep operation errors
  and Dismiss, pending provider results, sleep/uncertain-result controls, other
  agents' warnings and just-created notices independent and actionable.

The final component must describe a disconnected client without claiming the
desktop itself is offline. Refresh explanations must refer to conversation
actions, and an error alone must not invent a command lock. Store remains the
sole source of action availability; presentation never changes its gates.

## Dedicated synthetic fixture boundaries

Use new recovery-specific service/fixture/test files. The synthetic service
owns fixed canned hosts/targets, explicit history-result gates and call records.
It performs no socket, provider, feedback or paired-desktop operation. History
completion/failure is controlled explicitly, rather than by changing production
timers, adding lifecycle hooks, or relying on arbitrary delays. Existing shared
PreviewService/live adapter behavior remains unchanged.

Actual UI coverage may use a DEBUG route requiring both `--companion-preview`
and a fixed recovery-fixture flag. Inputs are canned scenario choices, never
arbitrary host/name/error injection into a live store. Review any added
concrete Store constructor or actor-class storage under the existing ownership
policy; add only necessary, reviewed entries.

## Hosted effects and command counts

These tests observe the real Store/service effects and actual view callbacks;
they are not a second presentation switch or a copy of the retry mapping.
UI reachability is a separate claim below.

1. First load: suspend the history response, mount the real conversation, and
   verify one history request despite the normal view hooks. A connected load
   presents refreshing; success hides recovery. No presentation-owned task
   starts another reconnect or history request.
2. Connection priority: with resync and an existing history failure, apply
   connecting/reconnecting/synchronizing. Progress remains honest and offers
   Details, without an unsolicited retry. Apply disconnected/failed: a leftover
   history request does not establish connection recovery.
3. Retry connection: invoke the actual row/Details retry with a failed or
   disconnected host. Verify exactly one reconnect for that host, no refresh
   for another target, and no extra recovery scheduler. Then explicitly apply
   the successful connection/history results and verify recovery disappears.
4. Retry history: connected failed/stale history invokes exactly one forced
   history request for the presented target. Failure preserves complete
   multiline details; a later explicit retry/success clears recovery using the
   existing Store behavior. Retained transcript/draft/bookmark survive.
5. Target changes: use two distinct hosts plus two agents on one host. While
   target A's Details is presented, select B. A's Details must close; B's
   Details/action must describe B. An already-issued A action remains bound to
   A if its asynchronous execution/completion overlaps the switch. No A retry
   becomes B's request and no B retry executes against A. Different hosts make
   reconnect scope distinguishable; same-host agents test history-target scope.
6. Retained visibility: repeat the target case with Review's selected page and
   a retained inactive conversation, not only complete navigation destruction.
   Count only explicit retry effects separately from pre-existing automatic
   view/load hooks; identify both sources in assertions.
7. Command gating: compare the real Store's can-operate/send behavior before,
   during and after each transition. Presentation must not enable commands,
   clear errors, mutate resync, or turn a bare error into a new lock.

## Actual UI reachability and deduplication

1. Drive progress → failure → retry → recovered through the real conversation
   and Details. Progress has one compact headline; no duplicate large loading,
   error or empty panel appears in the transcript. Verify the row disappears
   after clean connected history success.
2. Open Details during progress with a retained error and during failure. Read
   full multiline connection/history text without truncation. Row retry,
   Details retry, Details and Done have actual 44-point interaction targets;
   large text/narrow screens keep them reachable.
3. Exercise both row and Details retry callbacks with host/target changes.
   Check sheet dismissal and visible target content independently of the
   hosted service-call-count assertions. Do not call a model or real desktop.
4. Verify archive/earlier-history access, a reading entry/draft, the small
   composer reconnect/refresh caption and distinct operation/provider/sleep
   warnings. No warning is reclassified as connection progress or silently
   removed by deduplication.
5. Include standard and large accessibility text, keyboard up/down, retained
   Review switching and the combined header/composer/avatar candidate. This
   recovery fixture is not proof of RootView tab behavior or physical-device
   lifecycle recovery.

Source parsing/diff checks may run before the serial slot. Build, package tests,
hosted tests, simulator UI actions and screenshots wait for the parent's queue.
Record the final cleared component SHA, integrated candidate SHA, commands,
runtime/model/viewport and individual outcomes; do not infer acceptance from
the old report or standalone component tests.

## Implemented source and queued commands

The exact component dependency is preserved as an ancestor through merge
`b6bfa0be`; caller delta `fb204921` changes only ConversationView and this plan.
Its recovery identity includes target and selected/visible state; each callback
captures its presented target. The integration does not alter Store, shared
services, transport, composer captions, settings/provider/sleep warnings, or
operation-error handling.

`CompanionRecoveryFixture.swift` adds a dedicated DEBUG service and scene.
The service records requests and holds history with explicit checked
continuations; `finish` supplies a canned success/failure, with no polling timer
or real transport. Two targets share `recovery-one`; the third uses
`recovery-two`. Its scene retains only that service, the reviewed Store and
selection/visibility values. The ownership extractor supplied exact storage
and constructor inputs; only these two reviewed ARC-only entries and this
concrete Store constructor are added. MainActor teardown sets a Boolean fence
before finishing held continuations, so late queued loads cannot enter another
hold. Hosted windows choose a foreground-active scene, capture its key window,
hide/detach the root and restore the prior key window in defer, then await and
report pending-request/Store-load drain. Neither new deinit resumes work or
touches UIKit. A separate teardown case verifies a late held-mode mutation
cannot reopen admission.

The hosted `CompanionRecoveryIntegrationTests` finds the actual accessibility
leaf, requires non-nil lookup and `accessibilityActivate() == true`, and checks
service effects from that callback. It separates existing automatic view-load
requests from explicit retries. Target-switch cases cover Details dismissal,
an issued row retry, an issued Details retry, different-host reconnect and
same-host/different-agent history. This public accessibility activation is
**not** proof of native touch or VoiceOver traversal.

`CompanionRecoveryIntegrationUITests` uses real taps for progress → failure →
Details retry → recovered, full multiline errors, 44-point buttons, independent
operation warnings and another host's target Details. It also checks the
duplicate large transcript panels are absent. The fixture requires both
`--companion-preview` and `--companion-preview-recovery-fixture`; the default
preview/live routes are unchanged. It is an actual NavigationStack/conversation
fixture, excluding RootView/tab and physical-device lifecycle proof.
Its six retained, unannotated synthetic UI captures show compact progress,
history failure, full Details, recovered transcript, AX warning/retry, and AX
full connection/history Details. These are actual fresh app screenshots,
not the original feedback PNGs. Existence/hit-target assertions are not pixel
or keyboard evidence; keyboard coverage remains in the combined header matrix.

After the parent allocates the local serial slot, run the combined candidate
with the exact cleared component and selected header/composer/avatar source:

```sh
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,id=<parent-owned-simulator-UDID>' \
  -derivedDataPath build/recovery-integration/DerivedData \
  -resultBundlePath build/recovery-integration/RecoveryIntegration.xcresult \
  -only-testing:ClubhouseGoTests/CompanionRecoveryIntegrationTests \
  -only-testing:ClubhouseGoUITests/CompanionRecoveryIntegrationUITests \
  CODE_SIGNING_ALLOWED=NO test
```

A matching build-for-testing artifact may use `test-without-building`. Existing
component domain/hosted tests remain separate. Full build/tests, native UI,
policy-binary validation, Review integration and combined screenshot acceptance
are pending; only source parsing, ownership-source extraction and diff checks
have run locally.

Overlap for the parent combining #318: both branches touch ConversationView's
opening content stack, but recovery replaces only `connectionBanner`, its
visibility/derived status, timeline recovery panels and `hasTimelineHeader`.
Keep #318's identity/disclosure/footer/usage changes. Both add a PreviewRoot
fixture guard: combine the distinct recovery/header fixture branches before
the unchanged normal preview. Combine both additive ownership capture entries;
do not replace the existing policy or either fixture's concrete review.

## First combined failure and bounded evidence proposal

Parent candidate `1701db0a788cca1658ecc10ec3cc42a81e5b9606` passed the 11
domain cases and Debug build. Its single hosted batch passed 12 of 15 cases;
the three failures were the initial Details/retry prerequisites in
`testDetailsDismissOnTargetSwitchAndRetriesStayWithTheirHost`,
`testQueuedRefreshRemainsBoundToOldAgentOnSameHost`, and
`testRetainedInactivePageDismissesDetailsWithoutResettingReadingOrDraft`.
Each had one run and failed after its existing five-second predicate. No
recovery callback or target-switch assertion was reached in those cases.
The native UI batch was not run. The result contained no matching hosted
attachments, so it does not distinguish missing/covered product UI from a
limitation in the hosted public accessibility lookup. Source review alone
does not establish the cause.

The diagnostic successor changes tests only. Polling deadline, final predicate
evaluation, existing leaf search and single activation remain intact. A failed
prerequisite or activation now throws immediately; a failed unwrap already
throws. The hosted wrapper captures evidence before its existing teardown,
then rethrows without another predicate/control lookup or action. The queued
prerequisite records request count, loading and leaf result separately while
preserving its original short circuit (a skipped leaf is explicitly labeled).

Each failed hosted body produces at most one evidence event: an unannotated
original synthetic window PNG, a target/model/service/window ledger, and a
public AX inventory. Rendering uses `afterScreenUpdates: false`, with no
layout, refocus, activation, waits or private APIs. The PNG is taken before
the AX scan and capped at 12 million pixels. Window enumeration is capped at
8; controller traversal at 12 nodes/depth 6/8 children; AX traversal at 256
nodes/depth 12/64 children per edge, 160 characters per string and 65,536
encoded record bytes. Each JSON attachment is capped at 73,728 bytes and
reports truncation. The AX inventory records protocol/direct public IDs and
geometry independently of the unchanged lookup. Any leaf it finds is a
**post-failure observation**, never a recovered test outcome. Capture may
affect subsequent presentation timing; the failed outcome is already fixed.
These attachments contain canned synthetic fixture content only.

Proposed next allocation: parent merges the exact diagnostic successor into
a new source candidate, preserving frozen `1701db0a`. Run only the three
named hosted cases once, without repetition, retry or delay changes, on the
same simulator/configuration. Export their original attachments and individual
outcomes before selecting a fix or allocating native UI validation. This is
a diagnostic proposal, not an executed run or runtime acceptance; hosted
activation remains distinct from native touch/VoiceOver reachability.

## Native single-attempt diagnostic nomination

Exact combined source `0f7d8821a77e6aeaeca24f93f1daa3e9d066414b` passed
Debug compilation; all three selected hosted methods failed once before
activation. The nine original captures are indexed by git blob
`d36d9bcf10dc8faaa6976aae3053704fc93ff032`. All three PNGs show the
recovery row and its action controls. The queued ledger records calls 3,
loading false, leaf false; both Details ledgers record connectionFailed and
visible true. The depth-12 inventories contain only backing subviews with
nil direct/protocol identifiers and no declared/container AX children. They
do not establish a protocol/direct-ID mismatch or explain the original
lookup, which has no depth limit. Native export and callback routing remain
unproven; no product change follows from these artifacts alone.

The earlier proposal to run an unchanged native method "once" meant one test
invocation, but overlooked the shared helpers' three launch/gesture attempts.
`CompanionRecoveryXCUIDiagnosticTests` is a new, dedicated single-route case:
one explicit launch attempt and one attempt for each of its six route gestures
(two fixture menu selections, Details, Details retry), plus the single bounded
content-navigation gesture described below when needed. Existing shared
helpers and native methods are unchanged. All original normal-route
assertions, 10/5-second waits and 240-second allowance remain; the shared
single-attempt gesture helper still has its original final two-second wait.
There is no expected-failure launch loop at attempts 1. Successful-state
screenshots are omitted in this diagnostic; it retains at most two evidence
attachments on the first issue, rather than claiming a visual matrix.

The local XCTest recording hook defers forwarding the exact original issue
once, without rewriting it or changing continueAfterFailure=false. On a
synchronous main-thread callback it uses runtime-checked MainActor entry,
latches before capture, and retains the original app screenshot followed by
public app.debugDescription. Recursive issues cannot start another capture.
Unexpected non-main callbacks or unavailable app handles report incomplete
capture and retain the original failure without dispatching or waiting.
Hierarchy output is capped at 65,536 UTF-8 bytes including a truncation
marker. The public SDK's hierarchy retrieval has no caller-supplied size or
duration bound; the test's existing allowance still applies. Screenshot and
hierarchy collection occur after failure and can change presentation timing;
neither can rescue a failure or justify a later test lookup/action. No hook
tap, refocus, private API or explicit wait is added.

After source review and explicit allocation, parent should select exactly
one default invocation (no iteration or retry flags) on the same
375-point/iOS 26.0 simulator configuration:

```sh
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,id=<parent-owned-simulator-UDID>' \
  -derivedDataPath build/recovery-xcui-diagnostic/DerivedData \
  -resultBundlePath build/recovery-xcui-diagnostic/SingleRoute.xcresult \
  -only-testing:ClubhouseGoUITests/CompanionRecoveryXCUIDiagnosticTests/testSingleAttemptProgressFailureDetailsRetryAndRecovery \
  -jobs 4 -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 CODE_SIGNING_ALLOWED=NO test
```

Parent records the exact new combined head before execution, preserving both
failed combined candidates. This route can establish native exported control
and real tap reachability for progress → failure → Details retry → recovered.
It does not establish VoiceOver traversal, two-target service request counts,
the unresolved hosted discovery mechanism, or broad visual acceptance.
This nomination has not been built or run locally.

## Medium-sheet navigation correction after native failure

Parent ran exact `063fc7480e23943f8e0b6667b59ab7b8f833d696`: Debug passed;
the diagnostic method ran once and failed at `retry.isHittable` after
14.324402 seconds. Original screenshot/public hierarchy are indexed by blob
`6a93f0f9fc4a3bc9d3fc23d95edd5ae17fbd69b5`. Native row Details was exported
at 44 by 44 points and tapped once; explanation/full-error/target checks
passed. Retry was exported at y 685.7–728.9, below the 667-point screen in
the medium scroll sheet. The test had not navigated its content before
asserting immediate hittability. No retry tap or recovered assertion ran.
This supports a missing test-navigation step, without proving a product
export defect or resolving any of the three hosted discovery/routing failures.

The diagnostic-only correction selects a unique ScrollView containing the
retry identifier and the unique `Connection and recovery` navigation bar.
Its usable viewport intersects the main window and scroll frame, excludes
the navigation bar, and insets gesture endpoints by 12 points. If the target
is fully contained, no gesture runs. Otherwise it permits only a target below
that viewport, with a positive displacement from target center to viewport
center that fits within the viewport height. The start sits one point inside
the inset viewport's lower boundary; end is displaced upward by that measured
amount. Both endpoints must lie within the viewport and app frame before
one 0.05-second content drag. Unexpected above/invalid geometry fails without
an action; a contained but occluded target still fails the original hit test.
No grabber/detent action, blind target tap, swipe loop, font cap, new wait,
timeout increase or retry is introduced.

After that one gesture, both current scroll/window/nav viewport and target
frame are re-read and the whole target must be contained. The original
isHittable and strict width/height ≥44 assertions, full-error checks, single
Details retry tap and recovered-state checks remain. The first-failure hook,
existing native methods, shared helpers and product source are unchanged.
The captured scaled-sheet retry height was also 43.2 points: that is not
rounded or tolerated. A remaining size or hit-test failure must remain a
failure with its original evidence. The same single-method/default-once
serial invocation above is nominated only after parent source review and
allocation; the corrected source has not been built or run locally.
