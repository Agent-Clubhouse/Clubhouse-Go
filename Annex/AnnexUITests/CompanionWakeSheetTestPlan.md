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

## Assigned candidate validation

At exact `e7a938acbaaa4a4790321fd04ffeb66f5dccd7f9`, one Debug arm64
build-for-testing (`-jobs 4`, Xcode 26.0.1 / 17A400) passed in 46.365 seconds.
One serial invocation on a fresh owned iPhone 17 Pro / iOS 26.0 (23A343) ran
exactly three methods once. The xcresult has no repetition nodes; the log has
three unique test starts. Animations remained enabled; there was no test retry,
baseline repeat or focus rescue.

| Method | Result | Seconds |
| --- | --- | ---: |
| Existing project-page tapped-entry smoke | Passed | 55.169 |
| `testDirectTypeWithoutTap` | Failed at direct typing: no keyboard focus | 21.886 |
| `testDirectTypeWithoutTapAfterCancel` | Failed at FIRST whitespace entry: no keyboard focus | 21.292 |

No characters were delivered by the direct-entry cases. Cancel/reopen,
multiline retention and preview send were not reached in the second case.
XCTest internally attempts synthesis three times for a failing `typeText`; this
does not represent three test runs. The owned simulator was shut down/deleted
and its absence verified. No further runtime slot is authorized.

**Candidate insufficient; PR #313 held.** Two initial presentations failed on
this candidate/configuration. We did not run the baseline, so this does not
establish a candidate regression or a deterministic reproduction on main.

## Existing evidence and observation limits

The first failure's original 1206×2622 screenshots before typing and at teardown
are byte-identical: SHA-256
`4122375c454dcdecf0067b28c4f070f48c84025cffbc36242a4406813fbb9efc`.
They show the on-screen half-sheet and empty placeholder with no caret/keyboard.
Both AX dumps show disabled Wake and a field at `(34.6, 612.3, 332.8, 85.0)`.
Native `UIWindow.isKeyWindow`, `UIWindowScene.activationState`, responder identity
and the SwiftUI binding are absent. AX `Window (Main)` is not proof of key-window
ownership. The passing tapped case is a separate app launch of the same binary,
not a rescued failed instance, and has no before/after native lifecycle trace.

The preview root uses the normal SwiftUI WindowGroup. Without preview-feedback
flags it constructs no feedback presenter/runtime. The wake sheet contains one
native SwiftUI multiline TextField with no delegate or custom responder code.
Source and AX do not establish which native UITextField/UITextView subclass
backs it, or whether a different object owns first responder. There is no
evidence of a competing window, inactive scene, cancelled transition, or binding
reset; those remain values to measure, not explanations to assume.

Local evidence blobs (unreferenced objects, no upload): PNG
`af5034c388894dabac190337b1673eb654c2035d`; before-input AX
`fa3be2498d9399327a282835fbb61d7b501cfe42`; final AX
`237a9fdafe374682b641117a1d204e1fcdcc0c87`. Exact commands, generated xctestrun,
xcresult, attempt-check JSON and original attachment manifest remain under
ignored `build/issue246/validation-e7/`.

## Prepared observer (source only; separate from failed candidate)

The observer is compiled only for DEBUG simulator builds and allocated only
when BOTH `--companion-preview` and `--wake-focus-measurements` are present.
The dedicated UI tests append the second flag only if runner environment
`CLUBHOUSE_WAKE_FOCUS_MEASUREMENTS=1`. No root/composer/provider probe is changed.

Its transparent, noninteractive TextField-background anchor records:

- Monotonic uptime, sequence, SwiftUI appearance/focus-binding/scene changes.
- Child-controller will/is/did-appear, first four layouts, disappearance and
  anchor window/superview attachment. Child callbacks are correlated with the
  presenting controller chain; they alone do not assert sheet completion.
- Actual native UITextField/UITextView classes, identifier ancestry, attachment,
  enabled/editable/marked-text flags and first-responder state, without reading
  text, selections, placeholders, labels or delegates.
- Public scene activation, each window's key flag, native responder identities,
  controller presentation/transition flags, keyboard and editing notifications.

It records at most 96 snapshots during a 20-second event window, traversing at
most four scenes/eight windows/1024 views per snapshot, eight native inputs and
16 input ancestors. Layout recording stops after four boundaries. Truncation is
explicit. It has no polling, timer, focus write, delegate, swizzle, touch handler,
new window, text setter or notification userInfo dump. Subscriptions cancel on
dismantle or the first event exceeding the budget. If nothing happens after
20 seconds, subscriptions remain idle until dismantle; no deadline timer runs.
Both new UIKit classes retain MainActor teardown with additive ownership entries.

Full JSON is printed with `[wake-focus]`; the same records use unified-log
subsystem `com.Agent-Clubhouse.Go.wake-focus` (unified logs can truncate long
records, so preserve app stdout/xcresult console too). Object tokens are local
process identities, not persistent user or scene IDs. The observation itself
can perturb timing, and a native class/identifier match is reported rather than
assumed. An absent native input with a truncated scan is inconclusive.

When a new slot is explicitly assigned, propose one run with runner environment
enabled (`TEST_RUNNER_CLUBHOUSE_WAKE_FOCUS_MEASUREMENTS=1` on xcodebuild maps
to `CLUBHOUSE_WAKE_FOCUS_MEASUREMENTS=1` in the runner), selecting only `testDirectTypeWithoutTap` and the separately opt-in
`testMeasuredTappedEntryControl`. No automatic baseline repeat, no retry, no
keyboard wait and no failed-case rescue. The control performs one intentional
field tap in its own fresh launch. Both preserve complete value assertions.
Record whether the anchor window is key/foreground, the actual native input is
registered and eligible, and whether the binding ever becomes true before a
keyboard event. Compare the successful tapped control's event sequence.

If all attachment/key/scene/eligibility values are valid while the automatic
binding stays false, this narrows the boundary to default-focus evaluation or
scope; public observation still cannot prove why the focus engine ignored a
preference. If the binding becomes true then resets, correlate the reset with
the exact controller/window/responder event. If it stays true without native
first responder, inspect bridge/eligibility evidence. Do not turn any of these
branches into a delay/refocus workaround without evidence.

Observer status: source parsed and whitespace/JSON checked only. No compile,
binary ownership check, runtime measurement, IME test or new simulator run.
