# Context controls preview evidence

Source: `6e43083efb0c98a85ca8e6e796cf3f9512bf80d7` on `go-context-window/settings`, rebased onto `68a11b256ca01e2d84644cbe6c84ae1bee363cac`.
Whole committed desktop fixture pin: `352bcbd179bcc91b92acfd80b4165074a96fa988`.

Captured by all three passing `CompanionContextWindowUITests` from opt-in preview
content on a newly created iPhone 17 Pro / iOS 26.0 simulator. The simulator was
deleted and its absence verified after capture. The host app, phones and live
desktops were not used.

- `context-sleeping-agent.png`: pending context beside Model for a sleeping preview agent.
- `context-dispatcher.png`: Dispatcher pending launch/resume choice.
- `context-dispatcher-choices.png`: preview server choices plus default.
- `context-current-report.png`: read-only reported context, compaction and reserved values.
- `context-awake-locked.png`: ordinary awake preview agent's pending choice is locked.

Rebase validation: 972 package tests; coverage ratchet 96.43% Transport / 93.97%
Domain; Debug and Release simulator builds; all three context UI tests. Bundled
Framebriar verification/tests and CI-script checks also pass.

An attempted whole-set update to desktop `0f463f8f9ebc06d5b312288017a66e98a97406cb`
failed the two command/schema coverage tests for `helperRouting.update`, and the
refusal-message test for `invalid_helper_routing`. Those tests were left unchanged.
Per the orchestrator, this branch retains the entire validated `352bcbd17` fixture
set; PR #233 will advance it with supporting code.

These are illustrative previews and fixture observations. Copilot's real-login
catalog/tier effect, Claude plan figures and real running-agent UI remain
unverified (Clubhouse #2633). The not-applied notice fixture is hand-built; no
start/resume-to-phone wire validation is claimed.
