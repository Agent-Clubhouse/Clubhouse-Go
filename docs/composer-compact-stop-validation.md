# Compact composer and adjacent Interrupt

## Source and scope

Baseline: main `b17f9f80`, phone build 218. Parent-triaged Framebriar reports
`73e0e7c1` (2026-11-06 04:42:18Z, Working) and `3c1fef9e`
(2026-11-06 04:46:05Z, Done) show the same session. The later compact composer
was approved: “This one good.” Original image blobs were read into this
worktree's ignored `build/composer-layout-reference/`; no images are committed.

`usesCompactControls` depends on focus or accessibility text size, not agent
status. Losing focus expands model/effort controls for both working and idle
agents. Independently, working status places Interrupt left of the input and
adds a steering/queue caption. Thus status alone does not explain the pictures.
The screenshots do not prove the field's focus state; compact rendering follows
the focus/accessibility branch, rather than Done status itself.

Change only `CompanionConversationComposer.swift` and dedicated tests/docs:

1. Keep the existing compact settings menu at every focus/status/text size.
2. Put warning-palette Interrupt immediately before Send, preserving its
   confirmation binding, capability/connection/pending gates and 44pt target.
3. Remove only the normal steering caption, expressing that outcome in an
   accessibility hint. Retain queue, offline, refreshing and unsupported copy,
   with existing pending behavior. No inferred pending delivery claims.
4. Preserve native editor, selection, focus, Return, slash, attachments,
   approvals, sleep and keyboard dismissal behavior.

After the first allocated run measured the existing Attach target at 36pt,
parent authorized a narrow exception in `CompanionAttachments.swift`: retain
the 36pt icon frame inside a minimum 44×44 label/content shape shared by the
picker and preview button. Cache, upload, picker and attachment state behavior
are unchanged.

The parent then reviewed actual full normal/AXXXL video frames and authorized
an adaptive successor: at accessibility sizes the retained editor has its own
full-width line above a 44pt action rail. `AnyLayout` changes layout by text
size only; the field is declared once and its binding, selection, native hook
and focus callbacks stay intact. While editing, one large-text line is visible
and the native field scrolls to its caret, retaining the entire multiline draft
and its normal Dynamic Type font. The 76pt attachment strip stays present.
Icon-only glyphs are bounded inside full targets; textual labels are not capped.
One authorized line bounds the compact slider Image in
`CompanionChatControlsBar.swift`, without affecting menu text.

At accessibility sizes the direct pinned approval row becomes a prominent
warning hand in that rail, with a visible pending exclamation badge. Its full
accessible name identifies “Review approval”, the actual title and current
queue position. Opening it changes only sheet presentation state. A scrollable
sheet reuses `CompanionApprovalCard` with the current live request, exact
wording/options, expiry/resolution state, capability/connection/pending gates
and existing persistent-permission confirmation rules. Operation errors remain
visible there; Close only clears presentation state. Ordinary-size direct
Deny/Allow once actions remain unchanged. This progressive disclosure was
explicitly chosen by the parent to avoid oversized approval buttons consuming
the narrow keyboard region.

## Dedicated cases and serial validation plan

`CompanionCompactComposerUITests` covers:

- Idle Dispatcher: empty and typed draft, keyboard down/up, compact settings
  left of field and same row as Send; permissions/model/effort reachable.
- Working River with attachments and assistive dismissal: empty, image-only and typed
  draft, separate Interrupt and Send, adjacent trailing positions, 44pt targets,
  Interrupt opens confirmation without sending or losing the draft.
- Largest accessibility text: the same working attachment/dismissal row fits
  the window and retains reachable settings, Interrupt and Send.

The adaptive successor adds pending trigger title/queue naming, discover/open/
full-action reachability/Close checks without pressing an approval decision,
text+image draft retention, keyboard context after closing review, and a
multiline draft. Geometry checks require the editor above the action rail at
accessibility sizes, at least 70% of window width, with enabled targets fully
inside the region below the actual navigation/header and above the keyboard.
Screenshots precede row assertions and capture full approval actions after
scrolling. No timeout or retry policy was changed.

