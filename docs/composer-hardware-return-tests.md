# Hardware Return in the chat composer (#309)

The composer previously offered only Command+Return for submission. The change adds unmodified hardware Return through the existing native input hook. Shift+Return inserts a newline at the native selection. Return first completes an active named slash prefix; bare `/` and fully spelled commands submit. Software Return and pasted multiline text retain their existing editing behavior. Touch Send and Command+Return retain their guarded store path.

The hook preserves the SwiftUI editor's native identity. It advertises commands before focus but validates focus, editability and marked-text state when activating them. Cached actions cannot confirm marked text or send from an unfocused field. The store continues to gate empty, offline, unsupported, resynchronizing and pending sends.

## Evidence and limits

`CompanionComposerReturnTests` hosts the real composer with a synthetic service. It discovers actual native key commands, resolves their target through UIKit, then invokes `sendAction(to: nil)` through the first-responder chain. It verifies single dispatch, pending protection, slash precedence, Shift+Return selection replacement, multiline insertion, marked-text preservation, and unrelated-field isolation. These tests establish handler and responder-chain behavior. They do not establish physical-keyboard or iPhone Mirroring event delivery, or a complete real IME interaction.

`CompanionHardwareKeyboardUITests` separately sends actual XCUI `typeKey(.return, modifierFlags:)` events in preview mode, with assertions for Return, Shift+Return, slash completion and retained Command+Return. These assertions are not replaced with `typeText("\n")` or direct action invocation. Initial iPhone and iPad simulator runs failed both Return completion and existing Command+Return submission, while touch Send, image/text paste and existing slash-navigation tests passed. The cause is unresolved; this is not classified as a harness-only failure. Original results are retained under `build/hardware-enter/` and summarized in the PR.

The PR must distinguish passing hosted contracts from actual-event failures. Do not claim the reported Mirroring problem is fixed solely from hosted tests, and do not relax the failing assertions or retry policy to obtain green CI.

## Minimal manual verification still needed

On an explicitly authorized candidate build, open a preview-only conversation using iPhone Mirroring or an external keyboard. No desktop pairing or live message is needed:

1. Type ordinary text and press Return. Expect the preview-only Send refusal, once, instead of an inserted newline.
2. Type a named slash prefix such as `/fr` and press Return. Expect completion without a send. Shift+Return must insert a newline, including inside a partial slash name.
3. Verify Command+Return and touch Send still reach the preview refusal. An empty draft must not send.
4. With a multistage input method active, Return must confirm the composition without sending; a later explicit Return can submit the finalized draft.

No physical-device control, installation, upload, live message or paid prompt is authorized by this test plan.
