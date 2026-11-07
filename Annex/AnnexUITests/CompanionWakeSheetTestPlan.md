# Wake autofocus (#246)

## Source and original artifact audit

Baseline: `origin/main` b17f9f80. `CompanionWakeSheet` binds one native multiline
`TextField` to one `FocusState<Bool>` and sets it in `Form.onAppear`. The same
closure initializes the sleeping-agent selection. There are no other focus
writes, delayed tasks, custom text input, or input delegates in this sheet.
`programmaticFocusState` is not a symbol in this source. Requesting focus and
observing the keyboard/caret are distinct; the issue contains no binding trace.

The existing `testProjectPageFinishedChangesAndWake` explicitly taps the field
before typing and verifies its entire value. That verifies tapped entry, not
initial autofocus. The new dedicated class never taps the message field and
keeps UIKit animations enabled, unlike `ReliableUITestCase.launchApp`.

Recovered [run 41469238552](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41469238552),
`test-results-0` artifact 13159351307 (187099728 bytes; SHA-256
`07edd9a65679b8f2c9cb3734e52b0d543ca4865be3c3f1e5ecf966ad24d7dfcd`).
The first attempt fails in 119.129 seconds; its retry passes in 81.303 seconds.
The log records Wake tapped at 69.10 s, a message-field existence check succeeding
by 75.26 s, and direct `typeText` at 79.69 s. XCTest's synthesis checks still find
no focused descendant at 92.45, 106.35 and 118.23 s. This is a sustained failure
after presentation, not sufficient evidence of a particular lifecycle race.

Failure hierarchy attachment `ECE36DC5-01C5-4729-8CBE-447507172EE1` shows the
half-screen sheet, the Juniper placeholder at `(38.7, 613.8, 324.5, 82.9)`, disabled
Wake, and no Keyboard or Keyboard Focused entry. No typed characters were
delivered. The recording attachment is `E8632769-43B5-4C89-A98D-0EDFF1BC5ADF`.
The downloaded xcresult, log, activity JSON, hierarchy and recording are under
the worktree's ignored `build/issue246/`; binary artifacts are not committed.

Apple documents that [`onAppear`](https://developer.apple.com/documentation/swiftui/view/onappear(perform:))
runs before the first rendered frame. Its [WWDC23 focus cookbook](https://developer.apple.com/videos/play/wwdc2023/10162/?time=681)
uses `.defaultFocus` on a sheet's list to support presenting the sheet and typing
immediately, available on iOS 17+. Replacing the imperative appearance write with
that default-focus preference is a supported candidate. It does not establish
the original failure's cause or prove reliability without runtime evidence.

## Cases and acceptance

1. `testDirectTypeWithoutTap`: present an animated sheet, require empty-send
   disabled and Juniper selected, directly type, assert every character, cancel.
2. `testDirectTypeWithoutTapAfterCancel`: directly enter whitespace/newline,
   require send disabled, cancel, reopen, directly enter a multiline draft with
   leading/trailing spaces, require the exact value and send enabled, then send
   once through the preview service. A newline must not submit the sheet.
3. Existing tapped-entry smoke case remains intact. Run it once alongside the
   dedicated cases after a coordinated simulator slot is assigned.
4. Preserve the native TextField, message binding, line limits, agent selection,
   interactive-dismiss rule, and canWake checks. Do not intercept Return, mutate
   or normalize a draft, or add repeated focus writes. The store's existing
   trimming on actual send remains its own behavior.
5. An IME composition check is separate from XCTest `typeText`: on an authorized
   simulator with a CJK keyboard, start marked text, change candidate selection,
   commit it, and cancel/reopen. Verify no unsolicited focus change interrupts
   composition and the committed text is exact. The ASCII cases do not claim to
   test marked text. No phone or live desktop/provider is required or authorized.

## Controlled validation / diagnostic fallback

No simulator or heavy build/test is authorized until the parent assigns its
serial slot. Source parsing and `git diff --check` can run first. Then build/test
the dedicated class with an owned simulator and no test retries, preserving the
runtime, device and software-keyboard configuration in the result. Compare the
test-only commit against the candidate on the same configuration. One pass of
either version does not reproduce or disprove the intermittent problem. Do not
run open-ended simulator repetition.

If both versions pass and stronger causal evidence is needed, use a separate,
temporary DEBUG-only wake harness: log monotonically ordered onAppear,
FocusState changes, UIViewController viewIsAppearing/viewDidAppear, window
attachment and keyboard will/did-show events (no draft content). Independently
gate the field's insertion until a test-controlled action after presentation,
and compare the existing appearance write with the default-focus preference.
The gate diagnoses a request made before its focus target is registered; it
does not itself reproduce the production hierarchy. Require the real sheet's
direct typing result as acceptance. A controller callback or arbitrary sleep is
not a substitute for that evidence. No probe or timing workaround is shipped.

Runtime status: pending coordinated slot; no claim of a reproduced/fixed race.
