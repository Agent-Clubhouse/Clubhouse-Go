# Bounded combined visual source preparation

Base: preserved `c5d577402159e319fc867461ad0ccc05417ec970`.
Scope: five UI-test files and this document. No product, shared
`UITestSupport`, native recovery diagnostic, ownership-policy, content or
recovery review-ref changes. This is source preparation, not an executed or
accepted visual matrix. The parent reviews the exact successor and selection
before any allocation.

## Exact ten-method selection and expanded call ledger

Every row below has **one** `launchApp` invocation with `attempts: 1`, including
launches reached through local helpers. Every selected `waitAndTap` invocation
also has one attempt; the sole parameterized site is smoke `openRiver`, which
forwards the selected caller's `attempts: 1`. Counts describe the complete
successful source path, not observed runtime actions. A helper may tap zero
times when its expected state already holds; none may retry a selected tap.

| Class / method (under `ClubhouseGoUITests`) | Launch calls | Expanded `waitAndTap` calls | Complete wait-and-tap path, including indirect calls |
| --- | ---: | ---: | --- |
| `CompanionCompactComposerUITests/testIdleControlsStayCollapsedBeforeAndAfterTyping` | 1 | 1 | Controls → permissions menu. |
| `CompanionCompactComposerUITests/testWorkingInterruptIsBesideSendAndOnlyRequestsConfirmation` | 1 | 3 | `workingRow(false)`: River → composer, attach → thumbnail, interrupt → confirmation. |
| `CompanionCompactComposerUITests/testLargestTextWorkingAttachmentRowFits` | 1 | 5 | `workingRow(true)`: River → composer; approval review → Close before editing; attach → thumbnail; approval review → Close while editing; interrupt → confirmation. |
| `CompanionChatHeaderVisualUITests/testDarkWorkingKeyboardDownAndUp` | 1 | 1 | Header → details. |
| `CompanionChatHeaderVisualUITests/testLightLongNameAccessibilityExpandedWithKeyboard` | 1 | 2 | Header → details, header closes details. |
| `CompanionChatHeaderVisualUITests/testIdleFallbackCustomImageVersionAndContextQuota` | 1 | 6 | Two image-version iterations each open fixture menu/select image (4), usage → context (1), plan limits (1). |
| `CompanionRecoveryIntegrationUITests/testFirstLoadProgressFailureDetailsRetryAndRecovery` | 1 | 6 | Fixture fail (menu/select: 2), next-success (menu/select: 2), Details (1), Details retry (1). |
| `CompanionRecoveryIntegrationUITests/testLargeTextKeepsFullErrorsSeparateWarningAndTargetDetailsReachable` | 1 | 13 | Fixture fail/operation/connection-failure/progress/select-gamma each menu/select (10); Alpha Details, Done, Gamma Details (3). The separate row retry is one existing direct tap. |
| `CompanionChatHeaderUITests/testReviewHasOneIdentityPrincipalWithPositionDisclosureAndUsage` | 1 | 5 | Open Review, disclose title, collapse title, usage → context, plan limits. |
| `CompanionPreviewSmokeTests/testChatControlsMenusAndPersistentApproval` | 1 | 8 | `openRiver(attempts: 1)` (1); level → permissions, permissions → Full access, Full access → confirmation, level → model, model → Haiku, level → effort, effort → Extra high (7). |
| **Total** | **10** | **50** | Six distinct selected launch call sites and 32 distinct selected wait-and-tap call sites expand through shared local helpers/loops. |

Composer's five wait-and-tap sites expand to 9 invocations, header visual's
seven sites to 9, recovery's seven sites to 19, Review's five sites to 5, and
smoke's eight selected sites to 8. Launch sites expand 2→3, 1→3, 1→2, 1→1,
1→1 respectively. Only the selected smoke caller passes one to `openRiver`;
its new optional argument defaults to the previous three attempts, so all
other smoke callers and methods keep their prior behavior. Other methods in
`CompanionChatHeaderUITests` likewise remain untouched.

## Preserved timing, setup and navigation boundaries

All original explicit waits and default per-attempt timeouts/allowances remain:
launch allowance 240 seconds, foreground wait 30 seconds, until-appears default
10 seconds, until-gone default 5 seconds, and each helper's final 2-second wait.
Smoke River keeps its explicit 15-second timeout; the seven selected smoke
menu transitions keep their explicit 5-second timeouts and messages. One
method invocation previously still allowed the helpers' default three launch
or tap attempts. Explicit one-attempt arguments now remove those retries;
they do not remove the final state check or extend a deadline.

