# Compact chat

Mobile chat chrome for #314 (identity header), #315 (composer) and #322 (recovery status).

## Identity header

Like Messages, the navigation principal is the agent's canonical `CompanionAgentAvatar` (saved profile image, emoji or
initials, with its status dot) as a 50pt photo, centred over a small name pill with a chevron; in a short landscape
bar the photo shrinks to 30pt beside the pill. The whole control is one target of at least 44×44. The pill's text is
capped at the xxLarge size like other bar controls, with the Large Content Viewer at accessibility sizes. Tapping it
discloses a details card with the full name, desktop/project, status, Access and model. A known live level is the single
Access badge; boolean-only access reads "Auto or Full access" (#342). Status and Access are not shown permanently; the
identity's accessibility label still carries them.

An invisible, noninteractive leading reservation mirrors the trailing context control and spacer. The principal gets an
explicit symmetric width budget for the context control, menu, spacer, bar margin and gap; a maximum alone still lets
the system use the long name's intrinsic width. Long names truncate instead of shifting the identity left;
the disclosure and accessibility label retain the full name.

The transcript scrolls under the floating controls with the soft scroll-edge effect; there is no band under the bar.
The pill may hang just below the bar, so the top bar adds 8pt of clearance: status rows, banners and the first message
start below it, while scrolled content passes beneath.

The name pill, the usage control, the details card and the composer draw their glass behind the content, over the
theme's opaque card, and use its label colors. Bare glass took on the brightness of whatever scrolled behind it (white
labels fell to about 1.5:1 in dark mode), and content inside a glass effect is restyled, which dimmed avatars. The
palette keeps label and secondary label at 4.5:1 or better against the card, with Reduce Transparency and Increase
Contrast too. The draft's keyboard follows the system appearance.

The details card and the other-agent banner share one top `safeAreaBar`. `CompanionConversationHeaderBarLayout` caps the
card at a third of the height left above the composer, and taller details scroll inside it. When less than 100pt
remains (landscape with the keyboard up), expanded details aren't shown at all and VoiceOver says why; they return when
there is room. Working/activity moved to a one-line footer above the composer, and idle chats reserve no footer.

The usage control in the navigation bar (a context ring, or a chart icon when context is unknown) is at least 44×44 and
opens the existing context editor. Its sheet always offers "Plan limits by desktop", which opens the unchanged plan
limits screen. Context has no timestamp, so the sheet says "Latest reported context usage" or "Context usage unknown",
and notes when the desktop is unavailable. Nothing polls quota because a chat or the sheet opened.

## Composer

The draft keeps a full-width row above one action row. It grows to 8 lines; at accessibility sizes it shows 3 lines,
and 1 while editing so the keyboard leaves room for the actions (the field scrolls to the caret). The action row has chat controls and Attach
on the left, Interrupt and Send on the right. Chat controls (permissions, model, effort) are always the collapsed menu,
whatever the focus or Working state. Interrupt uses the warning palette, sits beside Send rather than replacing it, keeps
its confirmation, and is disabled under the same capability/connection/pending rules. The redundant "Your direction
will be sent to the running agent." caption is gone; Send's accessibility hint says what sending does. Queue-only,
offline and loading explanations stay.

When the session and saved model are distinct exact choices in the live model catalog, the Model submenu shows
"Session: <model>" and "Saved: <model> (next start)". Agent settings labels the same two values Session and Saved.
Equal IDs, unresolved defaults, missing values and unlisted alias/full-ID pairs keep the single Model UI.
Labels are presentation only, never identity or an alias table. Saved settings are read only for a visible live
conversation with a listed model, an enabled model menu and the existing durable-settings/connection capabilities;
read failures and a retry stay inside the submenu. Successful phone saves invalidate the per-target read; catalog
changes to the saved model/provider and Dispatcher settings invalidate it too, independently of the live model.
An open Agent settings form uses the same revision and saved-model identity to refresh its baseline and
comparison without replacing unsaved Name or Emoji text, including edits made while the read is in flight.
While that baseline is stale, Session/Saved comparison rows are hidden. A failed refresh keeps the form and
drafts visible with an error and Retry, rather than continuing to display an outdated model difference.
Model's status lines stay together in its section header; no global menu ordering is imposed, so Permissions
and Effort retain their existing ordering.
No rows are added to the collapsed composer.

The pinned desktop contract (`8bd00f0c`) does not export its renderer's `startModel`. Full desktop parity needs
`MobileChatControls.startModel: string | null` in `src/shared/mobile-control.ts`, emitted by
`src/main/services/mobile-control.ts`'s `chatControls(events, caps)` in the chat snapshot/page's `chatControls`.
It must mirror the desktop chat store: reset to `session_started.model ?? null`, fill an unset value from the
first non-null `session_info.model` or `model_changed.modelId`, and preserve it across later model changes.
Go must not infer it from
whatever bounded history happens to arrive. Comparing `model` to that field would reproduce the desktop's
`sessionModelLine` gate for alias/full-ID cases; it would not resolve a saved provider-default model by itself.

