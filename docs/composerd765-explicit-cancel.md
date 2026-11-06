# Explicit native Cancel for Interrupt

Base: `d765f06d9a0ae2ed664a1b69f5cae8d3534e17dd`. Dispatcher explicitly
authorized this intentional product affordance after independent artifact and
source-plan review. It does not establish that the previous app was globally
undismissable, or that this successor passes runtime or visual validation.

Only three files change:

- `Annex/Annex/Companion/Views/CompanionConversationView.swift`: Interrupt
  presentation only.
- `Annex/AnnexUITests/CompanionCompactComposerUITests.swift`: only the
  `cancelInterruptConfirmation` helper.
- This document.

Root owns header navigation, timeout configuration, final independent source
review and any execution allocation. No header, composer field, shared helper,
fixture/service, recovery, content, native diagnostic or ownership-policy edits
are included.

## Evidence retained

The original map `7bd4b6edbedf92f6a59e9ec46957d1486beda278` contains 163
path-keyed records and 32 original PNGs. Every record was materialized through
shared Git objects into this worktree's ignored artifact directory and verified
against its byte count and SHA-256. No original was changed or uploaded, and
no derived video frames were generated.

Original confirmation `7925927C-FF47-4671-9CBB-6FDE4DDF272A.png` is blob
`c24cabe35341a45bbad1dcc310fddf0940f576df`, 536495 bytes, SHA-256
`b926c43931bc29ffcbae8d44196fcc404707de3fae1a50d77c4d592bc0416fa2`.
The retained diagnostics show Cancel absent, one expected popover, one native
dismiss region, and an existing destructive action. Actual region/window was
`(0,0,375,667)`, popover `(18,30,339,367)`, and conversation viewport
`(0,74,375,333)`. Available conversation-side dimensions were 18/18/0/10,
so the unchanged >24pt side rule correctly found no point there.

The native-region fallback chose `(187.5,532)` from the larger lower side.
Original synthesized event `04F0C70C-E160-4307-AB1E-5348D4513F27` records
that exact point for both touch-down and touch-up. It was outside the popover
but inside the recorded keyboard `(4.5,451,366,216)` and inputView
`(4.5,407,366,260)`. It was below the assistant frame, which ended at 451.
Region-wide hittability did not prove ownership of that particular coordinate.
The PNG shows keyboard onboarding content; it does not prove that the keyboard
consumed the touch, and no Continue action was recorded.

The original five-second disappearance check failed after that one tap.
The title remained exported at all recorded polls; its false disappearance
short-circuited the destructive-action check. Post-tap archives/descriptions
contain only an app root with no children, so they do not supply exact resulting
pixels or touch ownership. Composer failed after 70.108 seconds. Remaining
post-cancel draft/image/noIO/refocus/dismiss assertions did not execute.
The parent reports Debug/binary gate passing and UI 1/3, including Dark header
passing. Earlier ordinary composer and recovery passes remain separate evidence.
There is no inferred pass, new execution or original-receipt rewrite here.

## Intentional presentation contract

Interrupt now uses a native alert with the same `confirmCancel` binding,
title and explanatory message. Its destructive Button and
`Task { await store.cancel(target) }` closure remain byte-identical. An empty
`Button("Cancel", role: .cancel) {}` provides a semantic cancellation action.
There is no manual binding reset, store call, target/gate change, draft/image
mutation, field replacement, focus write or keyboard action on Cancel.

Apple's [confirmation-dialog documentation](https://developer.apple.com/documentation/swiftui/view/confirmationDialog(_:isPresented:titleVisibility:actions:message:))
describes outside dismissal instead of the standard dismiss action for popover
presentation. Adding only a cancel-role action there does not establish a visible
popover Cancel contract. Native [alerts support explicit cancel-role actions](https://developer.apple.com/documentation/swiftui/view/alert(_:isPresented:presenting:actions:message:)-29bp4).
This change deliberately chooses that explicit action for a binary Interrupt
confirmation. Actual accessibility export, button geometry, keyboard behavior
and dismissal still require separately allocated validation.

The test requires exactly one actual alert globally and one containing the
expected title. Inside it, title, Cancel and destructive Button counts must
each be exactly one before indexed retrieval. All three labels must match
exactly. Queried title/alert/Cancel frames and actual main/app intersection
must be finite and positive. The actual Cancel must be enabled, hittable,
at least 44pt in both dimensions, wholly inside the actual alert frame AND
the actual window before one direct semantic Cancel tap. The alert footprint
is queried, never guessed from screen or keyboard dimensions.

Counts, labels, frames and individual geometry/actionability predicates are
retained as activities. Missing/duplicate/unexpected labels, invalid geometry,
undersized/unhittable/disabled/outside Cancel fail before tapping. Interrupt's
coordinate/native-region fallback and its diagnostic adjunct are removed.
The outside-point, menu, viewport and coordinate helpers remain unchanged for
their other callers. No second tap, wait, scroll, keyboard Continue, field
focus or alternative dismissal action repairs failure.

The original final five-second combined title-and-destructive-action-gone
block remains byte-identical, as does every byte outside this helper. All
downstream draft/image/noIO/refocus/assistive-dismiss assertions, screenshots,
launches, waits, navigation allowances, 44pt minima and <=16 gap remain required.

## Ownership and affected-route matrix

ConversationView remains the same value-type view with the same stored fields.
The destructive closure retains its original store/target capture. The empty
Cancel closure adds no captured owner. No class, constructor producer, callback
registration or lifetime owner is introduced. The reviewed extractor fingerprints
the existing `CompanionStateLifetime { CompanionComposerMemory() }` constructor
in this file; replacing the presentation modifier does not alter that site.
Policy mismatches must fail source review rather than trigger a refresh.

| Route/state | Required acceptance |
|---|---|
| Ordinary working composer | Native alert, one scoped 44pt actionable Cancel, one tap, original disappearance and full draft/image/noIO/dismiss path. |
| Largest AX working composer | Same explicit cancellation checks after both approval-review states, plus all original row/editor/attachment thresholds. |
| Missing/ambiguous/invalid Cancel or alert | Fail before any cancellation tap; no coordinate fallback. |
| Cancel tap does not dismiss | Original five-second both-gone failure; no rescue. |
| Idle composer | Does not invoke Interrupt cancellation; source/case unchanged. |
| Destructive confirmation | Existing explicit action alone dispatches the identical store.cancel Task; it is never tapped in these cancellation tests. |

Both ordinary and largest-AX working methods are materially affected and need
separate explicit nomination. Prior ordinary success does not validate a changed
presentation. No additional method or run is automatically authorized.

Verification is cached source extraction, frontend parsing, diff and exact
source comparisons only. There is no binary gate, SDK typecheck, build, test,
simulator, provider probe or runtime/visual acceptance. Root must review the
frozen exact successor before combining or nominating validation.

Source verification passed: View frontend parsing with and without DEBUG,
test-file DEBUG frontend parsing, and `git diff --check`. The existing cached
extractor read all 137 production Swift sources without compilation: every
surface/capture result equals the pre-edit baseline, all 30 ARC-only surfaces
and all 11 capture-site file maps equal the reviewed policy. No policy refresh
was needed. Exact comparisons also confirmed the two production edits only,
the unchanged destructive closure/title/binding/message/gates, all test bytes
outside the helper, original launch/checked-tap/timeout/typeText lines and the
original five-second disappearance suffix. The helper contains one direct
Cancel tap and no coordinate dismissal path.
