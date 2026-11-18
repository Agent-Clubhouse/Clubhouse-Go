# Current: harness-only correction, pending exact QA review

#582 source5c785b864 rebases cleanly onto85ee757a; the pre-harness cumulative patch is byte-identical to reviewed a971c9343. [Rebase identity + current diff/manifest](proposal-and-proof/bookmark-start/harness-r2/harness-r2-review-notes.md). Product code is unchanged; only the DEBUG recording fixture, its new UI tests and the proof doc change. No build/test/simulator on the rebased head yet. PR584 remains draft.

F-r1 stays STOPped (3 once/3F), with all original evidence retained. [Revised QA ruling](runtime/f-r1/revised-ruling.md) supersedes the initial product-bug classification: the banner inset is correct, and A’s intentional38pt correction moves the inline header above the viewport. No inset change or main comparator was coded/run. Current fixes are native-top setup/physical clearance,2x6fixture controls,genericcomposer and SE/XXXL/landscape recording scope. Video QA comes before the remaining suites.

# Current STOP: F-r1 pinned-banner access

Fresh A-r5 on a971c9343 PASS (compiled gate +20policy). F-r1 ran3 methods once,3 failures: a real Show-earlier occlusion by the pinned other-agent banner, plus separate fixture reachability/composer-query defects. [Complete STOP report and original video/frames](runtime/f-r1/report.md). No retry/correction or later suite has run. Private simulator deleted, system0Booted/processes empty/swap0; host returned. PR584 stays draft.

The Orchestrator authorized addressing banner access within #582. [Main attribution and inset proposal](proposal-and-proof/bookmark-start/banner-access/proposal.md) is submitted BEFORE code/run. It distinguishes the native inset (already measured) from an additional scroll-content protected band; no pre-existing attribution is claimed without the comparator.

# #582 / draft #584 — bookmark-first implementation, pending static/runtime proof

The user approved paused remounts starting WITH the canonical saved entry, with earlier history behind Show earlier. The implementation is pushed at `a971c9343`. [Cumulative review packet](proposal-and-proof/bookmark-start/implementation/bookmark-start-review-notes.md) records QA's required mounted-replacement correction, its new hosted control, the nil-predecessor edge, exact source/test/config hashes and paired CPU count instrumentation. The capture epsilon correction is a separate commit.

**No build, test or simulator ticket has run on this new design.** Exact conditional-fix static acceptance is pending. Then fresh build → first-frame video first → N/H/S/CPU → broad suites → current-main combined coverage. No runtime, CPU, device or merge-ready claim. PR584 stays draft.

# Prior experiment: hard stop (preserved evidence)

Exact source `7c12e00df` is NOT merge-ready. A-r4 fresh build, compiled deinit gate and20policy tests PASS. FD-r2's ONE F1 UI method PASS reached all scenarios, but its real video FAILS the first-frame gate: native destination reopen paints marker1 before jumping to90. No assertion or test retry follows it.

See [runtime/fd-r2/report.md](runtime/fd-r2/report.md) for the decisive73.333ms transition, full unaltered video/PNGs, actual frame timestamps, app stdout/timeline, controls, limits and exact cleanup. The synchronous cached-ID proxy request did execute once; native offset remained0 until the existing geometry correction.

The initial expanded paused opening improved, but the native-destination counterexample triggers QA/Orchestrator's hard stop. All N/H/S/CPU/broad/combined runs remain held. The earlier zero-command assertion is unchanged. Private simulator8876542F was deleted, system-wide0Booted, owned processes empty, swapgrowth0; host released.

Two explicit options go to the Orchestrator/user: start the initial window at the bookmark, moving older history behind Show earlier messages (a UX/contract decision requiring new review/proof), or do not ship #582 and retain shipped behavior. No further timing iterations or silent window trimming.

History: runtime/fd-r1 preserves the original expanded-mount top-to-bookmark failure. runtime/a-r4 preserves the fresh build/gate results. Earlier proposals and A/N receipts remain as honest history; old CPU overlays are stale and must not be run.