Before serial allocation: Swift frontend parse of changed Swift files and
`git diff --check` only. No build, simulator, physical-device or live commands.

After allocation, parent owns runtime/visual review: build and run the dedicated
UI class on the narrow phone, then existing `CompanionChatChromeUITests`,
`CompanionKeyboardDismissalUITests`, `CompanionComposerIsolationTests` and
attachment/slash cases. Check native editor identity/focus and draft retention
using existing isolation coverage. Review screenshots with empty/typed working
and idle drafts, largest text, keyboard down/up, attachment previews, pinned
approval, sleep, offline, refresh, pending command and queue-only capabilities.
Queue explanation must stay truthful; existing reconnect/loading/errors must
remain visible. Parent runs project build/test/lint checks in its serial slot
and records actual results; parsing is not runtime evidence.

## Relationship to existing work

Issue #272 concerns framework Unicode caret corruption under programmatic
focus; this correction does not touch that path. Preserve #312's composer
probe when rebasing. Do not cherry-pick held Return PR #310. Header/tabbar
consistency remains parent-owned.

Focused feedback issue: #315 (open issues and #272 checked first).

Parent authorized focused compatibility edits in two existing test methods for
the newly permanent nested settings menus:
`CompanionPreviewSmokeTests/testChatControlsMenusAndPersistentApproval` and
opt-in `CompanionLiveE2ETests/test4ModelAndLevelSwitch`. They expect direct
permission/model/effort chips; they now open Chat controls, then each nested
menu, preserving choice, confirmation and approval assertions. The live case
polls the compact control's accessibility value for the selected model rather
than a chip hidden inside a closed menu. No other methods or shared helpers
changed. The opt-in live test remains unrun; this is navigation compatibility,
not authority to contact a live desktop.

## Validation recorded

Allocated tested SHA: `cc959d41351e3b1a2ec87f396139c4de71145856` (before the
successor target/test corrections). The branch was preserved at docs-only head
`e1243666` during the detached run. One jobs-4 Debug build passed on Xcode
26.0.1; four selected UI cases ran serially on an owned 375pt iPhone SE (3rd
generation), iOS 26.0 / 23A343. Each started exactly once, with no test retries:

- Existing `testChatControlsMenusAndPersistentApproval` passed.
- Idle case failed because the dedicated test used an unsupported fixture flag;
  Dispatcher settings require `--companion-preview-context-window`. This does
  not establish a product settings failure.
- Normal and largest-text working cases failed at the initial empty/unfocused
  Attach width: 36pt, below the required 44pt. The fixed 36pt label predates this
  composer change. Both cases stopped before image-only/typed/confirmation/
  dismissal checks; those outcomes are not yet runtime validated.

The UI batch exited 65, with 1 pass and 3 failures in 79.109 seconds. Its
effective generated xctestrun selected only the four UI methods and set
`ParallelizationEnabled=false`; the CLI also disabled parallel testing and
used no retry flags. An initial invalid `-test-iterations 1` invocation was
rejected before any build/test and its log is retained separately.

Evidence stays under ignored `build/composer-cc959-validation/`: result bundle,
logs, generated/effective configuration, summary, test tree, attempt audit and
attachment manifests. Original PNGs exist for the smoke test; the new row
cases failed before their screenshot calls. Their original screen recordings
are retained. Full, unedited PNG frames extracted from those recordings are
explicitly labeled as video-derived, with local blob mappings; they are not
original XCTest screenshot attachments. No image uploads or blob commits.
Owned simulator was shut down/deleted and build/test processes drained.

The successor fixes the fixture flag and actual Attach label target, captures
screenshots before geometry checks, and checks enabled typed controls/Send/
dismissal for hittability and full unobscured app/keyboard bounds. It invokes
dismissal and checks keyboard/focus exit with text and image draft retained.
Existing empty Send semantics, test timeouts and retry policy remain intact.

