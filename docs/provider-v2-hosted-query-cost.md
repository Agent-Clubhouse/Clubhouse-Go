# Provider V2 hosted query-cost correction

The first #616 provider shard at `37d5b595` did not pass. Preserve its original first outcomes separately from CI retries and runner restarts. The Large semantic method failed after 225.669 seconds before its checked Start tap. The later iteration reported Passed after 265.671 seconds alongside an allowance warning. The Large capture method exceeded its four-minute allowance and restarted without a retained completion. Neither is first-attempt acceptance.

## Original evidence and limits

- Run `44624001013`, provider job `135954651616`, uploaded artifact `test-results-0` / `14595083360`.
- Closed job stdout SHA256 `3d6eccc25e701fc8011e5e7bcccf58f90465521f523fd3c1583e0134122f0dcf`.
- Uploaded ZIP SHA256 `33c424a7a2b18ef583e93efaf2c03c02501ee436d3895b9df80b78d55e821889`. It contains the unfinished result bundle Data and Staging diagnostics, but no Info.plist; xcresulttool cannot open it. No reconstructed bundle summary or activity export is claimed.
- Retained staging session logs independently corroborate the timestamped native operations. At 02:27:06 the proposed-model Find took 11.1616 seconds. A later proposed-effort Find retried until the capture allowance expired. This is an observed AX-query stall, not proof that changing the helper fixes its cause.
- The first Large semantic attempt contains 624 logged Find operations and 27 readable-row geometry observations. Saved, proposed, reset, receipt and Start reading repeatedly resolve navigation, Form, window and sticky-action frames in separate AX requests. The proposed-model search alone uses seven native pans; its movement progresses toward the row.
- The final first-attempt Start frame is `(16,457,370,69.6667)` within the measured `144...587` protected band. A named capture occurs, then the generic scrollTo's remaining-time guard fails when the checked-tap helper starts another search for this already-contained row. This establishes redundant search, not an absent or oversized control.
- The original PNG payload with 1,070,070 bytes is unique in this artifact and matches the staging activity's reported attachment size. Its Start sentence is readable. The 947,074-byte proposed-model PNG is also unique and readable. This size/content correlation does not substitute for missing finalized attachment-reference metadata or establish fresh native acceptance.

## Bounded test-only correction

Take one native application snapshot for each readable-row observation. Resolve the unique Provider navigation bar, Form and persistent actions from that same hierarchy, and retain the realized row's native frame. Reject missing required elements or ambiguous row identity. Use the same eight-pan cap, response feedback, 24...120-point travel, slow velocity, initial press, zero end hold, stall and oversize stops, and horizontal and vertical clearances.

Before capturing, retain the five-second row existence check, snapshot that exact row once, and check its identifier, every expected text phrase, whole frame and same-Juniper context. The text and geometry are actual native observations, not fixture-substituted values. This removes repeated remote attribute reads; it does not relax readability.

For Large checked controls only, skip the generic search when a fresh native observation already fully contains the control. The existing four-pan adjustment, actual control remeasurement, hittability, whole-frame guards, screenshot and single checked tap remain. Immediately before the checked Large tap, another coherent observation must resolve the exact same control frame and identifier, confirm it is enabled and hittable, and confirm both horizontal and vertical containment; any mismatch fails without a tap. An unrealized or clipped control still uses the original bounded search. Ordinary/V1 paths keep that search unchanged.

No product, fixture response, command, confirmation, cancellation, same-agent check, assertion outcome, test selector, gesture ceiling or execution allowance changes. Full-fixture command traces, current readable original pixels, first-attempt native outcomes and cleanup remain required after independent review. Timing improvement and iOS 26.5 convergence are unproven until observed; no local iOS 26.0 result substitutes for hosted proof.
