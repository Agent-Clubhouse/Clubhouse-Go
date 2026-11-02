# Feedback trigger and diagnostic investigation

Branch: `go-feedback-flow/triggers-and-logs`, based on `6c32b12` (reported build 147).

## Plan and test cases

- Screenshot: resolve unknown enrollment status instead of silently ignoring the trigger; retain one bounded capture across inactive scenes; start/restart the eight-second offer only in the original foreground-active scene. Test cold status, secure input, inactive fallback, activation, interruption and repeated capture. Keep the offer at the top, away from the screenshot thumbnail at the bottom.
- Shake: exercise a first responder outside the SDK receiver's subtree, conversation focus/dismissal, sheets and disabled settings. Prefer an ancestor responder in Go's own hosting hierarchy, without swizzling, first-responder stealing, polling or changing the pinned SDK. Keep one eligible trigger path and the two-second gate.
- Diagnostics: mock enrollment and OTLP only. Prove connection failure and backoff survive the mapper; reproduce periodic-flush omission from report excerpts. Explain missing/off/disconnected diagnostics in Go's composer entry points. Enrollment already enables capture independently of Connection diagnostics; do not capture before enrollment.
- SDK requests: preserve already-exported/inflight records in a bounded report excerpt; expose availability; simplify the composer to visible review plus one intentional Submit. Do not modify Vendor/Framebriar.
- Define correlation and limitations, including the lack of backend evidence for historical report `35858bdd`.

## Validation

Run Swift package tests with coverage, the coverage ratchet, vendor package tests and hash verification, Debug and Release builds, app tests and preview UI tests on a newly created private simulator; delete it afterwards. Do not run live E2E, contact production feedback, use a phone/shared simulator, restart/update the host app, publish or merge.

A simulator cannot establish real shake-sensor delivery or real iOS screenshots with Full-Screen Previews. Those checks remain for an authorized physical-device session.
