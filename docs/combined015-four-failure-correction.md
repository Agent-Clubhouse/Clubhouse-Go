# Four-failure correction from frozen 015a319

This source slice starts at `015a31943d50a7b61bcad93a46a541ea5c5b62cc`.
Its approved plan is shared Git blob `1f8719d6b48b27e4f08529630b07fa18a58cc060`,
with the parent's subsequent explicit clip-versus-track clarification. The
original candidate remains frozen. This document records source preparation,
not a new execution result or visual acceptance.

## Original evidence and limits

The parent's original attachment/activity/details/configuration/drain map is
blob `ab2ad79dc653955a050a19e896df4da9a7a9d170`. All 110 original entries were
materialized only under this worktree's ignored `build/combined015-source-audit`
directory; each declared byte count and SHA-256 matched. No media was uploaded,
modified or added to the source bundle.

Derived-frame map `ce43f3e8f12635955c427fc884b4832135ba3168` contains four
full, unedited 750×1334 video-frame extracts. Their hashes were also verified.
These are **not original XCTest PNG attachments**. Requested end-minus-0.5s
times and actual sparse video sample times differ:

| Case | Actual / requested seconds | Frame blob |
|---|---|---|
| Idle | 9.54 / 15.573333333333334 | `7d2d7d491674d76590b2be60899d8415fd198034` |
| Standard working | 25.718333333333334 / 25.8 | `680786327721f3b3f3599961e502eab3983f7e6a` |
| AXXXL | 24.668333333333333 / 25.49 | `9b261a6f98ef242ba25912c33c4ae4a7c410a0b6` |
| AX recovery | 8.773333333333333 / 10.805 | `aa46c8c3cb2c433912d9b052a367f23409258919` |

Parent evidence reports Debug and binary ownership gate passing, then six of
ten UI methods passing. Configuration/activity records show each method ran
once, each launched once, serial execution and no test-iteration retry flags.
The idle method made one source `typeText` call, but XCTest internally retried
event synthesis as attempts 2 and 3. Helper `attempts: 1` and a single method
run do not erase those internal retries or establish focus timing. The shared
launch helper still adds `--ui-testing-fast`.

| Failure | Supported classification | Last observed boundary; later work untested |
|---|---|---|
| Idle typeText has no focus | Test menu-dismissal witness was insufficient | The permission submenu remained over the field. Its parent trigger disappearing did not prove dismissal. Typed draft and editing-row checks were not reached. |
| Standard working Cancel missing | Test assumed a native Cancel button | Typed row and Interrupt confirmation were reached. Native popover exported `PopoverDismissRegion`, not Cancel. Post-cancellation draft/image/keyboard-dismiss checks were not reached. |
| AXXXL Stop→Send gap 22.25 > 16 | Product layout violates retained contract | First empty stacked row failed. Approval review, image, typed and confirmation states were not reached. |
| AX recovery Operation inaccessible | Fixture-menu navigation failed before action | Operation existed below the visible menu; there was no Operation tap activity. Warning/connection/retry/Details/progress/Gamma checks were not reached. |

The separate original header screenshot `ef9fa9a49a3fd4de91dd5164d32a6b1b3a372c6e`
shows an additional visual failure despite its method passing. Header correction
belongs to the parent and is outside this slice.

## Narrow changes and failure gates

Only these four files change:

- `Annex/Annex/Companion/Views/CompanionConversationComposer.swift`
- `Annex/AnnexUITests/CompanionCompactComposerUITests.swift`
- `Annex/AnnexUITests/CompanionRecoveryIntegrationUITests.swift`
- This document.

The native field subtree, `AnyLayout`, memory, selection/focus hooks, Store
and authorization gates are unchanged. Header/caller/Root/Review/recovery
production code, content refs, shared UI support and the original native
diagnostic are unchanged.

### Idle: one dismissal action, then one focus action

Require one native collection containing the permissions trigger and one
collection globally. Conservatively exclude its entire exported frame
intersected with the actual main window. Choose one finite side rectangle
within the nav-to-tab/complete-input viewport, inset it by 12pt, prove the
point lies outside the menu, and tap it once. Fail if geometry or uniqueness
is missing. No editor tap is used to dismiss the menu.

Within the original single five-second dismissal budget, require the native
collection, permissions/model/effort triggers and all five permission-choice
identifiers absent together. Capture that state, then perform exactly one
editor focus tap. Require the existing AX keyboard-focus marker and one
actual keyboard before the original one source `typeText` call. There is no
extra focus tap, Show Keyboard setup, new focus wait or rescue path.

### Working: native cancellation without a destructive action

Preserve the one Interrupt tap, original title/action/refusal assertions,
draft, image and later keyboard-dismiss flow. Capture the actual confirmation
before cancellation. If native Cancel exists, require it unique/hittable and
tap once. Otherwise require one expected confirmation popover and one public
`PopoverDismissRegion`. Compute one interior point within that region and
the actual unobscured window, outside the entire popover. Tap once; never tap
the destructive action. Keyboard presence during confirmation is optional
because the native dialog can end editing; any exported input surfaces still
constrain the safe point.

Require title and destructive button absent together within a bounded five
seconds before downstream draft/image checks or the original distinct
post-dialog refocus. Preserve exact text/image counts and no preview error.
Missing or ambiguous cancellation geometry fails rather than trying another
route after an unsuccessful tap.