The target/test successor at `95e1e599` and the subsequent adaptive successor
have source-only validation: `swiftc -frontend -parse` passed for all six changed
Swift files and `git diff --check` passed. No successor runtime
execution is authorized until allocated. Native editor identity through status
changes remains source-reviewed only. Missing preview errors are UI evidence,
not a transport spy: the reviewed Interrupt action only opens confirmation;
the unchanged parent dialog calls the store command only on explicit confirm.
No physical-device or live commands/tests were run.

No full accessibility usability claim follows from a 44pt AX frame. The
predecessor clips large approval decisions and squeezes the field in the actual
AXXXL frame. The adaptive successor needs allocated combined approval + image
plus multiline draft + keyboard screenshots and action checks. The old large
header may still consume space; its separately owned compact replacement must
also be assessed in the parent's final combined matrix. This work does not
modify or rebase the header, or overwrite the newly merged #312 focus probes.

## Adaptive source-review follow-up

The new Review and Dismiss buttons now put the actual 44pt frame/content shape
inside their labels. The sheet has no ScrollView container identifier that
could mask descendant identities; UI selectors use the title/queue StaticText
leaves, decision Button leaves and explicit Close button.

`CompanionComposerApprovalReviewSheet` is an internal View in the same composer
file, sharing its actual projection, Close and async response methods with
dedicated synthetic tests. Review selection contains both target and request
ID. The real card callback captures the original request ID and full option,
then its Task checks that live selection still matches the original target
and request and resolves the current approval immediately before calling the
existing `store.respond`. It does not remap an option by ID or alter shared
store permission gates. A stale callback cannot select another request/target
or reuse a resolved/removed request through a captured pending value.

`CompanionComposerApprovalReviewTests` adds bounded, network-free cases for
queue changes while the review binding stays open; resolved/removed requests;
same-ID changed options; Close before queued action; switched requests/targets;
one valid dispatch; pending duplicate disablement; and existing offline,
expiry/refusal/error behavior. It exercises the actual sheet methods with
synthetic store events and a service spy, without mounting or driving native
accessibility UI. These cases are added but UNRUN until allocated. Native
sheet navigation, editor identity and keyboard return remain separate runtime
limits. Frontend parsing of all seven changed Swift files and diff checks pass;
there are no timeout/retry configuration changes or new local runtime runs.

## Synthetic fixture ownership and teardown

The two test-only empty `nonisolated deinit` declarations have a concrete
ownership rationale, not a safety claim derived from exclusion from an app
binary gate:

- `ReviewFixture` owns a MainActor `CompanionStore` and the concrete
  `ReviewServiceSpy`, plus target/selection values and a sequence counter. Its
  Store constructor has no persistence or UI owner, never starts the listener,
  and uses synthetic approval/draft values. The sheet value is not mounted and
  owns only that Store and a Binding back to the fixture. All four construction
  sites immediately register MainActor `defer { fixture.tearDown() }` before
  throwing assertions. Teardown closes presentation, tears down the concrete
  spy and calls `store.stop()` on MainActor. The pending-task case explicitly
  tears down and awaits its response task before returning. Destruction then
  only releases the reviewed UI-free Store/spy references and value fields;
  it neither dispatches work nor invokes actor-owned callbacks.
- `ReviewServiceSpy` is **not** String-only: it owns a callback capturing an
  `XCTestExpectation`, and may own a `CheckedContinuation` retaining a suspended
  response task. Its explicit MainActor teardown clears the callback, turns
  off future response holds, removes the stored continuation and resumes it
  once. A late-starting task therefore cannot install a fresh hold after
  teardown. The pending case drains that task and checks callback/continuation
  release. No callback or continuation is invoked by deinit. Remaining stored
  fields are String/Bool/target response values; the spy owns no UIKit,
  hosting-controller, timer, delegate or network resource. Cleanup is
  idempotent, so the explicit pre-drain cleanup and deferred cleanup are safe.

This is an ownership review of these concrete captures/call sites. New owners
or callback captures require review; frontend parsing does not prove teardown
or runtime behavior. The tests remain unrun until allocated.

The same-ID cross-target test now also populates a real second target in the
synthetic Store, rejects the first target's old callback, and dispatches through
the second target's actual sheet method once. This positive control shows that
the negative selection check does not merely reject an unavailable target.
