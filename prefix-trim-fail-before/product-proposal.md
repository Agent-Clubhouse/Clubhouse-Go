# #569 product proposal — review before implementation

The deterministic fail-before is accepted by QA. On unchanged main f89bb9ee plus DEBUG fixtures at 1f719268, one real tail upsert between the restore pin and delivery removes the oldest rendered entry. The saved entry moves −96.667pt, but the product reports `.arrived` at the original numeric target. Hosted miss is +96.667pt; UI marker moves 166.667 → 70pt. Each test executed once and failed only the unchanged 6pt contract. No restore code has changed.

## A. Preserve the semantic target across a prefix shift

1. Keep the immutable saved entryID and distanceFromEntry already passed into restoreReadingPosition. Extend CompanionReadingRestoration.next with the current saved entry's measured lowerBound (nil for a bookmark without an entry). Retain the last accepted lowerBound alongside the numeric offset.
2. Accept measurements only after the existing content-height/frame-height agreement (<1pt), generation/follow guards, deadline and outcome checks. Pin the first numeric target and its entry lowerBound together.
3. On a later consistent sample, if that SAME saved entry's lowerBound changes, replace the numeric target with saved.restoredOffset from the current frames. Update the remembered lowerBound before the arrival comparison. Never repin merely because contentHeight, maximumOffset or the proposed offset changes; nil/unrealised entry measurements do not retarget.
4. Test arrival against the updated target. Keep the original maximum20 attempts /2sec deadline, task identity, cancellation and touch/navigation authority; a repin consumes the same loop/attempt budget and never extends startedAt. Leave normal post-arrival compensation and bookmark saves unchanged. H2 was not observed and is not needed to explain this reproduction, so no teardown/save policy change in A.
5. Keep the existing dropped-delivery/tail-growth test, deliberately strengthen its setup to pass an explicit unchanged entry lowerBound while proposedOffset/contentHeight grow, and require the original numeric target. Add value tests for prefix shift before stale numeric arrival, multiple shifts under the same budget, nil/unrealised frames, generation/cancellation and unchanged bounds. No tolerance changes.
6. Convert the deterministic hosted/UI methods from characterization to regression: retain every real gate, final-arrived requirement, shift measurement and original6pt assertion; replace only baseline-bug expectations (miss≈−shift and pixel displacement≈−shift) with miss≈0/pixel delta≈0 within2pt. The probe controls ordering only and stays DEBUG/reset in defer. The original historical Reading :311 helper keeps its6pt checks and controls.

## B. First paint is a separate concern

The trace shows a real remount initially at the latest offset before restoration. It should present the saved semantic window/follow state from the first body, but layout-dependent pixel alignment cannot be resolved before real frames exist. Propose a separate small follow-up after A is proved: lazily seed followLatest, shownEntries and the initial edge from the per-target bookmark before the first body; no guessed numeric scroll offset, hidden content or delayed first paint. This is intentionally not mixed into A's target-correction proof. A cold/remount first-frame recording and latest/paused controls must independently validate it before shipping. Ask QA/parent whether B belongs in the same PR as a separate reviewed commit or its own issue; A can be assessed independently.

## Proof plan after static code review

- New branch from current main1797d21f, carry only approved fixture/helper/policy additions, then A. Prove core delta and fixture identity separately.
- Fresh Debug build with source/artifact provenance, compiled deinit gate and policy unit tests.
- Focused restoration value tests; deterministic hosted once then UI once, requiring PASS/no skips/retries and all gates exercised.
- Same controlled historical prefixes: original e45+test overlay50 and b829 prefix23 on the fixed head in their original order, plus cold single. Preserve exact maps/order,6pt checks and controls.
- Broad reading/hidden-conversation, footer/keyboard/decision and navigation risk suites; then current-main combined coverage under guarded FIFO. Exact manifest goes to QA before runs. No product acceptance until these pass.
