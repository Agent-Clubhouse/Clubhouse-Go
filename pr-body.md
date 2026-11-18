Visible Home rebuilt its owner, layout and headers for every streamed batch, including conversations outside the selected desktop scope. This removes that steady per-chunk rebuild by isolating Dispatcher transcript observations in a child view and giving Home a decision-only value projection. Pending decisions retain the existing selection, urgency, metadata and live action-authority rules.

Refs #528.

Tested head: `95b61cf685ed74bb3ff9408aa5f508f14027b3cf`; merged as `ffcf13e8`. Eight files, +377/−14. No anchor restoration is added: returning from another tab still starts at the top, tracked in #567/#568.

[Evidence, receipts, live tables and inspected frames](https://github.com/Agent-Clubhouse/Clubhouse-Go/tree/evidence/ux-528-visible) (`43c94ee`). Raw xcresults remain under `/tmp/ux-528-visible-proof/tickets/`.

| Proof | Result |
| --- | --- |
| Projection parity and observation package tests | 49 tests / 6 suites PASS; all six target×outcome cases ran |
| Fresh before/after Debug builds | PASS; exact product fingerprints and additive-overlay inverse proofs |
| Compiled deinit / policy | PASS / 20 PASS |
| Identical r2 live measurement | Main2× + head2×; approved count bar PASS in both head runs |
| Strict mounted Root tests | 2/2 PASS: pushed freeze and decision pixel freshness |
| Hosted regressions | 27/27 PASS |
| UI C1 / C2 / normal Dispatcher C3 | 14/14 +26/26 +10/10 PASS |
| Package ordering/state | 73 tests /11 suites PASS |
| Combined current-main coverage | Clean/no-overlap merge of main `5cd27a06` + head into `d61276ac`;1693 tests /205 suites PASS; coverage check PASS |
| Line coverage | Transport96.82% (5017/5182); Domain93.03% (14757/15862) |

The package49 run used product/package-identical `c1a62b75`; the retained identity proof confirms those inputs are unchanged on95. All mounted/UI gates used fresh95 products. Every selected hosted/UI method ran exactly once with no skips/retries, and strict xcresult verification passed. Tickets used guarded FIFOs, two jobs, hard bounds and record-only runtime swap monitoring. All recorded runtime swap growth was zero. Final receipt confirms no owned swift/xcodebuild and the private simulator shut down; it was deleted after merge. No phone installation or device CPU/battery claim.

This **removes the steady per-chunk visible-Home rebuild; a single first-mutation pass remains, identical to main's**. Main rebuilt about3–4 times with72–96 header evaluations per batch. Both head runs measured one owner/inputs/content/layout pass and24 headers at visible batch0, then zero on batches1–9; the loaded outside-scope case stayed zero throughout. Every other site stayed at or below paired main. Supporting process CPU seconds for100 chunks were visible .939/.950→.114/.092 and outside .885/.880→.052/.086; counts are the gate.

The maintainer explicitly accepted the disclosed bar above. The original ambitious zero-bar FAIL is preserved, not reported as zero work. QA's candidate explanation is a stale initial unheld-Recent `lastActivity` dependency: the first mutation may retire that observation after the held order applies. The cause is not instrumentally proved; #572 retains the diagnosis and ordering-input decision.

The before/after r2 method SHA256 is `a0c944a66cf661c7af377a62f5657b106a3f36a76ec5aafc46552a83771ed9e9`. Both overlays have exact additive-inverse proofs. C3 uses the normal Dispatcher and unchanged tests for routed bursts, sender folds, separate drafts/scroll positions, streamed chips, permission and reconnect behavior.

The decision projection refreshes from final accepted history/timeline items, approval/question upserts including local submitting/completion/refusal/uncertainty, and removal. Plain text/tool/sequence changes do not recompute it. The common attention selector is unchanged. The mixed-event package oracle compares full raw decision values and conversations-derived attention after every event, including deadline expiry without traffic, history/timeline replacements, stale events, same-ID metadata, all resolutions, reconnect/epoch changes, removals and plain chunks.

All seven existing HomeVisibility methods are byte-identical. The new mounted pending test seeds authoritative per-target history and loads it before mount, checks conversation/cache/isLoaded before and after mounting, then proves full Edit→Shell text at AX1. Resolution retains the question row while removing Shell; a realistic waiting host report produces the question status pixels; the final empty state remains asserted. It explicitly permits the #572 first-mutation pass and requires zero further construction growth.

Validation history is preserved: strict-r1 failed only the new fixture test because its unloaded approval was replaced by generic fixture history on the hidden Needs-you mount. The reviewed correction changes only that new method and default-preserving fixture controls; strict-r2 passes both methods and the fresh head2× measurement passes. No pixel/counter assertion was removed. #573 records pre-existing duplicated permission text with an inspected frame; #574 is LOW-priority nil-session hardening, with current producer reachability ruled out because pending decisions arrive via session-bearing timelines. Neither is changed here.
