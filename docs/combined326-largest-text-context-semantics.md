# Unapplied largest-text retained context semantics proposal

Base: frozen `dfb6f4c13196f0ca3f1d70d266ceb8cc37b20dda`. SOURCE-ONLY, unapplied.
Only proposed Swift delta replaces the obsolete ring-absence assertion inside
`CompanionChatChromeUITests.largestText(hidePreviewBanner:)`.
Proposed doc path: `docs/combined326-largest-text-context-semantics.md`.
No product, ring, toolbar style, shared helper, source application, Swift parse,
typecheck, build, test, simulator/app probe, commit or push. Dispatcher0103 and
other artifact/AX-placeholder lanes remain root-owned; no duplicate owner work.

## User-intended source contract

ConversationView's contextButton is unconditional when the conversation owns its
navigation actions, including while editing and at accessibility text sizes.
Known usage renders the existing ring; absent usage renders the existing Image.
The keyboard visibility state affects the independent compact other-agent notice,
not contextButton's presence. The user-authorized toolbar is available during
editing, so the old `ring yields its header row while editing` absence predicate
contradicts the intended behavior. No source ring hiding is proposed.

The known-usage `companion-context-usage` ID is already required by this fixture's
original pre-focus hittability assertion. The ring child independently shares
that ID, so requiring any-role uniqueness would confuse a leaf/wrapper with the
actual control. This proposal guards exactly one actual BUTTON globally and
exactly one under the unique actual navigation bar. It does not mask duplicates
with firstMatch or substitute ring/Other wrapper geometry.

## Exact proposed replacement

1. Keep every original surrounding assertion, launch argument, focus action,
   transcript/readable-height calculation, original full screenshot, safety
   labels, other-agent notice and original readable floor unchanged.
2. Replace ONLY the obsolete post-focus absence assertion with exact global
   context Button count1 and global navigation bar count1, logged and guarded
   before retrieval. Under that navigation bar require exact context Button1,
   logged/guarded before indexed retrieval.
3. Require exact label `Context and plan limits`, enabled AND hittable state.
   Read native Button and nav frames once; require finite positive non-null,
   non-infinite rectangles and WHOLE Button contained in navigation. Retain
   queried frames and finite predicate in an activity before assertion failure.
   Guard invalid geometry before containment; missing/ambiguous nodes fail.
4. Preserve byte-identical original Conversation actions → Context menu → context
   picker route and final picker hittability assertion. No new direct context
   tap, wait, focus repair, keyboard action, allowance or retry is added.

This semantic test proposal deliberately adds NO44pt assertion and no tolerance,
ceil, scaling or normalization. It can check the intended retained reachable
control on dfb6 while the independently reviewed context product44-label proposal
remains a separate slice. A native36pt Button is NOT relabelled a44pt success;
this test does not claim to validate that different contract. Existing strict44
checks in ChatHeaderUITests remain unmodified and unresolved independently.

Both public methods call this exact changed helper and are affected:

- `testLargestTextKeepsSafetyStatusAndControlsReachable`
- `testLargestTextWithoutPreviewBannerKeepsSafetyStatusAndControlsReachable`

The two methods retain their original with/without-preview distinctions and10/44
readable-height floors. Every byte outside largestText, including focus/record
helpers and all other cases, is unchanged. Replacing the new block with the
original single absence assertion reconstructs the full base file byte-for-byte.

Native export shape/identity, geometry, enabled/hittable state, menu route,
readable pixels and full behavior remain unexecuted by this proposal. Sequential
queries are not an atomic hit-test guarantee; no runtime pass, native44 sizing,
visual acceptance or current active Dispatcher result is inferred. All frozen
refs/original failures remain preserved pending independent exact source review.
