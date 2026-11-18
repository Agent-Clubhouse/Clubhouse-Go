# #570 — visible Home observation evidence

Product/test head: `95b61cf685ed74bb3ff9408aa5f508f14027b3cf`, based on main `92b6f1caff2686ca74ff7b3242b865c2d9122923`.

This removes the steady per-chunk visible-Home rebuild; a single first-mutation pass remains, identical to main's. The maintainer explicitly accepted visible batch 0 ≤1 owner/inputs/content/layout and ≤24 headers; visible batches 1–9 and every outside-scope batch must be zero. All other sites stay ≤ paired main. The original zero-bar failure is retained, not reclassified as zero work. #572 tracks the remaining one-shot dependency and ordering decision.

Both head runs meet the approved bar. The identical r2 overlay SHA256 is `a0c944a66cf661c7af377a62f5657b106a3f36a76ec5aafc46552a83771ed9e9`; build receipts include exact additive-inverse proofs and product fingerprints. Every live case delivered 100 chunks in 10 rendered batches. Idle controls and all counters remain in live-gate.json. Process CPU time is supporting evidence, not a device CPU/battery claim.

| Case | Main per-batch construction/header | Head | CPU seconds, main → head, runs 1 / 2 |
| --- | --- | --- | --- |
| Visible Dispatcher | 3–4 owner/content/layout; 72–96 headers | one construction /24 headers at batch 0, then zero | .939→.114 / .950→.092 |
| Loaded conversation outside Home scope | about 3 construction /72 headers each batch | zero throughout | .885→.052 / .880→.086 |

The real mounted Root pending-decision test seeds authoritative history before mounting and proves full Edit→Shell pixels at AX1, approval resolution with the question row retained, realistic waiting-report question pixels, and the final empty state. It explicitly permits the same #572 first-mutation pass and requires zero later construction growth. All seven older HomeVisibility methods remain byte-identical; strict-fixture-identity.json/.diff records the correction. Original strict-r1 is retained locally as a fixture failure, not a product pass. #573 records duplicate permission text; #574 is low-priority nil-session hardening with current producer reachability ruled out.

Validation recorded so far: package parity49; fresh Debug before/after builds; compiled deinit +20 policy checks; paired live2× per side; strict2; hosted27; C1 UI14; C2 UI26; C3 normal Dispatcher10 (UI50/50 total); package ordering73/11 suites; combined current-main coverage1693/205 suites. All focused methods ran once, no skips/retries. Combined main `5cd27a061e49ee08a24a51e033bc0dca5e5433ef` merged cleanly with no overlapping changed files into temporary `d61276ac63d2152ef86b315c1379aae9f1ffba0a`. Coverage --check PASS: Transport96.82% (5017/5182), Domain93.03% (14757/15862). Final process receipt shows no owned swift/xcodebuild and private simulator Shutdown/system-wide0Booted. Every runtime ticket recorded zero swap growth. Every run is once through its guarded FIFO with a hard bound; no assertion retries. Simulator is shut down at each ticket exit. No phone install or live configuration changes.

Images are generated fixture evidence: linked Home light/dark, full-origin AX5, real swipe-back, large-catalog native menu and the duplicate permission text at AX1. Raw xcresults/logs/remaining OCR attachments remain under `/tmp/ux-528-visible-proof/tickets/`.
