# #582 / draft #584 evidence (work in progress)

Cumulative source caaac0337 adds the missing Combine import and explicit MainActor on the new hosted Fixture to reviewed fbb7a7ee6. QA carried approval over the import; the helper annotation is with QA. All runtime acceptance remains pending. A-r1 stopped at compile rc65 after64.18s (one ObservableObject conformance error), zero tests/sims, swap0 and owned-process closure/system0Booted. Receipt and compressed log are under runtime/a-r1. A-r2 compiled the app but stopped at the new test Fixture’s missing actor annotation (rc65,161.52s,zero tests/sims,swap0,ownedprocesses[],system0Booted). Its receipt/log are under runtime/a-r2. A-r3 may reuse that closed DD under the guard after beta.3’s single harness/live ticket closes. No UX heavy is currently queued.

The current bundle covers the lazy immutable seed, once-per-mount counters, idle-only identity handoff and disclosed DEBUG phase/ownership tests. New hosted scope is11 methods/12 executions plus two pre-launch recorded UI methods. All four existing Reading/restore/hidden contracts remain byte-identical to main77b24899.

QA accepted the source-only CPU overlays at main858398b8/head251e5bbb, identical additive test patch SHA810d8ce4e1269efed07ff6479a670167dfe396f7ae8fa71dc71568c3b3147c41. The head overlay is now STALE after the import correction and MUST NOT run. Regenerate after the final green build and obtain QA identity review. The preparer supports a new generation directory and always forces fresh CPU builds, never borrowing product A’s incremental receipt.

Run order A→N→F→H→S→CPU→C23→C50→R0→RSE→D, stopping on unexpected outcomes with no assertion retry.
