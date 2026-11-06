# Chat header glass and space

## Evidence and source diagnosis

Parent-triaged Framebriar reports `73e0e7c1` (2026-11-06 04:42:18Z) and
`3c1fef9e` (2026-11-06 04:46:05Z) both report main `b17f9f80`, installed build 218,
in the same session. The older Working capture marks the boundary below the
permissions/context row as too much lost space and asks for an iMessage-like
glass background. The newer Done capture is the compact composer reference.
Original images remain local in ignored build output; none belong in commits
or issue/PR attachments.

At that revision, `contextHeader` is an ordinary stack preceding the transcript.
The top `safeAreaBar` contains only the other-agent banner. The context button
already reserves a 44-point interaction target, while the activity line adds
height below that entire row. Working, approval, and waiting states can supply
activity; Done does not.

The minimized tab bar in the newer capture is a separate state: RootView uses
`tabBarMinimizeBehavior(.onScrollDown)`. Composer compaction follows composer
focus (or accessibility text size). Conversation keyboard notifications only
control its accessibility header fallback. These sources identify independent
inputs; the captures do not establish which interaction caused the observed
keyboard, focus, or tab states.

## Requested compact identity header

Mason's subsequent glass-chat reference supersedes the spacing-only candidate:
use the real Clubhouse identity beside the name, expand details on demand, and
remove persistent status/Free Agent text from the top. A slim worker/time
footer sits above the composer. A compact usage control opens context and
quota information. The reference image is also local-only.

The navigation principal is a 28-point canonical `CompanionAgentAvatar` beside
a single-line name and disclosure, in a native glass capsule with a minimum
44×44 interaction target. Its combined accessibility label retains agent
context/status/permissions even when the visual details card is collapsed.
The full name, host/project, status, permissions and model appear in the
natural-height card below when requested. Canonical avatar resolution/cache
handles custom image references and version changes; this component adds no
image requests of its own.

The card and existing other-agent banner share one top `safeAreaBar` with
zero spacing. The transcript uses the native hard top scroll-edge effect,
matching its bottom treatment. The worker/activity footer joins the existing
bottom bar above the composer. Idle chats reserve no activity line.
Apple documents that [`safeAreaBar`](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:))
adjusts safe areas and extends affected scroll views' edge effects;
[`scrollEdgeEffectStyle`](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:))
configures their native style.

The usage control always has a 44×44 target, including when context is unknown.
Its sheet wraps the existing context-focused agent settings form. A separate,
always-reachable “Plan limits by desktop” link opens the unchanged plan limits
screen even if settings fail to load. There is no quota fetch or polling merely
because the chat or context sheet opens.

Context has no timestamp; wording is “latest reported,” absent means unknown,
and offline values may be out of date. Quota identity is `(hostID, providerID)`,
with no account association. The existing plan limits screen groups all paired
desktops and owns capability/version/connection checks, clock age, desktop
stale/unknown readings, retained readings after failed refreshes, and polling
lifetime. Saved routing decisions remain historical. The header never infers
quota readiness from provider/CLI presence or Auto eligibility.

Connection/provider/sleep notices, operation errors, pinned approval actions,
reading anchors and navigation controls retain separate behavior. Keyboard
and focus handlers are unchanged. The existing accessibility keyboard rule
still compacts the other-agent banner; the default header has no permanent
status row to compact.

## Test plan and cases

Automated, dedicated `CompanionChatHeaderUITests`:

1. Open River with context reporting. Details start collapsed, disclosure opens
   and closes them, identity/usage targets stay at least 44×44, and activity is
   above the composer. Native scroll-to-top keeps usage pinned/actionable.
   Open the actual context editor/report, then desktop plan limits; unsupported
   quota capabilities remain explicitly unavailable.
2. At Accessibility Large, focus/type into the composer. Identity and usage
   stay reachable without a permanent status row. Open the context editor via
   the actions menu.
3. Open Dispatcher with no context usage. The control and sheet say unknown
   and still offer desktop plan limits.

Dedicated hosted `CompanionChatHeaderIdentityTests` render the actual header
with locally generated synthetic custom images: absent icon fallback, custom
image, new image version for the same identity, and return to absent fallback.
No unrelated images are fetched and no screenshot artifacts are attached.
The separate canonical avatar owner handles shared emoji/image precedence.
The test-only observable `HeaderIdentityFixture` owns one `CompanionAgent`
Sendable value and no callback, UI object or teardown action; its empty
nonisolated deinit is safe for that reviewed storage. The production ownership
gate scans `Annex/Annex` and the app binary, excluding `AnnexTests`, so this
fixture needs no shared policy entry or ownership-table change. No production
class or reviewed constructor/capture surface is added by this header.

Authorized shared test edit: only context label/value expectations in
`CompanionPreviewSmokeTests/testExploredFoldAndApprovalCardMatchDesktop` change;
its activity expectation stays intact.

Parent-owned simulator/visual acceptance, after the serial slot is available:

- Produce the combined screenshot package: keyboard up/down, narrow portrait,
  landscape, large accessibility text, light/dark, long names, Working and
  idle/Done. Show both collapsed identity and disclosed details with actual
  canonical identity. Inspect glass/scroll-edge readability as text passes
  behind the top, footer and composer; check for doubled top inset and ensure
  opening details while editing leaves a usable transcript.
- Exercise other-agent needs-you/error banners, connection/resync warning,
  operation error/dismiss, just-created notice, and pending provider/sleep
  notices. They must remain legible and actionable below the header, without
  overlapping the transcript or consuming duplicate safe-area spacing.
- Open/dismiss the keyboard with both expanded and minimized tabs; retain
  draft/focus and a paused reading entry. Check Previous/Next/Latest and native
  scroll-to-top with streaming, history prepend, navigation return, and review
  paging. Reuse reading/keyboard/context regression suites for those behaviors.
- Include the agent terminal path: header and banners remain available.

Current-region helpers requiring runtime review (no speculative edits):
`CompanionKeyboardDismissalUITests.transcriptPoint`, the safe-transcript helper
in `CompanionSlashCommandUITests`, reading viewport/marker geometry in
`CompanionReadingUITests`, and Dispatcher transcript drag helpers. The
`companion-chat-header` accessibility frame is now the navigation principal,
so tests must intersect actual transcript/composer/bar frames for usable space.
The identity button replaces no existing scroll view or reading anchor.

Review passes optional page-position metadata into the selected conversation's
identity control. That one principal includes its position subtitle and keeps
the existing exact `review-title` accessibility label. The Review parent owns
only the empty-state title; Done, filters, paging and settings are unchanged.
The dedicated Review-header case checks one principal, position after paging,
disclosure and the context-to-desktop-plan-limits route.

Validation is serialized by the parent. Source parse and whitespace/diff checks
can run independently; builds, tests, and simulator actions wait for its slot.
Source parse and diff checks pass. Full build/tests and combined visual
acceptance remain pending the parent's queue; old captures are not acceptance
evidence for this draft.

## Runnable synthetic visual matrix

`CompanionConversationHeaderFixture` is compiled only in DEBUG and selected
only inside the preview route when **both** `--companion-preview` and
`--companion-preview-header-fixture` are present. All values are canned; there
is no arbitrary host/name/image input or live desktop mutation. It seeds one
preview agent, a long readable transcript, context and the existing synthetic
quota service. A fixture-only photo menu switches locally generated solid
magenta and green profile images through the canonical versioned icon cache.
The usual preview remains unchanged when the new flag is absent.

| Representative case | Exact extra launch arguments | UI sequence |
|---|---|---|
| Dark Working, standard text | none | Capture collapsed keyboard down; focus/type; capture keyboard up; disclose and capture expanded keyboard up. |
| Light Working, long name, Accessibility Large, **375pt viewport** | `--companion-header-light --companion-header-long-name -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL` | Focus/type; disclose; capture full screen; collapse and capture again. Long name is “Alexandria — release coordination and simulator validation.” |
| Dark idle, fallback/custom/new version and usage routes | `--companion-header-idle` | Capture fallback, use fixture photo menu twice (magenta then green), capture each version, tap usage and capture context editor, navigate to desktop plan limits. |

These three cases are implemented in `CompanionChatHeaderVisualUITests`.
Attachment names include the actual viewport width; running the long-name
case at another width does **not** satisfy the requested 375pt acceptance.
The methods exercise the real navigation stack, conversation, disclosure,
composer, keyboard and sheets. This fixture does **not** contain RootView or
tabs; parent integration smoke must separately cover tab expansion/minimizing,
review, banners, and the combined composer/avatar candidate.

After the parent grants the local serial slot, select the reviewed combined
candidate (header plus composer/canonical-avatar dependencies), record its
exact HEAD, and use a parent-owned simulator whose portrait viewport is 375pt.
Do not select an installed phone or a pre-existing live pairing. For example,
from that candidate's worktree, substituting the owned simulator's UDID:

```sh
mkdir -p build/chat-header-validation
git rev-parse HEAD > build/chat-header-validation/candidate-head.txt
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,id=<owned-375pt-iPhone-UDID>' \
  -derivedDataPath build/chat-header-validation/DerivedData \
  -resultBundlePath build/chat-header-validation/HeaderMatrix.xcresult \
  -only-testing:ClubhouseGoUITests/CompanionChatHeaderVisualUITests \
  CODE_SIGNING_ALLOWED=NO test
```

For cached `build-for-testing`, the parent may use its matching arm64 test
configuration and `test-without-building` instead. Record simulator model,
runtime and actual width with the candidate head. The test helper adds
`--ui-testing-fast` and portrait orientation; dark/light and canned status/name
are controlled by the fixed flags above. The app commands in this route use
the preview service and cannot contact a desktop. Generated screenshots and
results stay in ignored local build output for parent inspection; original
feedback images are never attachments or committed artifacts.