`launchApp` still inherits `--ui-testing-fast` from unchanged shared support.
That disables UIKit animations in the fixture. These methods therefore cannot
establish production focus timing, animation timing or absence of focus
jitter. No keyboard/typeText/focus rescue was added or changed. Header visual's
existing composer tap and conditional **Keyboard → Show Keyboard** setup are
explicit separate user setup actions, with their existing 2/3/5-second waits.
Composer's existing refocus after cancelling Interrupt is also unchanged.

Idle composer's two existing field taps have distinct purposes: the first
dismisses the open controls menu, the second focuses the editor. A new bounded
5-second disappearance assertion sits between them; it must pass before the
focus tap. There is no blind repeated field tap or retry-until-focus loop.

Existing bounded navigation remains intact: River discovery/scroll limits,
the largest-text approval review's `scrollTo(...maxSwipes: 8)` for each decision
in both presentations, smoke's `scrollTo(always,...maxSwipes: 4)`, the native
status-bar reading gesture, and Review's original single horizontal drag.
These are navigation steps rather than repetitions of a failed action. This
source slice does not alter their geometry, bounds or selection semantics.

The normal recovery screenshot route now copies `revealDetailsRetry` **verbatim**
from `CompanionRecoveryXCUIDiagnosticTests` at this base, the previously proven
diagnostic helper. It is called once after full-error/target assertions and
the existing pre-scroll `full failure Details` capture, before the unchanged
strict hittability/width/height ≥44 checks and one Details-retry helper call.
The copied helper permits zero or one geometry-directed content drag, never a
blind retry, detent/grabber action, loop or extra wait. It checks one containing
ScrollView and sheet navigation bar, finite frames, whole-target viewport
containment, and re-reads the viewport after navigation. A new original
`full failure Details after content navigation` screenshot is retained before
the strict retry checks. The native diagnostic itself is unchanged. The
large-text recovery method does not call the navigation helper or gain another
row retry.

## Assertions, state matrix and original captures

No original assertion, source label, confirmation, draft/image check, viewport
or keyboard/AX state was removed or relaxed. Preserved examples include:

- Composer idle empty/unfocused and typed/focused; working empty, image-only,
  typed/focused and typed/unfocused at standard and largest accessibility size;
  enabled/hittable unobscured targets, strict 44-point bounds, approval text and
  decisions, unchanged draft/image count and pending approval after Close,
  Interrupt confirmation/Cancel, real dismiss-keyboard behavior and refusal
  text absence.
- Header dark Working keyboard down/native top/up/expanded; light long-name AX
  Large expanded/collapsed with keyboard; idle fallback and image versions 1/2;
  context editor and desktop quota/plan-limits route. Existing draft text and
  conditional keyboard setup stay unchanged.
- Recovery progress/failure/full multiline Details/retry/recovered transcript;
  separate operation warning under AX Large, connection retry, progress and
  Gamma's target-specific Details. Duplicate large panels remain forbidden.
- Review retains Maple 1 of 3 → Cedar 2 of 3, exactly one principal, no duplicate
  header, disclosure and context/plan-limits actions. Smoke retains desktop
  level/model/effort labels and notes, Full access confirmation, Always allow
  confirmation and explicit preview refusal after each attempted change.

All 34 original explicit captures on the complete selected success paths remain
unmodified, plus the one new recovery post-navigation capture (35 total):

| Source group | Preserved original captures |
| --- | --- |
| Compact composer (14) | Idle's two named row states; four working row states each at standard and largest text; Allow once/Deny review screenshots both before and during editing at largest text (4). |
| Header visual (11) | Four dark Working states, two light AX long-name states, idle fallback, two synthetic custom-image versions, context editor, desktop plan limits. |
| Recovery (6) | Compact first-load progress, history failure, full failure Details, recovered transcript, AX warning/connection retry, AX full connection/history Details. |
| Selected Review (0) | No original screenshot call in this method; no screenshot is invented for it. |
| Selected smoke (3) | Permission level menu, Model menu, Always allow confirmation. |

Captures remain original `app.screenshot()` attachments, without annotations,
crops or compositing. The new recovery capture uses the same helper. Counts
are planned source paths; a failure may stop before later captures. No image,
runtime or visual acceptance is claimed by source preparation.

## Verification and handoff

Swift parsing and `git diff --check` passed. Source comparison confirmed the
helper copy, retained original assertion lines, unchanged unselected Header
and smoke methods, and unchanged shared/native diagnostic files. The source
inventory confirmed six selected launch sites and 32 selected wait-and-tap
sites, expanding as the table records. These checks establish no SDK type or
runtime result. No SDK typecheck, app build, test, simulator, provider/model, install,
workflow dispatch or allocation occurs here. The parent selects the exact
successor and these ten methods for any later serial run; no test-iteration or
retry flags are implied by this document. Preserve the frozen base and any
actual attempts/results independently of these source counts. Content/PDF and
recovery seam branches remain unchanged; PDF UI is still deferred.