### Local keyboard geometry includes the accessory row

The retained original working hierarchy exports keys at y451, while
`inputView` and `SystemInputAssistantView` start at y407. Keys alone would
permit 44pt of actual occlusion. Local geometry intersects the actual main
window and app, excludes navigation/tab bars and the union of finite visible
Keyboard/inputView/SystemInputAssistantView frames. Multiple keyboards or
invalid geometry fail. Both editing-row and approval-decision checks now use
this complete occlusion boundary. All original 44pt, row alignment, editor
width, viewport, draft and image assertions remain.

### AX fixture menu: clipping frame and scroll track differ

Original hierarchy `9b0544dd0c11dc51735646899b7a49f0cd2efaca` places Fail at
y30…106.5, the menu's clipping ancestor at y20…540 and the scrollbar track at
y50…510. The exported collection extends to y687. Operation is y569…645.5.
The track safely constrains navigation, but is not the exact clipping edge:
requiring the first visible Fail item inside it would be impossible at the
top of scrolling.

After the original single menu-open attempt, require exactly one target and
one native collection globally/containing that target. Public `Other` queries
must contain both the exact item and that collection. Require finite enclosing
frames inside the main window and a unique smallest enclosing clipping frame;
equal duplicates are accepted, incomparable candidates are rejected. The full
window and collection frame are not fallback clipping bounds. No debug-text
parsing supplies action geometry.

The zero-drag path requires the whole target inside the actual clip and
hittable. Otherwise require finite vertical scrollbar frames that all agree
exactly. Intersect their vertical interval with the clip/window and use 12pt
interior endpoints for at most two geometry-directed content drags. Bound
each displacement by the interior gesture height. After every drag, re-query
item, menu, ancestors and track. Before the existing single checked item tap,
require the whole target inside both clip and conservative track, and
hittable. Missing targets/tracks, divergent duplicates, invalid geometry,
obstruction or unresolved navigation fail closed. No guessed heights, app
swipes, tap retries, fixture reordering, service shortcut or new timeout.
Later Select Gamma uses the same checked path; if native AX does not export
it sufficiently to identify the menu, that remains a failure rather than a
guessed navigation route.

### Product: only adjacent Stop/Send grouping

Place the existing Stop and Send nodes in one unconditional inner HStack.
At ordinary sizes retain 6pt group spacing and the original Send horizontal
padding (2pt assistive editing, otherwise 6pt). At accessibility sizes use
zero group spacing and zero extra Send horizontal padding. All existing
individual full44 frames/content shapes, regular glass/glyphs, action heights,
actions and enablement gates remain. Leading approval/config/Attach, trailing
dismiss and outer rail spacing remain in place. The <=16 gap assertion is
unchanged; actual native layout still requires allocated validation.

## Review selection and source verification

Future minimum selection, subject to parent/Dispatcher allocation:

| Exact `ClubhouseGoUITests/` method | Launch invocations | `waitAndTap` invocations on complete success path |
|---|---:|---:|
| `CompanionCompactComposerUITests/testIdleControlsStayCollapsedBeforeAndAfterTyping` | 1 | 1 |
| `CompanionCompactComposerUITests/testWorkingInterruptIsBesideSendAndOnlyRequestsConfirmation` | 1 | 3 |
| `CompanionCompactComposerUITests/testLargestTextWorkingAttachmentRowFits` | 1 | 5 |
| `CompanionRecoveryIntegrationUITests/testLargeTextKeepsFullErrorsSeparateWarningAndTargetDetailsReachable` | 1 | 13 |
| Total | 4 | 22 |

Every selected launch and `waitAndTap` call retains explicit attempts1.
One outside-menu tap replaces the misleading first editor tap. Each working
route still has one cancellation action and the original later focus/dismiss
actions. Each of the five AX recovery fixture calls adds zero to two content
drags before its existing single item tap, never a repeated tap. Existing
finite list/approval navigation remains unchanged. No assertion threshold,
existing timeout, allowance or original screenshot is relaxed or removed;
new screenshots retain the dismissed-menu and both native confirmations.

The normal recovery method shares the local fixture helper and therefore is
an affected path for source review, although the minimum failed-case selection
above does not repeat that previously passing method automatically. Its exact
Details reveal helper and all original assertions/captures remain unchanged.

Validation here is source parsing, original-assertion/helper comparison and
whitespace/diff review only. No build, SDK typecheck, test, simulator, app,
provider, install or workflow execution is authorized or claimed. Parent
independent review precedes any Go allocation; desktop's heavy slot is separate.

The three changed Swift files passed `swiftc -frontend -parse -D DEBUG`;
the production composer also passed parsing without DEBUG. `git diff --check`
passed. Source comparison preserved both original recovery case bodies and
the original Details navigation helper byte for byte. The production prefix,
suffix and Stop/Send actions/modifiers match the base after accounting only
for the approved group and AX padding expression. Two original assertion
lines are deliberately strengthened: the isolated parent-trigger dismissal
wait becomes the combined five-second collection/parent/choice witness, and
approval decision bottom containment uses full input occlusion instead of
keys alone. No recovery assertion line was removed or replaced.