The slash menu uses the remaining keyboard-safe height after the fixed composer controls, activity line and a readable
44pt transcript band. Its commands keep 44pt targets; when the full list will not fit, it scrolls without dismissing the
keyboard. Hardware-keyboard highlighting scrolls the selected command into view. Larger windows keep the complete list
when there is room.

With less than 360pt above the keyboard, the composer reduces its padding and gaps, not its draft text size or 44pt
action targets. This also keeps an eight-line draft, pinned approval and actions inside a small phone's visible region.
Accessibility text sizes retain the 10pt outer inset so the larger glass approval control stays clear of the keyboard.

In windows narrower than 390pt, the transcript reserves only the clearance needed for visible jump buttons, keeping them
clear of the newest item's controls. The end spacer chooses during measurement from its offered width plus the transcript's
outer insets, not from a post-layout state update. Zero or unspecified width uses regular clearance; the first real SE3
placement is already compact, and keyboard presentation does not change the width breakpoint. Combined with the compact
composer, this keeps the latest streamed text readable alongside a trailing tool card. Larger windows keep their existing
scrollable clearance; following and reading anchors do not change.

Keyboard/safe-area layout can publish a new bottom, then return to the preceding layout's offset in a separate
same-dimensions sample (#384). The existing rollback exclusion covers container and inset changes as well as content
height. UIKit's current bounds/insets also reject stale SwiftUI samples during concurrent layout, even if duplicate
pinned samples have displaced the before-last geometry. Unexplained upward geometry still pauses non-pan input once
the reported viewport matches UIKit; tracked pans and native status-bar delegation keep
their explicit paths. Opt-in Debug follow tracing exposes cumulative pause and deceleration audits, so transient false
pauses cannot be hidden by recovery before the next UI snapshot.

At accessibility text sizes the pinned Deny/Allow bar would squeeze the draft, so a prominent review button opens the
pending request in a sheet with the transcript's approval card. Opening or closing it sends nothing, and Allow goes
through the same `store.canApprove` gate and full-event review as the transcript (#345).

Clubhouse grant requests are separate cards pinned above the composer, not CLI approvals or helper requests (#357).
They show the same details, complete arguments, reason, Allow effect and offered answers as Needs you, through the same
`CompanionGrantRequestActions` and store answer gate. Full cards appear only when their measured height fits half the
space above the composer. Otherwise a compact pinned row names the requester and summarizes the request; Review opens
the complete, scrollable sheet without sending a decision. Decisions stack when their full labels cannot fit side by
side. The native draft scrolls to the caret when it must shrink to keep Review and the composer above the keyboard.
If a landscape keyboard leaves less room than the minimum footer, the footer scrolls with Review first.
Chats without pending Clubhouse grants use the ordinary composer directly, without the measured grant footer.
Answering on either surface removes the request from both.
Desktop-update grants keep the shared explicit Restart now / When idle choice before Allow once; stale-epoch rows
remain subject to `store.canAnswer`.
Open chat on a Dispatcher's grant switches directly to its retained Dispatcher tab instead of pushing a duplicate chat.

## Recovery status

`CompanionRecoveryStatus` classifies connection and conversation state, in this order:

| Connection | Conversation | Row | Action |
| --- | --- | --- | --- |
| connecting / reconnecting / synchronizing | any | Connecting… / Reconnecting… / Synchronizing… | Details |
| offline | any | Offline | Retry connection, Details |
| failed | any | Connection issue | Retry connection, Details |
| connected | loading | Refreshing conversation… | Details |
| connected | error | Conversation refresh failed | Refresh, Details |
| connected | needs resync | Conversation needs a refresh | Refresh, Details |
| connected | clean | hidden | — |

Progress is never inferred from a resync flag or an error, and offline/failed never claim to be reconnecting even with a
history request in flight. Details shows the full connection and conversation errors together. The row replaces the old
large refresh panel and the in-transcript loading/failure views; it starts no work itself, and command gating is
unchanged. Retry actions are bound to the page that presented them, and Details closes when that page changes target or
becomes inactive. Operation warnings and the wrong-machine notice (#350) stay separate.

Recovery uses an inset, rounded card-glass surface rather than a full-width tinted strip. The navigation background
stays explicitly hidden even when the status row separates the transcript from the bar. Progress and refresh icons
are vertically centered with the headline in both the single-row and wrapping layouts, in light and dark appearance.
