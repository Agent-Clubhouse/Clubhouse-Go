# One bounded native Cancel content navigation

Base: `d944c2f7c8cf90433feb04dfa4f2fbd70d5cc89a`. This implements the
independently reviewed proposal `cc33463e63ff840f6bb6e48574abf88ed6fd22b5`
under Dispatcher's explicit test-only source authorization. Only
`Annex/AnnexUITests/CompanionCompactComposerUITests.swift` and this document
change. Root owns independent exact review and any later allocation. Product,
header, recovery, shared support, native diagnostic, timeout and policy source
remain unchanged.

## Retained evidence

Initial local map `c9b5956e0ed9fb646459ca18cd213b7ba44e716f` has 122 records,
including 35 original PNGs. All records were materialized through shared Git
objects into this worktree's ignored artifact directory and verified against
recorded bytes and SHA-256. Its full 53967689-byte runtime log matches blob
`8a3b5a970aa1433c8cbda83bc779e27a3c3e0645`. Final map
`60db6ce2b208f0883cb6c76b6fe2c1d2aea3a817` has 125 records and leaves every
original attachment record unchanged. Its successor validation record and
added post-run identity/gesture summaries do not replace original media.
No original was edited or uploaded and no derived image was generated here.

The Largest AX confirmation PNG `6004D4C0-A499-4B80-AFD3-5C33D754C388.png`
is blob `f8d6c11eeafa7b8ee64b812d3ead40de315cb674`, 423949 bytes, SHA-256
`9606efb28faae91fa7461a856c572ab08d3cd5bcf356feb5d4ae6bff97abb034`.
It shows a visible Cancel label with its lower action surface clipped by the
alert edge. Actual Cancel `(34,555,307,125.5)` ends at 680.5, beyond alert
`(18,34,339,619)` ending at 653 and window ending at 667. The two whole-frame
containment predicates failed; unique labels/counts, finite frames, 44pt
minima, enabled and hittable checks passed. No Cancel tap or alert-navigation
gesture occurred. This was a 63.288-second failed method, with all original
post-cancel disappearance/draft/image/noIO/refocus/dismiss assertions unexecuted.

Ordinary confirmation PNG `20E21CAB-DC26-46CE-A8C4-B7981653CD7D.png` is blob
`2160f42938a1fd022a2087c480fac48d0f8ad93d`, 436373 bytes, SHA-256
`8ffe75fe922c97757e579bea2483f8a43b3c613c0b97d11ba64ccb0de077d861`.
Cancel `(43.5,375.5,140,48)` was wholly inside alert
`(27.5,247.5,320,192)` and the window. One semantic tap and the full original
downstream path passed in 35.713 seconds. That pass remains separate evidence
for the earlier zero-navigation source, not a pass for this successor.

Filtered runtime query paths repeatedly put Cancel in an action ScrollView
separate from the title ScrollView. They do not prove full-tree uniqueness.
No action scroll frame/usable clip was queried, so the existing evidence does
not prove its height, scroll range, button fit or one-drag sufficiency. Native
hittability's visible point is not whole-button visibility. Observed clipping
is not proof of user-level inability to scroll or dismiss the alert.

## Source boundary and failure gates

One private `revealCancelIfNeeded` preflight and one guard are added before
the otherwise byte-identical `cancelInterruptConfirmation` body. Its local
read-only geometry function obtains current public queries for each phase;
it performs no wait or UI action. The unchanged original helper runs afterward
with fresh queries and retains its one semantic Cancel tap and original
five-second combined title/destructive-action disappearance check.

Preflight first requires one actual alert globally, one expected title-containing
alert, one scoped exact-label Cancel, and finite positive actual Cancel/alert/
main/app/window frames. If Cancel already fits wholly inside alert and window,
it returns with zero gestures BEFORE querying an action ScrollView. The passing
ordinary path acquires no new scroll prerequisite. Its original label/44/
enabled/hittable/containment checks still run unchanged afterward.

Only overflow requires exactly one Cancel-containing native ScrollView under
the actual alert. It guards count before indexed retrieval; neither a global
first scroll nor the sibling title scroll substitutes. The queried scroll
frame must be finite and its intersection with actual alert and main/app window
must form a finite positive clip. Missing, duplicate or invalid geometry fails
before movement. Nothing uses screenshot dimensions or a guessed modal clip.

The actual target must fit horizontally and in clip height, start no higher
than the clip and overflow below its bottom. Positive finite displacement is
target midpoint minus clip midpoint. It must fit a single gesture's endpoint
budget inside the measured clip inset by 12. Both endpoints must also be inside
clip, alert and window. No displacement cap or guessed position makes an
unsupported target eligible. Above/sideways/oversized/invalid geometry fails.

There is at most ONE upward content drag, with velocity from actual endpoint
distance divided by a nominal one second, initial press 0.05 and terminal
contact hold 0.2 in that same gesture. These parameters do not promise delivered
timing or native movement. No second gesture, reverse motion, focus/keyboard
action, timeout change or tap retry repairs failure.

Immediately after the gesture, the existing screenshot mechanism captures a
new original post-navigation PNG BEFORE later queries or assertions. Then
fresh unique alert/Cancel/action-scroll queries and actual frames recompute
the clip. The whole Cancel must be inside this clip, alert and window, at
least 44pt in both dimensions, enabled and hittable. Otherwise preflight fails
before a tap. Success merely proceeds to the original, unchanged helper and
its independently re-read predicates. It never counts a skipped assertion
or a partially visible action as accepted.

Activities retain phase-specific counts, exact label, all actual frames and
finite predicates, scroll/clip, target-fit/below/displacement predicates,
endpoint budget, actual endpoints/velocity and post-navigation acceptance.
These new measurements cannot reconstruct the unqueried earlier scroll frame.
The original pre-cancellation screenshot remains at its original call site.

## Acceptance matrix and limits

| State | Required behavior |
|---|---|
| Already contained Cancel | Zero gestures, no action-scroll query; original cancellation checks/tap. |
| Below-clip overflow, unique valid scroll, whole target fits and displacement fits | One measured upward drag, post-navigation original image and fresh full acceptance. |
| Missing/duplicate/invalid/above/sideways/oversized/unreachable geometry | Fail closed before navigation or tap; no alternative viewport. |
| One drag insufficient or action no longer unique/actionable | Fail with current image/values before any Cancel tap. |
| Preflight succeeds | Original one semantic tap, five-second both-gone and all draft/image/noIO/refocus/assistive-dismiss assertions. |

Only ordinary working and Largest AX working methods are affected; both require
an explicit future nomination after root's exact source review. Idle and every
case body remain unchanged. All launch/checked-tap attempts, existing waits,
44pt minima, <=16 action gaps and captures are preserved. Header/recovery passes,
earlier failures and original/runtime timeout receipts remain separate evidence.

Validation is frontend parsing, exact source equality and diff checks only.
No SDK build/typecheck, test, simulator, live/provider probe or runtime/visual
acceptance is authorized here. If the native clip or fit cannot be established
at runtime, this source must fail closed; no future pass is guaranteed.

The changed test file passed `swiftc -frontend -parse -D DEBUG` and
`git diff --check`. Exact reconstruction confirms only the new helper and one
leading guard differ from the base; the original cancellation body and every
other existing source byte are preserved. Original assertion, launch,
checked/direct-tap, timeout and typing lines are identical. The new helper
contains one nonlooping press and no tap/wait/retry; its contained route
precedes the action-scroll requirement. Production, policy and shared support
have no diff.
