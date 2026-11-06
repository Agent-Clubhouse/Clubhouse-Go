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

## Bounded correction

Place the header and existing other-agent banner in one top `safeAreaBar` with
zero spacing. Give the transcript the native hard top scroll-edge effect,
matching its bottom treatment. Keep the shared background at the conversation
level: no extra opaque panel, custom blur, or additional safe-area inset.
Apple documents that [`safeAreaBar`](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:))
adjusts safe areas and extends affected scroll views' edge effects;
[`scrollEdgeEffectStyle`](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:))
configures their native style.

At fitting widths, status and activity share a leading stack beside the
unchanged context target. This saves the extra caption line when both lines
fit within that target's height. Preserve the vertical width fallback and the
existing accessibility keyboard fallback/context menu action. Notices,
connection/provider/sleep warnings, operation errors, transcript anchors,
navigation overlays, and keyboard/focus handlers retain their own behavior.

## Test plan and cases

Automated, dedicated `CompanionChatHeaderUITests`:

1. Open the preview River approval chat with context reporting. Assert status,
   permissions and activity remain visible; context retains at least a 44×44
   target; activity fits within the context row vertically. Native scroll to
   top keeps context pinned and actionable. Open its settings/report.
2. At Accessibility Large, check permissions and context before editing. Focus
   the composer and type; the existing compact header releases space while
   retaining permissions. Open Context through conversation actions.

Parent-owned simulator/visual acceptance, after the serial slot is available:

- Compare Working and Done with context/permissions/Free Agent Mode, short and
  long activity names, narrow portrait, landscape, and large accessibility
  sizes. When the normal layout fits, Working activity should not add a full
  row beneath the context target. Inspect native glass/scroll-edge readability
  as text passes behind the header; check for doubled top inset.
- Exercise other-agent needs-you/error banners, connection/resync warning,
  operation error/dismiss, just-created notice, and pending provider/sleep
  notices. They must remain legible and actionable below the header, without
  overlapping the transcript or consuming duplicate safe-area spacing.
- Open/dismiss the keyboard with both expanded and minimized tabs; retain
  draft/focus and a paused reading entry. Check Previous/Next/Latest and native
  scroll-to-top with streaming, history prepend, navigation return, and review
  paging. Reuse reading/keyboard/context regression suites for those behaviors.
- Include the agent terminal path: header and banners remain available.

Validation is serialized by the parent. Source parse and whitespace/diff checks
can run independently; builds, tests, and simulator actions wait for its slot.
Visual acceptance cannot be inferred from source checks or the two old captures.
