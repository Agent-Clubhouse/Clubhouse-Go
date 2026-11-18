TASK_RESULT:qa-569-static — #569 fix A at 3db11ac3 (PR #583): QA COMPLETE. Static, exact-head runtime and combined coverage all PASS. The black-band comparator is non-blocking and can follow.

Combined coverage (d-fix-r1): main 1797d21f is still origin/main and is an ancestor. The combined tree ba0277e7 equals `git merge-tree --write-tree 3db11ac3 1797d21f` (recomputed by QA). No product overlap. 1721 tests in 205 suites passed, 0 failures. Transport 96.81%, Domain 92.98%, ratchet PASS.

Runtime, all on 3db11ac3, each with a fresh lifecycle and its simulator deleted:
- A: green build, deinit and policy passing.
- H: exactly 15 methods / 19 executions passed. Hosted regression: pin 1324, shift -96.667, arrived at 1227.333, miss ~0.
- S: 2 of 2 passed. UI regression: pin 1081, arrived at 984.333, miss ~0. Timeout/drag control passed.
- C23: 20 passed / 1 expected failure / 2 skips with the right reasons, original order.
- C50: 47 passed / 1 expected failure / 2 skips, original order.
- R0 cold: 1 of 1 passed.
- RSE on iPhone SE: 14 passed / 1 pointer skip.
- The #569 Reading method passed in every set. Timelines settled at y 209.667 on Pro Max (C23, C50, R0) and y 168.0 on SE (RSE). (Corrected: the earlier wording said 209.667 for every set.)

Fail-before and pass-after on the same deterministic fixture: main missed by +96.667 (hosted and UI); the fix gives ~0.

For the PR: B (first paint) is deferred to #582. Disclose the unchanged 20-attempt / 2s exhaustion behaviour. Merge is the parent's decision.

Note: not delivered. The orchestrator was asleep when this was sent (both send_message and message_parent failed).

Addendum: the coverage log has 5 pre-existing opt-in skips (heldHTTPReceipt, heldAttach, persistentSnapshot147, fiveMinuteWindow147, failedBuildBackoff147), the same count as the #578 coverage run. No package test or enable flag changed.

Black-band comparator (mb-r1): passed, run once. Main f89 + overlay shows the same large dark band as 3db (side-by-side /tmp/ux-569-black-band-proof/main-head-comparison.png; offsets 32363 vs 32309, same arrived state). So it predates #555 and #569: no regression, and no new issue required by the agreed criterion. The cause (end of content vs drawing or contrast) is unresolved and out of scope.
