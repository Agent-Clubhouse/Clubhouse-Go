# Product A: accepted proof on 3db11ac3

A reply arriving during reading restoration can trim the rendered timeline prefix after the numeric scroll target is pinned. The saved entry moves, but the old restore reports arrival at the stale target, landing one block late. The deterministic hosted and UI fail-before cases reproduced the original 96.667pt miss.

Recalculate the target only when the same bookmarked entry’s measured lower bound moves by more than 1pt under consistent geometry, before checking arrival. Tail growth alone keeps the pinned target. The original 20-attempt / 2-second budget and touch/navigation cancellation remain. Continuous movement exhausts that unchanged budget and preserves the semantic bookmark for a later mount.

The regression fixtures retain their real-layout gates and unchanged 6pt assertion; the bug-signature numeric/pixel miss assertions now require zero within 2pt. The historical Reading method uses a bounded public-frame stability helper with no expected-position input or tolerance change. Value tests cover 0.5pt noise, increasing lower bounds, repeated shifts, inconsistent geometry, unchanged tail growth and budget exhaustion.

Independent QA accepted static review, exact-head runtime and combined coverage on **3db11ac3234a47a4ba3420acdef8799d3e5c0309**. Current main at coverage time was **1797d21f**, already an ancestor. The tested combined tree `ba0277e70739bc288dc460dac78546ec54a04985` matches a freshly recomputed merge tree.

| Proof | Result |
| --- | --- |
| Debug build, compiled deinit gate, policy checks | PASS; 20 policy unit tests |
| H: focused values + hidden-conversation suite | 15 methods / 19 parameter executions PASS |
| S: deterministic restore + timeout/real-drag controls | 2 PASS |
| C23: original ordered historical prefix | 20 PASS, 1 strict expected failure, 2 known skips |
| C50: original ordered broad prefix | 47 PASS, 1 strict expected failure, 2 known skips |
| R0: cold historical Reading method | 1 PASS |
| RSE: full Reading on iPhone SE | 14 PASS, 1 iPad-only pointer skip |
| D: fresh combined coverage, jobs 2 | 1,721 tests / 205 suites, 0 failures; ratchet PASS |

Coverage: **Transport 96.81%, Domain 92.98%**. The five pre-existing package skips require `ANNEX_REAL_CADENCE_TESTS=1`; neither the tests nor enable flag changed:

- `aHeldHTTPCommandReceiptTimesOutToOutcomeUnknownOnRealURLSession`
- `heldAttachReplyHasNoDeadlineAndReconnectAutomaticallyAttachesAgain`
- `persistentSnapshotFailureGraceResetsTheAttemptCounterOn147`
- `fiveMinuteWindowOn147RecoversThroughResync`
- `failedBuildBackoffOn147RecoversThroughResync`

Both deterministic after-fix cases arrived with effectively zero miss. The historical Reading method passed in every context: Pro Max returns at saved y=209.667; SE at saved y=168.0. Prefix order and exact-once outcomes were audited. The known UI skips are the existing footer hysteresis case and iPad-only pointer case. All private simulators were deleted, owned processes exited, and runtime swap growth was zero.

The first compile-only attempt and generic hosted-auditor rejection are preserved in evidence. The hosted native run passed; a parameter-aware offline audit confirmed all 19 declared executions without rerunning tests. No assertion retries were used.

[Full evidence and independent QA verdict](https://github.com/Agent-Clubhouse/Clubhouse-Go/tree/evidence/ux-569/product-A-r2). [Deterministic fail-before](https://github.com/Agent-Clubhouse/Clubhouse-Go/tree/evidence/ux-569/prefix-trim-fail-before). A nonblocking [timeout/drag screenshot comparison](https://github.com/Agent-Clubhouse/Clubhouse-Go/tree/evidence/ux-569/black-band-main-comparison) shows the same large black band on historical main, predating #555 and #569; its rendering cause remains unclassified and no code was added for it.

First-paint semantic seeding is deferred to #582 and will not start until this change merges; latest content can still appear before restoration. #569 remains open for a device check. GitHub CI build/test jobs remain queued; the local results above do not claim those checks passed. Merge remains the orchestrator’s decision.

Refs #569
