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

The principal has a symmetric width budget for two 44pt trailing controls, their spacer, the bar margin and a gap.
A noninteractive UIKit background measures the identity in the actual navigation bar and balances a hidden leading
button's reservation after layout: SwiftUI toolbar hosts have independent coordinate roots, and native leading controls
can differ in width at large text sizes. This changes layout rather than offsetting the pill outside the native title's
hit area. The reservation uses a hidden semantic button, not a bare color (which caused iOS 26 AX snapshot timeouts).
Context keeps a 44pt target and bounded bar typography; its full reading remains accessible and available in settings.
Long names truncate instead of shifting the identity left;
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

When the desktop's optional `chatControls.startModel` proves the live model moved from its opening model,
or the session and saved model are distinct exact choices in the live model catalog, the Model submenu shows
"Session: <model>" and "Saved: <model> (next start)". Agent settings labels the same two values Session and Saved.
Exact identical live and saved IDs never differ, regardless of the opening model or display labels.
An unchanged opening alias does not establish a difference from a saved full ID. Equal display labels omit the
next-start comparison, matching the desktop's `sessionModelLine` / `nowAndNextStart`. Missing or null `startModel`
retains the conservative catalog-only comparison; unresolved defaults and unlisted IDs alone prove nothing.
Labels are presentation only, never an alias table. Saved settings are read only for a visible live
conversation with a listed model or known opening baseline, an enabled model menu and the existing durable-settings/connection capabilities;
read failures and a retry stay inside the submenu. Successful phone saves invalidate the per-target read; catalog
changes to the saved model/provider and Dispatcher settings invalidate it too, independently of the live model.
An open Agent settings form uses the same revision and saved-model identity to refresh its baseline and
comparison without replacing unsaved Name or Emoji text, including edits made while the read is in flight.
While that baseline is stale, Session/Saved comparison rows are hidden. A failed refresh keeps the form and
drafts visible with an error and Retry, rather than continuing to display an outdated model difference.
Model's status lines stay together in its section header; no global menu ordering is imposed, so Permissions
and Effort retain their existing ordering.
No rows are added to the collapsed composer.

The pinned desktop contract (`8c0029a1`) exports optional `MobileChatControls.startModel: string | null`
in v1 chat snapshots/pages. The desktop folds the full session to produce it; Go never infers it from
whatever bounded history happens to arrive. Live model changes preserve the authoritative baseline;
a new session/run clears it and requests one current-chat page with a one-event limit for a previously loaded
target. The response supplies only the authoritative baseline and cannot replace newer live models/lists.
Session/run, history-read and host-connection keys discard stale replies. The connection key changes on transport
disconnect/reconnect and resync events, even when automatic reconnect retains the same event subscription;
duplicate connected snapshots on the same socket do not invalidate it. Missing/null baselines and failed reads
never start a retry loop; failures expose the existing conversation resync/Refresh path.
A moved session can name a saved full ID
or "Default model" for the next start without guessing the provider's resolved default.

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

Pending CLI approvals and structured questions share one bounded card above the composer (#387). The oldest request
appears first by its request timestamp, with transcript-order ties, including older requests recovered outside a history
tail. Undated legacy requests retain transcript order ahead of dated requests. Previous/next controls and a request
position select one item, never a growing stack. Submitting stays
in the same queue until the store settles it. Ordinary-height cards offer the existing one-off decisions and More for
lasting options, with the same confirmation and full-event Allow gate (#345). Compact-height and accessibility text
use Review instead of squeezing decision labels beside the draft. A short keyboard-safe footer (less than 360pt)
also forces Review even for a one-line draft, so small phones use the compact form with the keyboard up.
Review reuses the complete scrollable approval
sheet or question card; opening/closing it sends nothing. VoiceOver announces newly pending requests.

Inline requests remain readable history, without duplicate actionable decisions. Show in chat reveals the original
request, loading its transcript window when necessary; this explicit navigation pauses following. Tray arrival,
removal, and height changes are only container/inset changes, not reading intent. All response callbacks bind the
target, desktop epoch, session, and exact presented request, and retain the existing reconnect/explicit retry guards.
An answer on another device settles the same retained history item and removes it from the pending queue. Selection
stays on its request when other requests settle, falling back to the oldest when that selected request settles.
Desktop parity follows Agent-Clubhouse/Clubhouse#3472 (`7ea65d7a`); the phone intentionally uses only `i of N`, not a second `N pending`
line, and history remains read-only instead of desktop's expandable Answer here actions. Compact Review and the label
Show in chat are the native phone equivalents of desktop's bounded card and Show in conversation.

Clubhouse grant requests are separate cards pinned above the composer, not CLI approvals or helper requests (#357).
They show the same details, complete arguments, reason, Allow effect and offered answers as Needs you, through the same
`CompanionGrantRequestActions` and store answer gate. Full cards appear only when their measured height fits half the
space above the composer. Otherwise a compact pinned row names the requester and summarizes the request; Review opens
the complete, scrollable sheet without sending a decision. Decisions stack when their full labels cannot fit side by
side. The native draft scrolls to the caret when it must shrink to keep Review and the composer above the keyboard.
The combined footer's order is **Clubhouse grants, selected CLI approval/question, activity, composer**; a pending
agent's redundant "Waiting for approval" activity line is omitted while its request is shown. It reuses
the original two concrete requests/composer layout slots. Grant and decision cards share the available request budget;
compact controls retain 44pt targets. If a landscape keyboard leaves less room than the minimum footer, that footer
scrolls rather than overlapping controls. The composer stays mounted even as requests arrive or disappear; without
requests the same layout preserves the ordinary composer's transcript clearance.
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
