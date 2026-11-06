# Hardware Return in the chat composer (#309)

The composer previously offered only Command+Return for submission. The change adds unmodified hardware Return through the existing native input hook. Shift+Return inserts a newline at the native selection. Return first completes an active named slash prefix; bare `/` and fully spelled commands submit. Software Return and pasted multiline text retain their existing editing behavior. Touch Send and Command+Return retain their guarded store path.

The hook preserves the SwiftUI editor's native identity. It advertises commands before focus but validates focus, editability and marked-text state when activating them. Cached actions cannot confirm marked text or send from an unfocused field. The store continues to gate empty, offline, unsupported, resynchronizing and pending sends.

## Evidence and limits

`CompanionComposerReturnTests` hosts the real composer with a synthetic service. It discovers actual native key commands, resolves their target through UIKit, then invokes `sendAction(to: nil)` through the first-responder chain. It verifies single dispatch, pending protection, slash precedence, Shift+Return selection replacement, multiline insertion, marked-text preservation, and unrelated-field isolation. These tests establish handler and responder-chain behavior. They do not establish physical-keyboard or iPhone Mirroring event delivery, or a complete real IME interaction.

`CompanionHardwareKeyboardUITests` separately sends actual XCUI `typeKey(.return, modifierFlags:)` events in preview mode, with assertions for Return, Shift+Return, slash completion and retained Command+Return. These assertions are not replaced with `typeText("\n")` or direct action invocation. Initial iPhone and iPad simulator runs failed both Return completion and existing Command+Return submission, while touch Send, image/text paste and existing slash-navigation tests passed. The cause is unresolved; this is not classified as a harness-only failure. Original results are retained under `build/hardware-enter/` and summarized in the PR.

The PR must distinguish passing hosted contracts from actual-event failures. Do not claim the reported Mirroring problem is fixed solely from hosted tests, and do not relax the failing assertions or retry policy to obtain green CI.

## Hosted focus diagnostic (#272 / #234)

Run 42156046561's hosted Load test failed 51 paced and 10 rapid first-responder assertions before the Return tests ran. Its text, binding and native-identity assertions did not fail. The old `focusLosses=0 retainedAll=true` summary was constant text, so it was not evidence for either result. The shader-pipeline delay in that log does not establish a cause.

The optional DEBUG `CompanionComposerFocusProbe` now records composer appearance/disappearance, FocusState changes and explicit focus/dismiss requests. The Load test observes native editing, window-key, scene and keyboard notifications; snapshots report fixture ownership, editor attachment, first responder and activation states without recording draft content. Notification-delivery and first-observed-loss stacks are labeled as observations, not assumed resign call sites. Teardown removes observers and restores the previous probe/key window. Existing assertions and native focus setup remain, with measured focus-loss samples, text retention and editor identity.

One serial iPhone 17 / iOS 26.0 diagnostic passed all 15 cases once: the six historical predecessor cases, Load, and eight Return contracts. Load took 13.370 seconds, with measured `focusLosses=0 focusLossMetric=failedSamples retainedAll=true retainedIdentity=true`. The fixture stayed key, mounted and active; its only end-edit notification followed the test's explicit final resign. The notification stack included that test call through `UITextView.resignFirstResponder`.

The run used `-jobs 4 -parallel-testing-enabled NO`, no retry/repeat flags and the unchanged 120-second allowance. The exact built xctestrun and shared auto-created scheme had no retry/repetition settings; results contained 15 passing cases, no repetition nodes, and the log contained exactly one start per case. Two prelaunch argument/result-path rejections executed no tests and their logs were preserved. Setup began 2026-11-06 04:20:05 UTC; the single build took 56 seconds; actual execution ran 04:22:02–04:22:53 UTC; the owned simulator was deleted by 04:22:56 UTC.

This does not reproduce or explain the CI focus loss, establish a load cause, or repair physical Return/Mirroring delivery. Instrumentation and the older local runtime can affect timing. The remaining hypotheses are SwiftUI/native focus reconciliation versus host window/scene ownership; the original failure needs its first native end-edit and lifecycle sequence before choosing a behavior fix. No automatic refocus, timeout, retry-policy or assertion change is introduced.

## Minimal manual verification still needed

On an explicitly authorized candidate build, open a preview-only conversation using iPhone Mirroring or an external keyboard. No desktop pairing or live message is needed:

1. Type ordinary text and press Return. Expect the preview-only Send refusal, once, instead of an inserted newline.
2. Type a named slash prefix such as `/fr` and press Return. Expect completion without a send. Shift+Return must insert a newline, including inside a partial slash name.
3. Verify Command+Return and touch Send still reach the preview refusal. An empty draft must not send.
4. With a multistage input method active, Return must confirm the composition without sending; a later explicit Return can submit the finalized draft.

No physical-device control, installation, upload, live message or paid prompt is authorized by this test plan.
