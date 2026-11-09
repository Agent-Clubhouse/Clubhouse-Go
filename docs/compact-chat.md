# Compact chat

Mobile chat chrome for #314 (identity header), #315 (composer) and #322 (recovery status).

## Identity header

The navigation principal is the agent's canonical `CompanionAgentAvatar` (saved profile image, emoji or initials, with
its status dot) beside its name, in a native glass capsule with a 44×44 target. Tapping it discloses a details card with
the full name, desktop/project, status, Access and model. A known live level is the single Access badge; boolean-only
access reads "Auto or Full access" (#342). Status and Access are not shown permanently; the identity button's
accessibility label still carries them.

The details card and the other-agent banner share one top `safeAreaBar`, so the transcript gets the system scroll-edge
effect instead of an opacity panel. `CompanionConversationHeaderBarLayout` caps the card at a third of the height left
above the composer; taller details scroll inside the card. Working/activity moved to a one-line footer above the
composer, and idle chats reserve no footer.

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
