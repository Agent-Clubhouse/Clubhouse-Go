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

At accessibility text sizes the pinned Deny/Allow bar would squeeze the draft, so a prominent review button opens the
pending request in a sheet with the transcript's approval card. Opening or closing it sends nothing, and Allow goes
through the same `store.canApprove` gate and full-event review as the transcript (#345).

Clubhouse grant requests are separate cards pinned above the composer, not CLI approvals or helper requests (#357).
They show the same details, complete arguments, reason, Allow effect and offered answers as Needs you, through the same
`CompanionGrantRequestActions` and store answer gate. The cards use at most half the space above the composer and scroll
when needed, including at accessibility sizes. Answering on either surface removes the request from both.
Desktop-update grants keep the shared explicit Restart now / When idle choice before Allow once; stale-epoch rows
remain subject to `store.canAnswer`.

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
