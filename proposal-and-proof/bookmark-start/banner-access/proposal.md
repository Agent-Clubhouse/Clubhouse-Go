> **RESCINDED / DO NOT IMPLEMENT OR RUN.** QA and the Orchestrator withdrew both the inset change and main comparator. Neither was coded/run. See the current [harness-only plan](../harness-r2/harness-r2-review-notes.md). The proposal below is preserved as unaccepted history.

# #582 pinned-banner access proposal — BEFORE product/harness changes or another run

Authority: Orchestrator t_mwmomzr7 authorizes fixing pinned-banner access within #582, subject to main attribution and QA static review. F-r1 remains STOPped at a971c9343. Nothing below is runtime-accepted. No correction has been coded.

## Evidence and cause boundary

The first paused content is canonical90 on initial/tab/native destination. The inline Show-earlier control is initially visible, then disappears under the River-needs-you banner after the normal38.333pt A correction. It stays covered and the native tap does not widen the cursor. A/B was not reached. Full video/PNG/actual PTS, stdout and cleanup: evidence/ux-582/runtime/f-r1/report.md.

Important refinement: native topInset is already180.333pt with navigation maxY116pt. Thus omitted native banner inset is still a hypothesis, not a proven cause. The default/native top edge and A's normalized entry alignment may differ in which inline header space remains visible. Padding inside the measured transcript is not proposed: A could simply increase its numeric target by the same padding.

## One main77b comparator (proposed, uncredited)

No exact main77b artifact for Maple with River's banner at native top was found. Propose ONE additive UI-only overlay on77b24899 (product tree byte-identical), fresh build900 then ONE fresh suppressed ProMax UI lifecycle<=300s. No seeded bookmark, no product probe or positioning command.

Method: ordinary --companion-preview --companion-preview-reading --companion-preview-follow-trace. Open Home's agent-preview-studio-maple using the existing public row-navigation helpers. Require the actual composer and River's View banner. Tap the native status bar once using the existing helper. Wait boundedly for the actual earlier button/native top, then retain screenshot, public AX rectangles for navigation/header/banner label/View/earlier/composer, transcript following value, earliest reading marker and complete hierarchy. Tap Show earlier ONCE and retain whether real marker prefix/count changes within5s, plus after screenshot/hierarchy/frames. This is diagnostic: do not turn a failed real tap into passing acceptance. A missing setup is NOT EXERCISED and stops attribution; no repeat. If main exposes/activates the button, classify the new mounted alignment as the regression; if covered and blocked there too, classify pre-existing. Both outcomes are reported before the product fix.

I will send the exact additive overlay/test diff + manifest/hash to QA before its build. This request is for the one comparator design, not a scoped exception.

## Product proposal for static review

Keep the existing safeAreaBar, its two-slot measured layout, toolbar, footer and A state machine unchanged. Measure ONLY the pinned other-agent banner's actual vertical size (including its own bottom padding), in the existing banner slot using public onGeometryChange. A target-scoped Equatable value in the outer ConversationView tracks that height; unchanged geometry writes nothing; no banner clears it; stale-target measurements cannot enter a different chat. No timeline/conversations read is added.

Pass that value as a display input to the transcript. Apply the measured value as an ADDITIONAL top .contentMargins(..., for:.scrollContent) on its ScrollView, OUTSIDE companion-transcript-content's frame coordinate. This reserves a visible top band for the pinned overlay even when A aligns the canonical entry; it is not another internal row padding or a change to saved distance, A tolerance, normalization, budget or retarget logic. Do not add a guessed constant, timer, mount delay, opacity, onAppear positioning, UIKit traversal or alternate restore command.

QA must explicitly review this distinction because native insets already include the bar: the extra margin is a deliberate protected reading band, not evidence that the original native inset is zero. If the main comparator or static model disproves this approach, refine the proposal BEFORE coding. Initial geometry is ordinary SwiftUI layout; the first encoded frame must already satisfy the visible-header/canonical-first contract, with no blanking or delay. A later good frame cannot rescue it. Repeated appearance/disappearance/size changes must preserve the currently read entry through unchanged A geometry safeguards; following/latest must remain bottom.

## Separate harness hunks

- F1: replace the recording fixture's unreliable horizontal action strip with two fixed rows of six short-labelled, native buttons. Keep every action; all controls have a physical hit region and stay on screen. The real conversation occupies the remaining offered space and keeps its real header/footer. No product content is hidden. The control helper makes one native tap and requires the actual target/scenario transition. Record the changed fixture viewport explicitly; do not credit old footage as the new proof.
- F3: use the existing descendant companion-composer lookup, then the existing software-keyboard helper. Keep every keyboard/draft/reload/final-pixel assertion.
- F2: strengthen the pre-tap physical clearance check against the visible banner band, in addition to hittability. Keep actual prefix-change, every4pt prepend/tail assertion and first-frame gates. No new tolerance/settling allowance or #587 edit.

Product and harness corrections are separate commits/hunks. The current exact source/tests remain unchanged until QA accepts the design; implementation diff + exact counts/manifests go back to QA before any candidate build.

## Proof and stop

Main attribution first, once approved. Candidate: fresh A -> F/video QA FIRST on all four opening routes, including a real pinned banner and actual Show-earlier activation. Add focused standard/largest-AX banner clearance/appearance/removal controls (including SE/landscape where measured height changes) as QA directs; disclose exact new selector counts before building. Then N/H/S, paired Home/paused/deep CPU counts<=main, and the full existing pinned-decision/footer/Reading coverage in C23/C50/R0/RSE, plus D.

The6pt restore,4pt earlier stability, first-frame route contract, same expected native outcome maps and STOP discipline remain. Wrong first content, hidden earlier control, excess movement, unexpected result or higher work counts -> STOP; no timing iterations.

After #587's merge, rebase onto current main85ee757a before broad selectors, prove the reviewed delta identity, re-pin only the separately authorized Reading test change plus source metadata, and fresh A for C23/C50/R0/RSE/D. #588's CompanionChatControlsBar change is outside our diff; check overlap explicitly. Parent owns landing, PR584 stays draft and device acceptance is deferred.
