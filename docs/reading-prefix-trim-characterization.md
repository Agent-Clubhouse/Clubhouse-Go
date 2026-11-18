# Reading prefix-trim characterization (#569)

Diagnostic only. No restoration logic changes and no passing regression claim. The existing historical Reading method and its six-point checks remain unchanged by this fixture delta.

The shared DEBUG fixture starts an ordinary loaded preview transcript. A real native scroll captures the paused bookmark. On remount, the existing `CompanionReadingRestoreProbe.deliver` hook refuses the first delivery after the product pins its offset, then appends one distinct reply through a normal Store upsert. It never writes geometry or scroll offsets.

Release requires all of these actual product conditions: a pinned offset, a different window hidden count and first entry, the new first entry's frame and the old first entry's removal, a retained bookmarked entry displaced by more than one point, and content/frame heights within one point. The viewport/insets must match the pre-remount geometry. Ten attempts or one second without the gate is **H1 not exercised**, not a product verdict. The probe releases normal delivery after that fixture failure; it does not change product cancellation or timeout semantics. Only a final `.arrived` outcome can classify the result. Probe teardown uses `defer`.

The baseline-specific signature checks require an offset miss of `-entryShift ± 2pt`; the UI also requires the actual marker's pixel displacement to match that signature. The independent six-point preservation check then decides restoration correctness. These diagnostic signature assertions describe unchanged main and cannot ship as the passing fixed contract: a later reviewed product fix must expect zero miss while keeping the six-point check.

Planned proof, only after independent static review:

- Fresh Debug build-for-testing: jobs 2, signing disabled, parallel testing disabled; source/app/test fingerprints and compiled deinit gate. Normal FIFO, hard 900s.
- One hosted characterization: `ClubhouseGoTests/CompanionHiddenConversationTests/prefixTrimDuringPinnedRestoreCharacterizesTheOneBlockMiss`.
- One UI fail-before: `ClubhouseGoUITests/CompanionReadingRestoreUITests/testPrefixTrimDuringPinnedRestoreCharacterizesTheOneBlockMiss`.
- Test invocations use a fresh private iPhone 17 Pro Max/iOS 26.0, QuickPath suppressed, new result bundles, exact once, no assertion retries. One bounded lifecycle, hard 600s total, normal FIFO; exact-owned shutdown/delete and process/zero-Booted receipt.
- Admission: vm_stat free + inactive >= 8GiB, CPU idle >= 40%, swap growth <= 64MiB over 10s. Runtime swap remains record-only, flagging growth > 256MiB. No heavy overlap; coordinate directly with go-composer-control.

Expected failure is diagnostic evidence only if the geometry gate and final arrival succeed, the two-point miss signature holds, and the unchanged six-point assertion fails. A compile error, gate miss, timeout, wrong outcome, unrelated assertion, or repeat is not a product finding. Product proposal and independent QA acceptance must precede any restoration implementation change.
