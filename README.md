# Native Home agent-row menu coverage (#564 / #576)

Tested head `ba80d0a21eec463abc54879fad7f3520892c13e7`; merged as `3d4d01d7`.

- Hosted **23/23 PASS** on `253f5cb8`, preserved through UI-only changes by before/after SHA256 equality of **all 50 app and hosted-test payload files** (`build-r4` and `build-r5` receipts).
- Native UI **3/3 PASS**, exact once, no skips/expected failures/retries: standard and AX5, light/dark, sleeping/running menu labels/order/containment and correct Details target, plus existing sleeping-agent Settings.
- AX5: menu reveal max **1 drag**, Home positioning max **2**. Standard: **0** drags for either. Per-step measurements, native AX and screenshots are indexed below.
- Debug build, compiled deinit and policy **20/20 PASS**.
- Combined current main `2381d424` merged cleanly (fast-forward) with the tested head. Fresh coverage: **1693 tests / 205 suites**, Transport **96.85%**, Domain **93.00%**, ratchet PASS; swap growth zero.
- Exact owned simulator `EB0FD52F-378E-454D-BF69-A39926B1D4B1` deleted; see final receipt. Protected local route-contract scratch is untouched.

## Scope

Hosted tests OCR the actual native content child through real captured Root values and the real Home modifier. Existing callback guard-effect tests remain byte-identical to main. Hosted public AX exposed no SwiftUI button nodes, so **hosted native activation and telemetry are not claimed**. Native presentation/activation is live Home UI only; frozen Home is behind a pushed route and is not user-reachable for a long-press. Offline Terminal's presence and unavailable model state are checked; its disabled AX appearance is not.

## Evidence index

- [Final hosted actual-child OCR/screenshots](hosted-r3/attachments-index.json)
- [Final native UI frames, AX and screenshots](ui-r5/attachments-index.json)
- [Per-step geometry summary](ui-r5-geometry-summary.json)
- [All receipts and source/artifact hashes](receipts/)
- [Coverage log](coverage-r5/coverage.log)
- [Existing Home methods byte-identical to current main](receipts/existing-method-identity-rebased.json)

## Preserved failed attempts (never credited as passes)

1. `81510667`: hosted 20/23. Inner nil environment values overrode captured values (blank frozen content); actual live menu drew but public hosted AX was empty. Approved explicit OCR/guard/UI fallback followed.
2. `4bac1b58`: hosted 22/23. New missing-environment test waited for an unrealised sleeping row. Fixed fixture to get target-parameterized Root handles from a realised peer, positively checking sleeping Wake choices.
3. `253f5cb8`: UI 2/3. AX5 menu is natively scrollable; Settings/Terminal were below its clip. [Exact failure frame](ui-r3-AX5-failure.png). Fixed bounded menu-only reveal, preserving all item assertions and adding actual-clip containment.
4. `f886db8a`: UI 2/3. AX5 light and dark sleeping checks passed; dark Cedar was above Home's content (`y=-328...111.3`, navigation bottom 116) despite being reported hittable. [Exact press frame](ui-r4-AX5-running-press.png). Fixed full-row positioning before exactly one checked-center long-press; no action retries.

Original xcresults and recordings remain under `/tmp/ux-564-proof/tickets/`; the recording hash/path receipt is retained here. No product behavior, font cap or tolerance changed.
