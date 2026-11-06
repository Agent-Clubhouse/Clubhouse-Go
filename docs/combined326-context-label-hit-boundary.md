# Unapplied context Button label hit-boundary proposal

Status: exact SOURCE-ONLY candidate against frozen
`dfb6f4c13196f0ca3f1d70d266ceb8cc37b20dda`. No tracked application, source branch
change, Swift parse, typecheck, build, test, simulator/app probe, commit or push.
Root retains independent review, Dispatcher allocation and runtime/visual review.

## Scope and evidence boundary

Only proposed Swift change is inside `contextButton` at
`Annex/Annex/Companion/Views/CompanionConversationView.swift:227`.
Proposed doc path: `docs/combined326-context-label-hit-boundary.md`.
No test, Retry, recovery, identity, toolbar caller, composer, transcript, shared
support, fixture, timeout, policy or other source changes are included.
Dispatcher application and #327 original-pixel work remain root-owned.

Parent's exact #326 CI query block identifies the native CONTEXT Button as
`(272.6666666666667,66,55.33333333333331,36)`. The failing assertion is
`CompanionChatHeaderUITests:29`, context height >=44. Identity's independent44
checks at25–26 passed. Context width/hittability preceding29 also passed;
this does not establish the minimum height or completed usage navigation.
Do not relabel this as the identity failure or replace the native Button's
rectangle with a ring/outer wrapper rectangle.

At dfb6 the context Button label is the conditional ring or caption Image.
Its44pt minimum frame currently wraps the Button OUTSIDE the label, and the
control occupies a topBarTrailing ToolbarItem. Unlike main814's former in-content
context control, it has no explicit plain button style. This distinguishes
allocation, concrete label and styled native-control boundaries; it does NOT
prove which framework layer exported36 or guarantee a remedy.

## Exact proposed modifier change

Inside the existing Button label, place the EXACT existing ring/Image conditional
in one concrete `HStack(spacing:0)`. It contains exactly one selected branch,
no Spacer, padding, font, alignment override, tint or style change. Apply
`.frame(minWidth:44,minHeight:44)` and `.contentShape(Rectangle())` to THIS
concrete label container. Retain the original OUTER Button frame unchanged.

The original `CompanionContextRing(percent:)` expression and fallback
`Image(systemName:"chart.pie").font(.caption)` expression remain unchanged
apart from indentation. The ring's own font, internals, label and ID are not
edited. The new container receives no additional AX ID, accessibility element
modifier, hidden leaf, label or value.

Preserve byte-identical Button action `showContextSettings = true`, all outer
modifiers in order (min44, exact label, reported/unknown value, hint, conditional
usage/settings ID), surrounding gates/state/sheet behavior and toolbar's native
style. Do not restore `.buttonStyle(.plain)`, impose controlSize, change glyphs,
add padding, add an offset, normalize a rectangle or alter the strict44 test.
This is an authorized label-level hit-boundary proposal, not a style-only remedy.

## Source checks and future acceptance limits

Replacing ONLY the candidate contextButton property with the original recovers
the complete dfb6 ConversationView bytes. Reversing the sole HStack/frame/shape
hunk likewise recovers the original property. All source before/after it and the
entire original outer modifier suffix remain byte-identical. The action is
identical and no stored field, owner, recovery callback, service, constructor
capture site, authorization gate or lifecycle path is added. No ownership policy
refresh or executed ownership-gate result is claimed.

The known-usage ring, unknown-usage icon and Review's selected context control
share this property. Future separately allocated evidence should identify the
actual unique actionable Button by the existing exact label/value/ID in its
navigation ancestry and retain its screen-space width/height, enabled/hittable
state and original pixels. Known usage must keep the exact reported percentage;
unknown usage must remain explicit and plan limits/context actions must retain
all original semantics. Existing strict44 thresholds and downstream assertions
remain unchanged. A new wrapper/label size alone cannot establish native Button
size, hit ownership, accessibility role/cardinality or action success.

No native export shape or future44pt pass is guaranteed by source. The concrete
label container may affect framework layout/AX ancestry and therefore still
requires exact runtime/visual review; unchanged content expressions do not prove
unchanged pixels. Failure must remain a failure with original evidence, not a
selector fallback or substitute-node acceptance. No test is run by this proposal.

Recovery Details Retry remains separately blocked on parent/label/native mapping.
Its existing inner-label44 and42.24875621890544 native measurement are untouched;
no common-cause inference, normalization, tolerance or style remedy is proposed.
All prior checkpoints, Dispatcher proposal, #327 evidence and tracked dfb6 remain
frozen in this worktree.
