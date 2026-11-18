# #582 FD-r2: native destination still paints the wrong window — HARD STOP

Exact source `7c12e00df771f150e60b5b0c1084ea0ad8cc9ba9`, product experiment `9169903e3`, recording-only repairs `7c12e00df`. QA statically accepted this exact delta and A900 → one F1 recording. No product edit or further test invocation follows this result.

## Decisive result

The fresh build/deinit gate/20 policy tests pass. The ONE native F1 UI method also passes, reaches every scenario, and preserves its six-point final-return checks. **The first-frame video gate FAILS.** A passing eventual AX assertion is not first-frame acceptance.

On the native navigation destination reopen, the first destination transcript frame shows **Reading marker 1**, not the saved region. Marker 1 remains visible at encoded presentation times **41.243333, 41.275, 41.295 and 41.310 seconds**. The first encoded marker-90 frame is **41.316667 seconds**. This is a visible top-of-window → bookmark jump over a 73.333ms presentation interval. A precise encoded-frame extraction refines the initial coarse report (which first sampled 90 at 41.33s).

Unaltered full-frame witnesses:

- `destination-encoded/frame-0000-41.243.png`: marker 1.
- `destination-encoded/frame-0003-41.310.png`: marker 1.
- `destination-encoded/frame-0004-41.317.png`: marker 90.
- `destination-encoded/frame-times.json`: requested and actual times for every frame extracted in the decisive interval.
- `destination-encoded.jpg`: analysis-only crop/contact sheet; the full PNGs and full original video remain authoritative.

The encoded timeline was enumerated through AVAssetReader: 2,150 finite presentation samples, two invalid-timing samples reported rather than invented. The unchanged native decoder then requested every finite presentation timestamp in the decisive interval; its actual times are preserved. The recording is variable-rate, not a presumed 60fps sequence.

## App timeline

The destination's first body seeds canonical ID `message:reading-89` (the previously captured anchor) in an expanded window beginning at marker 1. Its cached saved distance places visible marker 90 at the final reading location. The synchronous onAppear request does execute once, but native offset remains near zero until product A's numeric correction. This distinguishes a real positioning failure from a missing request.

| Event | App epoch time | ID / geometry |
|---|---:|---|
| Destination first body | 1795027794.191165 | ID89, window first1 |
| First geometry | 1795027794.293694 | offset0, ID89 lower8508.666667 |
| Synchronous opening request | 1795027794.293834 | ID89 held |
| Further geometry | 1795027794.452484 | offset≈0 |
| Existing A numeric correction | 1795027794.456632 | point8605.333333, ID released |
| Geometry after command | 1795027794.471789 | offset8605.333333 |
| Arrived / saved | 1795027794.508980 / .509010 | restored final reading location |

`opening-stdout.txt` and `opening-timeline.json` preserve all events from every mount. Recording-start wall-clock bracket is 324.123ms (command1795027752.912968, observed-start1795027753.237091). We do not invent an exact log/video synchronization inside that bracket; the visible identity transition is decisive independently.

## Reached controls and limits

All planned scenarios were reached in the ONE UI execution, including native reopen, opposite-state target switches, Latest isolation and the real user-owned drag/tail update. No skip, expected failure, repetition or assertion edit occurred.

- The initial expanded paused mount now first shows marker90 (first encoded paused frame22.423333), rather than marker1. This improvement does not excuse the destination failure.
- Retained-tab return first shows the canonical captured marker89, then the existing fractional correction moves to visible marker90. The same pattern appears on the return-to-paused target switch. This row-level/fractional distinction is disclosed, not classified as a new acceptance exception.
- The other paused target and latest controls were reached. No overall first-frame acceptance is claimed, because the destination counterexample already triggers the pre-decided stop.
- N's earlier zero-numeric-command test was NOT rerun or weakened. H/S/CPU/broad/combined coverage did NOT run on this head.

## Cleanup

FD-r2 completed in121.62s, script/test/auditor rc0; video rc0,47,151,484bytes. Owned simulator `8876542F-BAE7-45F6-A527-1898E61566A6` shut down and deleted, UUID absent, system-wide0Booted. Owned process group empty, swap growth0. The read-only decoders subsequently exited. Host released; no build, test or simulator is queued.

## Required decision (no implementation)

**Option A: start the initially rendered window at the canonical bookmark.** The saved entry would be the first loaded row, so opening does not depend on native scrolling across the earlier loaded prefix. Older history would remain behind an explicit Show earlier messages action. This changes the expanded-window contract: scrolling upward immediately would no longer expose all earlier loaded rows without that action. It needs the user's UX decision, a new reviewed window/first-frame contract and proof. It is a candidate design, not a promise of first-frame success. Pixel restoration, missing/removed-ID fallback, Latest, history expansion and CPU would still need exact-head validation.

**Option B: do not ship #582.** Leave #584 draft and preserve the findings; retain the currently shipped delayed bookmark correction from #569, with its known opening jump. No new code or acceptance is claimed. This is the safe default until a changed history-window UX is explicitly approved.

No timing iterations, extra onAppear tricks, hidden paint, guessed offsets, assertion relaxation or UIKit introspection are proposed.
