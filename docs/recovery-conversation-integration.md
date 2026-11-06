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
concrete Store constructor are added. Hosted cleanup explicitly finishes any
held continuation; neither new deinit resumes work or touches UIKit.

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
