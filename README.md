# Context controls preview evidence

Source: `558bd742dabe5d93e9a11e508bde9f9dd4f29501` on `go-context-window/settings`.
Desktop committed fixtures: `352bcbd179bcc91b92acfd80b4165074a96fa988`.
Go rebase base: `9441c4362b6359abe6c87ffe9e5815ce0aa5c772`.

Captured from opt-in preview content with XCTest on a newly created iPhone 17 Pro,
iOS 26.0 simulator. The simulator was deleted after capture. No live desktop or
phone was used, and the host Clubhouse app was untouched.

- `context-sleeping-agent.png`: pending choice beside Model on a sleeping preview agent.
- `context-dispatcher.png`: Dispatcher's pending launch/resume choice.
- `context-dispatcher-choices.png`: menu showing only the preview server's choices and default.
- `context-current-report.png`: read-only reported context, compaction and reserved values.
- `context-awake-locked.png`: pending choice disabled for an awake ordinary preview agent.

These are illustrative previews, not real provider observations. Copilot's real-login
catalog/tier effect, Claude plan figures and real running-agent UI remain unverified
(Clubhouse #2633). The committed not-applied notice is hand-built; no start/resume-to-phone
wire validation is claimed.

Validation: 925 package tests; coverage ratchet 96.49% Transport / 93.99% Domain;
66 Framebriar tests and vendor verification; Debug and Release simulator builds;
17 CI-script tests. The full non-live UI run exercised 56 tests, with 55 passing and
one sleeping-reset failure. After fixing the reset control and its viewport-safe test,
the final bundle passed all 3 context UI tests plus 10 app unit tests (13/13, no retries).
All 53 pre-existing non-live UI cases passed in the full run.
