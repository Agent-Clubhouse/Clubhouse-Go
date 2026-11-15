# Testing Clubhouse Go

The app links the local `ClubhouseTransport` Swift package, so the transport isn't compiled a second time under the app's default MainActor isolation. When you add a transport source file, add its synchronized-group membership exception in `Annex/Annex.xcodeproj/project.pbxproj` too, so it matches the package sources.

## Deterministic tests

These run in CI (`.github/workflows/ci.yml`) and need no physical device or signing identity.

```sh
swift test                                   # ClubhouseTransportTests, CompanionDomainTests
swift test --package-path Vendor/Framebriar  # vendored Framebriar SDK
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,name=<iPhone simulator>' \
  -derivedDataPath /tmp/clubhouse-go-dd CODE_SIGNING_ALLOWED=NO test
```

- `ClubhouseGoTests` holds `FramebriarIntegrationTests` and `DiagnosticPrivacyTests`.
- `ClubhouseGoUITests` launches the app in DEBUG fixture modes that never restore or contact a real paired desktop:
  - `--companion-preview`: `CompanionPreviewSmokeTests`
  - `--diagnostics-ui-testing`: `DiagnosticSettingsTests`
  - `--framebriar-shake-ui-testing`: `FramebriarShakeUITests` and `FramebriarShakeDiagnosticsUITests`. The diagnostics tests add `--framebriar-shake-unenrolled` (feedback not enrolled) and `--framebriar-shake-companion-layout` (Companion-like split view with navigation and a composer).

Saved Access uses the desktop's `access.version >= 1` contract and its per-CLI choices, labels and descriptions.
`CompanionAgentSheetsTests` covers create/settings pickers and elevated confirmation; package contract tests encode
every recorded Access request without exemptions. Saved changes apply at next start, while chat's known live level
wins in its existing badge only while the session is running. Ended sessions use saved Access.
`QA361AccessRegressionTests` covers Access-only snapshot refreshes in both open sheets and elevated confirmation
against the latest snapshot while cached settings are stale.
A desktop without this capability is read-only for saved Access, not a boolean fallback.

### Linked projects

The optional mobile v1 `projectLinks` capability is pinned at desktop
`7b9425f1f1b6f028541d99ee2908c2a945e49edd`. One connected capable desktop supplies the
network-wide full replacement; the phone never unions replicas or infers links from names or remotes.
References match the paired host's lowercased identity fingerprint and desktop-local project ID.
Unknown machines/projects are ignored. Unlinking and catalog removal split derived entries, and
groups omitted under `projectLinksTruncated` remain unlinked. No link state is persisted.

Home, search, project pages and Needs you share the derived groups. Machine sections/labels retain
qualified agent and action targets. A linked project is pinned if any member is pinned and idle
only when every member is idle; pin, inactive, terminal, Changes and Wake actions remain
machine-specific. New agent requires an explicit machine for a multi-member group. Review keeps
its existing filters and uses the linked project label.
Offline or failed members retain their labeled place in a linked Home group, but their cached
agent trees are hidden. Multiple projects on one machine use machine-plus-project option labels.

`AnnexContractProjectLinksTests` and `AnnexContractProjectLinksDomainTests` consume the desktop's
accepted/manual/Keep separate/unlink and sequenced replay fixtures, plus empty/truncated variants.
`CompanionLinkedProjectTests` covers identity collisions, unknown members, disappearance,
source failover, non-union replacement and Home state. `CompanionLinkedProjectUITests` uses
`--companion-preview-linked-projects` for two preview desktops, project navigation, explicit
spawn destination, Needs you and a desktop-reported unlink. It also checks a disconnected member
with `--companion-preview-dispatcher-controls`, and disambiguated project option submenus with
`--companion-preview-linked-projects-same-machine`. It never contacts a real desktop.

### Composer keyboards

`CompanionPinnedDecisionUITests` uses the DEBUG-only `--companion-preview-pinned-decisions` stream: two approvals
and one structured question arrive after streaming starts; decisions succeed only in this synthetic mode. It covers
continued visibility after 30 more tool updates, one actionable request, oldest-first paging, answering/dismissal,
Show in chat outside the transcript window, small-phone keyboard clearance, landscape, and AX5. Store failure tests
cover queue/resolution filtering, exact-request/session/epoch binding and reconnect-blocked explicit retries; hosted
approval review tests exercise the same production callbacks and submitting state. No fixture contacts a desktop.

`CompanionComposerReturnKeyTests` covers the platform-independent Return decision, modifiers, disabled sends,
composition and repeats. Hosted `CompanionComposerReturnTests` sends synthesized `UIPress`/`UIKey` events to the
real SwiftUI composer's native `UITextView`, covering send eligibility, slash precedence, Shift+Return selection
replacement and undo/redo, literal native edits, marked text, attachments, per-key repeat suppression
across overlapping Return/keypad Enter presses, and stable input/focus. The marked-text test uses
`UITextInput` to establish and commit composition; it is not proof of a real Japanese/Chinese input engine.

`CompanionHardwareKeyboardUITests` taps the actual on-screen Return key and requires newline/no-send behavior.
Its hardware Return and Shift+Return assertions retain strict expected failures tracked by #366: on the local
iPhone 17 Pro / iOS 26.0 simulator, `typeKey("\r")`, `.return`, `.enter` and modified Return do nothing through
either the focused field or application, even with that simulator's hardware-keyboard preference enabled.
Ordinary `typeKey("x")` and Shift+`"x"` insert text. A future successful Return injection fails the strict
expectation so it can be removed. Hosted native tests have no expected failures. Physical-keyboard and iPhone
Mirroring verification, including real IME confirmation, remain separate checks under #366.
Only the unavailable injection assertion allows continuation inside its expected-failure scope; ordinary typing,
draft, focus and no-send checks run outside it with normal failure handling. A Send-button control verifies the
same operation-error accessibility sentinel used by the hardware send and no-send checks.

### Writing UI tests for hosted runners

`CompanionImageAttachmentUITests` reveals the sent image with held drags inside the transcript's
`Other` accessibility container, which exports its visible viewport. The `ScrollView` frame extends
under the pinned request, composer and keyboard, so screen-fraction drags can scroll the footer
instead. The test requires the whole image above the composer and below the header before opening
its local preview; it keeps before-reveal screenshot/hierarchy attachments for diagnosis.

`CompanionPreviewSmokeTests/testWakeSheetAcceptsTextWithoutTapping` probes #246 with
animations enabled: it opens Wake with a message, types without tapping the field,
then requires the software keyboard, exact text and enabled Wake action. The existing
project-page smoke test separately covers explicitly tapped entry.

Composer remount tests wait for the actual SwiftUI appearance/disappearance callbacks before inspecting saved
selection. History delivery tests wait for the initial native offset and the final history revision/bottom layout,
not a fixed settling sleep. The session-model OCR helper accepts a populated form even when it fits on iPad.
Landscape header tests require the composer actions to remain inside the keyboard's editing viewport; reserving
speculative transcript space must not clip the footer. Package tests also cover bounded restoration exhaustion,
generation/navigation cancellation, and the preview terminal's edits, interrupts and scoped size feedback.

### Unicode focus integrity (#272)

On an owned iPhone 17 simulator running iOS 26.0 (23A343), Xcode 26.0.1 (17A400), Swift 6.2,
an immediate-after-mount focus request to the real `CompanionConversationComposer` placed its native caret
at UTF-16 offset 1 in five separate one-grapheme drafts. Inserting ASCII split the first surrogate pair:
the native editor, `store.drafts` and the submitted service request all contained replacement characters.
Removing only the initial-selection fix reproduces those byte mismatches again. This is a component defect;
**no full-app user path reproduced surrogate splitting in the bounded investigation on that simulator**.
No physical iPhone, iPad, other iOS version, live desktop or real tap on a phone was tested.

The composer now supplies `TextSelection(insertionPoint: draft.endIndex)` before a programmatic focus request
only when its selection is nil. Existing user selections and slash-command selections are untouched.
This avoids an invalid initial caret; it does not repair text, delay focus, retry typing, change send behavior,
or apply a workaround to other SwiftUI inputs. It does not claim to fix #234's earlier unclassified input
delivery or #306's already-corrected preview reveal.

`CompanionUnicodeFocusTests` hosts the production composer, requests focus immediately after its appearance,
and checks native UTF-8, store UTF-8 and actual service-request UTF-8. Its five drafts cover emoji, a ZWJ sequence,
a flag, a skin-tone sequence and astral CJK. It also checks Unicode typing after send and preservation of a
user-selected whole grapheme across dismissal/refocus. The test never sets the initial caret.

`CompanionUnicodeFocusUITests` keeps byte-exact coverage of the actual app paths:

| Input/path | Coverage |
| --- | --- |
| Created-agent composer | Real **Wake with a message** button with five separate preloaded drafts, animations enabled, and application-level typing without a field tap; exact sent request |
| Composer user tap and send | Explicit end tap; exact draft and sent request |
| Composer slash picking | Unicode prefix, real menu pick/refocus, further typing and exact sent request |
| Composer lifecycle | Review sheet presentation/dismissal, Home/reactivation, rotation, further typing and send |
| Wake sheet | Empty-draft autofocus, Unicode entry, Home/reactivation, rotation, exact wake/send request; Cancel and composer remount preserve an existing draft |
| Quick agent | Older-desktop quick-only autofocus, Unicode entry, Home/reactivation, rotation, exact spawn request and dismissal |
| Search | Search-tab/native-search-field tap, Unicode query, Home/reactivation, rotation and further typing |
| Agent name | Existing/drafted name, explicit end tap, Home/reactivation, rotation, exact rename request and sheet dismissal |
| Dispatcher name | Explicit end tap, Unicode typing, Home/reactivation, rotation, exact rename request and sheet dismissal |
| Review answer | Real free-text question, user tap, Home/reactivation, rotation, exact answer request and dismissal |
| Terminal | Native mount autofocus, keyboard toggle, Home/reactivation, rotation and exact input bytes using the existing preview input audit |

The source inventory found no composer autofocus after send or scene reactivation: send retains focus, while
the created notice requests it and slash picking supplies an explicit selection. Wake and quick-agent sheets
request focus on appearance, starting with empty text. Search uses `.searchable`; settings names, the phone's
name, pairing fields and Review answer fields have no explicit programmatic focus-to-edit path. Pairing only
clears focus after inspection. Terminal input is a separate native `UIKeyInput`, not a SwiftUI draft editor.

The DEBUG-only `--companion-preview-unicode-focus` fixture seeds a synthetic draft with
`COMPANION_UNICODE_DRAFT` and compares outgoing request UTF-8 against `COMPANION_UNICODE_EXPECTED`.
Its visible refusal says whether the request bytes match; it never contacts a desktop or pretends delivery
succeeded. `--companion-preview-unicode-quick` supplies the older quick-only desktop capability.
All test typing occurs once, and predicate waits require the exact expected value, never a shortened string
or replacement-character tolerance.
The original #414 broad validation run passed all hosted cases and every other selected UI case, but failed the
Dispatcher rotation assertion when its entire draft reset to the saved name. That historical run is not reported
as passing. The #413 fix below restores the rotation step without changing its byte-exact assertions.

### Dispatcher settings draft lifetime (#413)

The Behavior section's initial settings observer ran again after rotation or scrolling the lazy Form section
offscreen and back. It unconditionally reapplied all three desktop text values, even when the settings were
unchanged. Restoring just that observer reproduces both failures; its bounded diagnostic trace observes equal
old/new settings with a pending name immediately before the overwrite.

The enclosing `CompanionAgentSettingsForm` now owns name, emoji and personality drafts, their saved baselines,
and loading/observation outside the lazy sections. Initialization belongs to that form presentation; section
remounts never initialize drafts. Closing without submitting still discards edits, and reopening starts from
the current desktop values.

**Concurrent desktop-change policy:** an untouched field follows the desktop. A pending local field keeps its
exact UTF-8 bytes and shows “The [field] changed on the desktop. Your unsaved edit is kept.” Repeated settings,
usage changes, and saves of unrelated controls never discard pending fields. An incoming value matching the
draft's exact bytes acknowledges it, including an NFC-to-NFD acknowledgement: both form observation and live
service deduplication include the text fields' UTF-8 bytes rather than relying solely on String equality.
Explicit submit, emoji clear, personality preset selection or personality Revert accepts the desktop result
for that field only, including its normalization/limits. Submitting an emoji that trims to its saved value
accepts that value without a command. A refused save retains the existing visible error/revert convention for
the submitted field, without resetting other pending drafts. This follows ordinary agent settings' existing
preserve-dirty-fields-on-refresh convention and adds a visible conflict notice.

Command receipts acknowledge only their submitted text field, never the older values of unrelated clean fields.
The live service publishes a receipt if it includes every settings component change observed while the command
was in flight, so an unrelated confirmation-token refresh does not hide a successful Behavior/model/color save.
If any changed component conflicts (including byte-distinct text), it performs one authoritative settings read
instead of publishing the older receipt. That authoritative result is also returned to the save caller, so the
submitted-field acknowledgement cannot mark a superseded receipt value clean. This does not retry the command;
read failures remain visible errors.
Without a server revision this does not establish a total ordering of all concurrent reads and events.
Draft baselines are keyed to the desktop's
`settings.agentID`: a replacement Dispatcher resets all three drafts to its saved values rather than carrying
edits intended for the deleted agent. Receipts for the previous agent cannot acknowledge the replacement.

`CompanionDispatcherSettingsDraftTests` hosts the production settings sheet with the in-memory preview service:
genuine desktop name changes update an untouched native editor even while Behavior is offscreen, while the same
snapshot updates a clean emoji without overwriting an edited name. Focused state cases cover every text draft,
unrelated saves, remote conflicts, acknowledgement and canonically equivalent but byte-distinct edits.
Native regressions additionally submit the normalized emoji no-op and hold a real name save while delivering
a newer clean emoji, then release the older receipt. State coverage checks agent replacement and an old-agent
receipt. Live-adapter contract coverage requires exact NFC/NFD acknowledgements for all three text fields and
rejects publication of a held old receipt over an intervening settings read, and requires a legitimate Behavior
receipt carrying refreshed confirmation tokens to reach the visible service snapshot without an extra read.
Same-field conflict coverage requires the caller to receive the authoritative name after exactly one read.
A hosted native regression routes the real submit callback through the live adapter with a held scripted
transport receipt; both the store and editor must show the newer authoritative name after completion.
These boundary regressions use
explicit callback/predicate expectations rather than fixed settling delays; restoring each old boundary fails
its focused regression.
`CompanionDispatcherUITests` checks lazy-section scrolling, Behavior/model saves with a pending name, actual
name/emoji/personality saves, rotation of the other text fields, and fresh sheet presentation.
`CompanionUnicodeFocusUITests` again checks rotation while editing the Dispatcher name, further typing and the
exact rename request using #414's emoji, ZWJ, flag, skin-tone and astral-CJK corpus.
Behavior, models, color and personality presets are server-backed immediate-save controls rather than local
drafts; the ordinary agent form already owns its text drafts outside lazy sections. These checks use only the
preview desktop on iPhone 17 / iOS 26.0; they do not establish physical-device or other-runtime behavior.

### Unresolved Wake-sheet autofocus (#246)

The original hosted failure remains **unresolved**, not fixed by #414 or the passing #372 probe.
Run `41469238552`, preview job `125374151856`, used iPhone 17 / iOS 26.5 (23F77),
Xcode 26.5 (17F42). Its surviving job log shows Wake tapped at 69.10 s, an empty visible
`wake-message`, and XCTest reporting no focused descendant through 118.23 s; the second whole-test
attempt passed. The artifact API now lists zero artifacts and `gh run download` cannot retrieve
`test-results-0`. Neither the retained log nor the original issue's recording/hierarchy establishes
whether UIKit ever became first responder, whether a keyboard frame appeared earlier, or whether
presentation timing caused the loss. A presentation/focus race remains a hypothesis.

#414 checks exact Unicode input, Home/reactivation, rotation and wake/send, but its Wake-sheet case
uses `launchApp` and thus `--ui-testing-fast` (animations disabled). Its animated created-notice
case focuses the conversation composer, not this sheet. #372's separate no-tap sheet probe does
enable animations. The failed, unmerged #313 `.defaultFocus` candidate is not applied.

`CompanionWakeFocusUITests` adds bounded, animation-enabled diagnostic scenarios: three consecutive
presentations, presentation after Home/reactivation, rotation while editing, landscape presentation,
and return to portrait. Each presentation uses one checked Wake-button center tap and one application-level
typing operation, never a field tap, retry, sleep or focus rescue. Exact text, software keyboard,
enabled Wake and cancellation are required. Monotonic `WAKE_FOCUS_UI` markers perform no AX queries;
failure-only attachments retain the hierarchy/screenshot. A prototype foreground attempt opened
Terminal instead: its synthesized point (317.23, 239.60) was outside Wake's final frame
(206, 174, 180, 46.3). That failed bundle is retained, not counted as a missing-keyboard repro.
The checked center avoids that off-target automation point; it does not change application focus.

`CompanionWakeFocusTests` separately hosts the production sheet with normal and 0.1 window-layer
speeds. The slow case must take over two seconds; it checks native first-responder/window
ownership through completed presentation without forcing focus. This is component timing coverage,
not the full application's sheet hierarchy or a regression/revert proof of the hosted defect.

For a bounded native trace, launch the Debug app with **both** `--companion-preview` and
`--companion-preview-wake-focus-diagnostics`. Up to 64 samples per presentation record focus-binding
observations, native editing notifications, attached native inputs' responder/window state, key-window
and scene lifecycle, presentation completion, and keyboard frames/durations. Producers capture closed
typed records (at most eight windows, 256 visited views and 16 inputs per window) and append to the
shared `CompanionDiagnosticTrace` 64-slot ring under its short lock. They perform no encoding, output
or writer scheduling on MainActor. Preview setup starts the writer through an `@concurrent` function;
only its utility queue encodes JSON and writes through an independently opened `O_NONBLOCK` descriptor.
An unavailable/full writer drops records and coalesces a numeric drop count; it never falls back to
blocking stdout. The 64-sample presentation cap remains separate from the ring bound.
Window scans start at the top presented controller, not the underlying project hierarchy; native
editing notifications also capture their exact input object's closed metadata independently of the scan.
No message content is read, no view is inserted and no focus is changed. The selector observer owns only
value metadata and the Sendable writer; its teardown review is recorded in the deinit policy.
The UI diagnostic case exercises this opt-in path;
other scenario tests leave native diagnostics off. Export the app's stdout with
`xcrun xcresulttool export diagnostics --path <result.xcresult> --output-path <directory>`:
the `WAKE_FOCUS` JSON lines are in `StandardOutputAndStandardError-com.Agent-Clubhouse.Go.txt`,
not necessarily the `xcodebuild` console. Records contain closed event cases, numeric OS-version
components, native input kinds and capture-time elapsed seconds; output order/timing must not be used
as callback timing. A nonzero drop count or a missing output descriptor limits what the trace proves;
a partial nonblocking write can leave a truncated JSON line, which must be treated as lost.

The initial revision's passing iPhone 17 / iOS 26.0 trace observed the assignment during presentation before
an attached input was found, completion at 0.661 s, native begin-editing at 0.738 s and a software
keyboard did-show frame at 1.215 s. The iPad trace observed those latter events at 0.669/0.757/1.224 s.
Their 20/18 samples stayed within the cap and contained no message text. These demonstrate successful
deferred focus in those attempts, not the failed runtime's mechanism. That revision used synchronous
stdout and could perturb the observed timing; the revised producer path uses the nonblocking writer above.
Local Xcode 26.0.1 (17A400) has no iOS 26.5 runtime.
Hardware-keyboard connect/disconnect was not driven: supported `simctl` IO exposes no such control,
and shared Simulator preferences were not changed. `GCKeyboard.coalesced` is logged only as
`hardwareKeyboardReported`; XCTest injection and a software keyboard appearing do not establish
an actual connected/disconnected hardware-keyboard matrix.

Bounded results from main `d20a5a8d`, Debug, two jobs and serial testing, without automatic retries:

| Owned iOS 26.0 (23A343) coverage | Result |
| --- | --- |
| iPhone 17, unchanged baseline: animated probe, tapped project path, Unicode Wake lifecycle/send and cancel/draft preservation | Four methods, three iterations each: 12 passing executions |
| iPhone 17, selected existing Wake methods plus new animated scenarios | 7 passed; strict xcresult verification passed |
| iPhone 17, entire Smoke/Unicode/Wake diagnostic UI classes | **40 passed, 1 failed**: untouched Details-to-settings scrolling assertion; strict verifier rejected this bundle, no retry |
| Final-source iPhone hosted bundle plus opt-in native-diagnostic UI case | 155 passed, 3 existing skips; strict verification passed |
| Final-source iPad (A16), same seven UI methods plus normal/slow native probe | 8 passed; strict verification passed |

The broad class run preceded only the final value-only observer teardown and slow-probe threshold
tightening; final-source hosted/diagnostic and iPad runs requalified those changes. The final normal/slow
native presentation probes took 1.08/6.08 s on iPhone and 1.17/6.17 s on iPad. Neither device reproduced
the reported missing keyboard. The full UI-class gate is not claimed green. The owned phone was
deleted before the iPad was created; both exact simulator UUIDs were deleted and their absence verified.

The hosted `testBlockedStdoutNeverDelaysWakeDiagnosticProducers` redirects the actual stdout descriptor
to a full blocking pipe, with a one-second background rescue. It exercises appearance, focus observation,
native keyboard notification and more than 64 capture attempts, requiring producers to finish within
250 ms and retaining exactly 64 samples. The unavailable independent PTY must drop all records rather
than fall back to stdout. Reintroducing synchronous `print` failed that duration assertion at 1.096 s;
the print was removed before final qualification. This regression prevents diagnostic-induced blocking,
not the still-unreproduced #246 defect.

After rebasing onto `617e8ba1`, the revised writer passed the hosted bundle (160 passed, 3 existing skips),
the seven affected Wake UI cases (7 passed), strict xcresult verification for both bundles, all 20 deinit
script tests and the binary gate (33 ARC-only, 1 deferred-main-actor, 19 isolated paths). The metadata
regression also verifies the native notification input's closed output shape and excludes a populated
synthetic draft. The exported UI trace retained native first-responder/window and keyboard metadata;
17 records were intact and three writes were reported dropped, including one truncated JSON line.
Those losses are not interpreted as absent native events. Owned simulators were used sequentially,
deleted by exact UUID and verified absent. No focus fix or new #246 reproduction is claimed.

Next capture: run the animated no-tap case on the original 26.5 (23F77) configuration without automatic
test retries, retain its xcresult/recording and app stdout before artifact expiry, and correlate
`focusRequested`, presentation completion, native begin/end editing, scene/key-window ownership and
keyboard did-show/frame events. Also record the actual hardware-keyboard connection and software-keyboard
toggle state. Without a failure-side trace or a controlled reproduction, no focus fix is justified.

The two `CompanionAgentTreeUITests` methods use one unsuppressed initial launch
attempt and assert their behavior-completion milestones during teardown (#327).
A launch-only result cannot satisfy the completion check. Their existing navigation,
intentional preference relaunch, assertions and time limits are unchanged.
They emit monotonic `AGENT_TREE_PHASE` markers before major operations and keep an
`AgentTree phase timeline` attachment. Markers perform no AX queries and remain in
stdout if a timed-out runner cannot finish an attachment.

#### Unresolved agent-row long presses: #247

The investigation starts from unchanged app code at `961a944d`. **No root cause or
product fix is established.** The issue includes recorded 1.2-second presses at
both the row center and the visible name that navigate to chat on iOS 26.5.
In particular, the name failure after #250 has the same checked point and row
frame as its passing retry; changing a test's selector does not fix this behavior.

The historical job logs remain downloadable. The
[center failure](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41469238552/job/125374151856)
requests one 1.2-second press, then spends about 32.4 seconds in the post-event
idle wait; the passing retry spends about 0.06 seconds there. The
[name failure](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41487601605/job/125427668261)
requests `(104.5, 493.8333)` within row `(16, 466.6667, 370, 74.3333)` on both
attempts. Its synthesis activity takes longer on failure, but these framework
activity timings do not establish the delivered touch duration, hit view,
recognizer state, or cause. The helper-settings and quota job logs also retain
their failed first presses and passing retries. All four referenced runs now
list zero artifacts; the named artifact IDs return 404. The original recordings
and failure hierarchies were therefore unavailable for independent reinspection.
Their reported chat-navigation outcomes remain evidence recorded in #247, not
newly observed failures in this investigation.

**Gesture composition:** Home and the project agent list share
`CompanionAgentTreeNavigationRow`: an outer HStack contains a value-based
`NavigationLink` and, for parents, a separate borderless helper-disclosure Button.
The link's `CompanionAgentListRow` label applies `CompanionAgentMenu.contextMenu`
to its inner HStack after vertical padding and accessibility combination.
There is no custom row `onTapGesture`, simultaneous/high-priority gesture, or
agent-tree swipe action. The list style is `insetGrouped`; the project page's
finished-run swipe actions belong to different rows. Dispatcher instead wraps
the same inner menu row in a plain Button. This is a structural difference
between navigation and menu targets, not proof of competing recognizers.

Temporary, opt-in geometry observations measured the inner menu and outer link
in global coordinates without installing a gesture. On iPhone 17 Pro / iOS 26.0
(`23A343`), Xcode 26.0.1 (`17A400`), the Home Juniper frames were:

| Target | Frame `(x, y, width, height)` |
| --- | --- |
| AX/List row | `(16, 466.6667, 370, 74.3333)` |
| NavigationLink layout | `(32, 481.6667, 338, 44.3333)` |
| Inner context-menu layout | `(32, 481.6667, 211.6667, 44.3333)` |

| Single-press point | Containment in measured layout frames | Observed outcome |
| --- | --- | --- |
| Center `(201, 503.8333)` | Row, link, menu | Menu |
| Name `(104.5, 493.8333)` | Row, link, menu | Menu |
| Avatar `(48, 503.8333)` | Row, link, menu | Menu |
| Interior gap `(293.5, 503.8333)` | Row and link, outside menu | Menu |
| Trailing `(374, 503.8333)` | Row only | Menu |
| Top inset `(201, 467.6667)` | Row only | Menu |
| Bottom inset `(201, 540)` | Row only | Menu |
| Leading inset `(17, 503.8333)` | Row only | Menu |

The project row has the same dimensions, shifted down by 173.3333 points, with
the same containment and outcomes. Each surface received one real
`XCUICoordinate.press(forDuration:)` at center/name/avatar/trailing for
each of 0.6, 1.0 and 1.5 seconds, plus the four inset/interior-gap presses at
1.2 seconds. Three additional center and three name presses at 1.2 seconds
followed River -> Agent details -> Agent settings -> Back -> Done -> Home.
All **38/38** opened menus; neither navigation nor an unclassified result
occurred. Separate normal center taps opened chat in Home and the project.
Every press had a checked, fully visible row and retained outcome screenshot;
there were no press or test retries. These runs used the existing preview
fixture and `--ui-testing-fast`, as the affected CI tests do, never a desktop.

On a private iPad Pro 11-inch (M4), the same 26.0 matrix also opened menus
**38/38**, with both normal taps navigating. The typical Home row was
`(20, 827.5, 794, 74.5)`, its link `(40, 842.5, 754, 44.5)`, and its inner
menu `(40, 842.5, 211.5, 44.5)`. The typical project row started at `y=862`.
Scrolling changed some rows' y origin, not their measured insets or dimensions:
the link/menu began 20 points right and 15 points below that attempt's row
origin. The stored per-attempt row and geometry logs retain those differences.

| iPad point | Containment in measured layout frames | Observed outcome |
| --- | --- | --- |
| Center `(417, row.midY)` | Row and link, outside menu | Menu |
| Name `(112.5, name.midY)` | Row, link, menu | Menu |
| Avatar `(56, row.midY)` | Row, link, menu | Menu |
| Interior gap `(615.5, row.midY)` | Row and link, outside menu | Menu |
| Trailing `(802, row.midY)` | Row only | Menu |
| Top `(417, row.minY + 1)` | Row only | Menu |
| Bottom `(417, row.maxY - 1)` | Row only | Menu |
| Leading `(21, row.midY)` | Row only | Menu |

After removing the geometry observations, each device repeated the eight
inset/interior-gap presses, six history presses and both normal taps. All
**14/14** presses per device opened menus, and both taps navigated. Across both
passes, that is **52/52** diagnostic presses and **4/4** normal taps per device;
the observations are not necessary for those successful outcomes.

The uninstrumented iPhone run passed all 60 tests in
`CompanionAgentTreeUITests`, `CompanionAgentSheetsTests`,
`CompanionPreviewSmokeTests`, `CompanionContextWindowUITests`,
`CompanionAutoQuotaUITests` and `CompanionDispatcherUITests`, plus the three
temporary control methods: **63/63** in 1743.055 seconds. The iPad baseline
passed both tree tests, sleeping-agent settings, sessionless-agent details and
the three controls: **7/7** in 392.576 seconds. All five result bundles
(`iphone-probe`, `iphone-gaps`, `iphone-baseline-ui`, `ipad-probe`,
`ipad-baseline-ui`, under `build/go-247/`, each with `.xcresult`) passed
`python3 scripts/verify-xcresult.py <xcresult> ClubhouseGoUITests --no-retries-in ClubhouseGoUITests`.
The temporary test and geometry observations were removed, rather than adding
a non-reproducing diagnostic matrix to normal CI.

The padding hypothesis is therefore not a deterministic explanation on this
26.0 configuration: even points outside both measured SwiftUI layout frames
open the menu. A layout frame must not be treated as the native menu's hit
region. This does not rule out version-dependent routing or an intermittent
recognition failure on 26.5, which is not installed locally. It also does not
establish that an OS difference, runner timing, or prior navigation causes the
failure.

Keep #247 open. A matched 26.5 recurrence needs the full event path and actual
touch timestamps, native hit-view/interaction ownership, recognizer transitions,
and row lifetime/layout changes through touch-up, correlated with app/runner
responsiveness. A synthesis activity's duration or the eventual navigation alone
cannot distinguish those mechanisms. No physical-device test was performed.
There is no proven fix to regression-test or revert-prove; production gestures,
accessibility actions, test selectors and retry policies remain unchanged.

#### Unresolved hosted investigations: #308 and #386

The artifact-led pass on main `847225b2` did **not** establish a fixing change for
either issue. Three unchanged, serial iterations on a private iPhone 17 / iOS 26.0
passed each test: agent tree 38.619/38.649/38.026 s; pinch
19.477/19.216/19.227 s. Every pinch changed 100% to 183% zoom and 4,088,066
of 8,596,368 channels. These results, like the unchanged 27/27 hosted feedback
rerun, are not a root-cause or fixedness proof.

| Retained failure | Mechanism observed | What remains unknown |
| --- | --- | --- |
| #308, [run 43458103774](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/43458103774), `test-results-4` / artifact 14061767779 | Initial `waitForExistence(timeout: 2)` takes 53.73 s: the runner cancels an AX query, then an internal query takes 30.15 s and its framework retry takes 20.13 s. Initial assertions finish at 135.96 s and persisted assertions at 173.27 s. River's checked center tap reaches the main window, but its main-loop idle acknowledgment arrives about 82 s late. XCTest spends 60.05 s waiting for it; the final return exceeds the 240 s allowance at 272.602 s. The next execution fails termination in 60.358 s. | The retained late spindump shows app disk-image page-in I/O waits and runner AX/quiescence waits, but does not cover the initial 53.73 s AX delay or establish the whole stall's cause. A SwiftUI scroll-geometry fault and a UIKit system-gesture gate blocked for 81.8358465 s occur near recovery; neither proves what caused the stall. |
| #386, [run 43478779969 attempt 1](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/43478779969/attempts/1), artifact 14079946147 | The pinch contains two down/move/up paths inside the canvas, yet rendered pixels and AX stay at 100%. The app's unified log records UIEvents dispatched to its main window with `ignoreInteractionEvents: 0` and gesture actions. Six later Settings swipes, each about 0.55-0.62 s, similarly dispatch events and gesture actions in a fresh PID while the form stays at its initial position. | Window delivery is proven; delivery to the intended hit view, actual touch identities/count, individual recognizer states and native scroll offsets are not recorded. The pinch's temporal precedence does not prove it corrupts simulator touch state. |

The #308 recording payload is `Unexpected Error: Finished test run with pending
attachment.`, not playable video. Its hierarchy still has the reachable River row
inside the content band. #386's retained canvas images, recordings and retry
hierarchies rule out an AX-only stale zoom value and persistent editor process
state; navigation taps work, and expected Settings controls are below the fold.
The app's AX snapshot captures around the failed pinch take 0.08-0.10 s, unlike
#308's stalled work. The #308 artifact does contain XCTest's 8.16 MB Spindump
attachment, `DBE575F3-F0BB-40B1-8F9E-BCC376847F28.txt`, sampled at
17:05:46.897-17:05:51.902 UTC. It reports 267 samples over 2.93 s, 3 active CPUs
and 8.526 s total CPU, with 0.048 s in the runner and 0.012 s in the app.
The app's main-thread stacks traverse SwiftUI navigation and preference evaluation,
named vector glyph / CoreUI asset loading, then APFS page-in / AppleDiskImages I/O
waits; the runner shows AX query and quiescence waits. This points to disk-image
page-in I/O at that late sampled moment, not proof of the failure's root cause.
It does not cover the initial 53.73 s AX delay or provide a CPU/load time series
across the whole stall, so contention across that interval remains unresolved.

The #308 SwiftUI scroll-geometry fault also occurs once on each successful local
River navigation. A fourth run traced the only `onScrollGeometryChange` handler:
the fault occurs during history/transition resizing while reading-position
recording is gated off, follow/bottom state stays true, and the geometry handler's
`scrollTo` branch never runs. A fifth controlled run temporarily returned before
**all** geometry-handler writes and still emitted the same fault. This rules out
those handler writes as a necessary cause of the locally reproduced warning,
not every possible cause of the hosted stall. Both temporary probes were removed;
no production scrolling logic changed.

Keep both issues open. On the next hosted recurrence, retain app, test-runner and
simulator-service stack samples during both the initial AX delay and delayed
main-loop idle interval, plus timestamped CPU/load and disk-I/O measurements across
the stall. Correlate those intervals with asset-loading and disk-image page-in
waits rather than relying on the existing late sample alone. For #386,
fixture-only native event instrumentation would need touch phase/count, hit-view
identity, pan/pinch recognizer state, `isScrollEnabled`, zoom scale and content
offset, without consuming or modifying events. Window-dispatch logs alone cannot
settle recognizer routing. The Settings reveal now retains rendered before/after
screenshots **only when it fails**, without another AX traversal. No retries,
sleeps, allowance changes, rescue gestures or assertion exemptions were added.

Use exact artifact IDs when a rerun creates duplicate artifact names:
`gh run download` can select the newer `test-results-5` instead of the failed one.
Export repeated-test attachments with an explicit test identifier, without
`--only-failures` (that option exports nothing for this failing feedback bundle).
`xcresulttool get test-results activities` and `xcresulttool export diagnostics`
provide the activity trees and app/runner unified logs. Sparse recordings can
return an earlier presentation timestamp even with zero image-generator tolerance;
check the actual timestamp rather than calling an extracted frame exact.

CI also reuses the simulator build in a separate **iPad hosted tests + UI smoke** lane (#284).
It creates an iPad Pro 11-inch (M4) on the newest installed iOS runtime selected by the Xcode setup,
runs the entire `ClubhouseGoTests` bundle plus the two feedback confirmation tests and
`CompanionAgentTreeUITests/testProjectUsesSameTreeAndCrossProjectCaption`, then deletes the device.
Both bundles must pass without retries. This targeted lane leaves the iPhone shards unchanged and
avoids duplicating the full UI suite; budget roughly 8-15 additional macOS runner minutes per app change
(artifact transfer, simulator boot, hosted tests and three UI tests), running alongside the iPhone shards.

The #284 failures were test assumptions, not unreachable iPad product controls: confirmation dialogs
use popovers, iPad top tabs are not inside `app.tabBars`, and whole-screen swipes can hide a row behind
a short modal's navigation bar. Feedback tests select the titled popover before its containing sheet
and reveal rows inside the actual form viewport. The five-live-item hosted history fixture sizes its
paragraphs from the window height; it still requires an initial offset greater than 500 points and
the same history-following and retained-reading-bookmark outcomes.

GitHub's macOS runners can take 15–20 s per element lookup and 90 s per launch, and sometimes drop a tap or long-press. Fixture-mode UI tests subclass `ReliableUITestCase` (`Annex/AnnexUITests/UITestSupport.swift`):

- `launchApp(_:)` launches in portrait with `--ui-testing-fast` (UIKit animations off, DEBUG only) and relaunches after a launch or terminate timeout.
- `waitAndTap(_:until:)` and `waitAndTap(_:untilGone:)` tap again only if the expected change didn't happen. `longPressUntilMenu(_:shows:)` does the same for context menus.
- `scrollTo`, `scrollUntilExists` and `expandFold` stop as soon as the target is there. Don't write `for _ in 0..<n where !condition { swipe }`: `where` doesn't end the loop, so the slow lookup in `condition` still runs on every remaining iteration.
- Each step fails with a message 30 s before the test's execution time allowance. A test the allowance kills restarts the runner and isn't retried.

CI marks QuickPath's first-use introduction as seen on its selected simulator after boot. For a fresh local UI-test
simulator, run `xcrun simctl spawn <test-simulator-UUID> defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool YES`
after boot too. This affects only that simulator, not the host or any other device; the introduction can otherwise
replace the keyboard when a sheet or confirmation closes.

Don't retry a tap whose repeat changes the result, such as adding an attachment or toggling a switch.

The live and provider tests listed below skip unless you enable them.

## Live E2E against a real desktop (nightly)

Desktop update validation (#359, #400) is deliberately **fixtures and preview only**: never trigger a real update, check or restart. `AppUpdateContractTests` reads the pinned desktop statuses, events, approval and command/error fixtures; `CompanionAppUpdateTests` covers capability gates, required approval modes, cancellation, explicit same-id request/cancel/check recovery, pending check progress without a Dispatcher or grant, stale whole-result receipt protection, Already checking, authoritative retirement of resolved attempts, terminal shutdown with late replies, and new-epoch/lost-receipt safety, including a capability refresh racing a snapshot blocked on icon work. `SessionTests.desktopUpdateRestartDropsReceiptsAndReplayCursorAndRefetchesCapabilities` exercises the real transport with synthetic sockets. `qaSocketEpochRemainsCorrectWhenRestartRacesTheUpgrade` proves fresh capabilities replace a mismatched socket before publishing its epochless snapshot. `CompanionAppUpdateUITests` uses `--companion-preview-app-update` for the Home indicator's running/available versions, version-specific restart action and immediate explicit approval choices. Fixtures are re-synced from desktop main at `5dcf6f18cfd9ecd6850ec735fdd3134e6b750bed` after Agent-Clubhouse/Clubhouse#3505 merged.

For #400, the progress regression fixture injects 512 update events, each followed by a connected notification and snapshot, while the icon actor is blocked. Observable/displayed progress must reach the real 99% within one second before releasing icons, and cannot regress afterwards. Hosted `CompanionAppUpdateViewTests` uses verbatim copies of the pinned `app-update-statuses.json` and `snapshot-app-update-approval.json` in `Annex/AnnexTests/AppUpdateFixtures` for all status/review layouts and synthetic request-to-choice transitions. Hosted and preview UI also exercise checking through download to restart-ready. Preview UI covers every status, all three immediate approval choices, idle-wait cancellation and explicit Dispatcher enabling. Set `COMPANION_PREVIEW_APP_UPDATE_STATE` to `none`, `available`, `downloading`, `ready` or `unsupported` with `--companion-preview-app-update`; add `--companion-preview-app-update-dispatcher-off` for its enable path, `--companion-preview-app-update-no-check` for an older host, or `--companion-preview-app-update-check-running` for Already checking. No live check, installer or restart is invoked.

`scripts/e2e-live.sh` tests Clubhouse Go end to end against a real Clubhouse desktop. Nothing here calls a model or spends tokens. It needs Node (the repo's `.nvmrc`), Xcode with an iOS simulator, and network access to clone `Agent-Clubhouse/Clubhouse`.

```sh
scripts/e2e-live.sh                                   # desktop main, iPhone 17 Pro
scripts/e2e-live.sh --desktop-ref my-branch           # any desktop branch, tag or commit
scripts/e2e-live.sh --only CompanionLiveE2ETests/test6ProjectAndAgentTerminals
scripts/e2e-live.sh --skip-desktop-build              # reuse .desktop as it is
scripts/e2e-live.sh --simulator 'iPhone 17'           # another model (a new device of it)
```

Repeat `--only` to run a sequence against one desktop fixture, for example:

```sh
scripts/e2e-live.sh --skip-desktop-build \
  --only CompanionLiveE2ETests/test7FinishedQuickAgent \
  --only CompanionLiveE2ETests/test8AgentThatSleptWhileAwayReadsSleepingAfterForeground
```

If the desktop returns `snapshot_failed` before its first snapshot, the transport keeps reading the authenticated socket for 30 seconds, preserving REST catch-up and commands. A snapshot on that socket cancels recovery; otherwise grace expiry reconnects through the existing backoff. Silence alone has no new deadline, and other error frames keep their existing routing. Desktop [#2639](https://github.com/Agent-Clubhouse/Clubhouse/issues/2639) prevents snapshot serialization for 60 seconds after a phone-started quick agent exits; until that is fixed, test8 can still exceed its catalog wait and need the existing retry. Report that retry explicitly.

What the script does:

1. **Builds both apps.** It clones the desktop into `.desktop/`, which git ignores, checks out the ref and runs `npm ci` and `electron-forge package`. It skips either step when the lockfile or the commit hasn't changed since the last run. Clubhouse Go builds for testing at the same time.
2. **Launches the desktop as an isolated fixture.** It copies `scripts/e2e-live/desktop-fixture.spec.ts` into the desktop's `e2e/` folder and runs it with the desktop's own Playwright and launch primitive. You get:
   - a disposable profile (`CLUBHOUSE_USER_DATA`), with auto-update off;
   - loopback-only, ephemeral Annex (`CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`, `CLUBHOUSE_ANNEX_EPHEMERAL=1`): no Bonjour, and identity, TLS and peers held in memory;
   - every provider CLI pinned through the desktop's unpackaged-only `CLUBHOUSE_TEST_CLI_BINARIES` seam. Claude Code is the desktop's scripted `src/main/chat/claude/__fixtures__/fake-claude.mjs`, running in chat mode on the stream-json transport. Codex and Copilot point at paths that don't exist, so a real CLI on the machine is never reached.
   - one git project under `/tmp`, `Phone Fixture`, with two sleeping chat agents: Echo, which works in the project folder, and Builder, which has its own worktree;
   - the New layout, with Dispatcher initially off so the earlier idle-project tests keep their order constraints. The Clubhouse MCP always runs and the Dispatcher flag graduated on the desktop (Clubhouse #2913–#2915), so the fixture seeds no MCP or flag setting;
   - a separate session-paired mTLS observer that checks real Dispatcher events, follow-up snapshots and replay. It pins the fixture certificate before pairing. A wrapper around the unchanged fake CLI stores only that isolated child's MCP bridge credentials in 0600 files inside the private temporary fixture folder, so tests can call real Dispatcher tools without a model. Credentials never reach the phone runner or wire evidence. Desktop stdout/stderr are redacted before entering the artifact directory, other logs are scrubbed at teardown, and the entire temporary folder is deleted.

   Before any build or launch, the script removes every inherited `CLUBHOUSE_*` environment variable, including the agent credentials present when an installed Clubhouse starts the script. The fixture refuses inherited Clubhouse variables. Its fake wrapper records credentials only for fixture-created agent IDs; every MCP RPC verifies that ID, excludes the original inherited port, and checks that the listener belongs to the fixture desktop PID. Fallback teardown also checks that `desktop.pid` runs an executable under `.desktop/` before signaling it.

   It never touches your own Clubhouse instance or its profile.
3. **Prepares one-use pairings.** Once Annex's TLS listener is up, the observer pairs with the current `annex.getStatus().pin`, spending it. The fixture re-reads the rotated status and writes `annex-ready.json` (port only). It does not publish the observer's PIN as a phone invitation. Before each phone launch attempt, XCTest sends `preparePairing` over the private fixture action channel. The fixture checks readiness and paused state, calls the pinned desktop's existing `annex.regeneratePin()`, re-reads and checks status, then atomically writes `{host, port, hostID, certificatePin, pin, name}` to `invitation.json` (mode 0600). Regeneration gives the slow hosted launch a new ten-minute PIN lifetime without disconnecting the observer or unlocking paused pairing. The acknowledgment contains only a conservative expiry deadline, not credentials. The runner checks that deadline before/after launch and bounds its Home/project waits by it, reporting an explicit fixture PIN-expiry error rather than a generic project timeout. Each successful pairing still spends and rotates its PIN; ephemeral mode changes storage, not one-use semantics.
4. **Runs `CompanionLiveE2ETests`** on a new simulator of the chosen model, which the script creates for this run and deletes afterwards. On a dev Mac other builds and agents boot, drive and shut down the usual simulators, and sharing one crashed runs and relaunched the app mid-test. Pass `--shared-simulator` to use the existing device instead. The script uninstalls the app and runner first, because a stale runner has run old tests. The runner receives `TEST_RUNNER_CLUBHOUSE_E2E_FIXTURE_DIR`, not a frozen invitation; it reads the newly acknowledged invitation and passes it to the app in its launch environment. Each launch pairs for that session only through the unchanged DEBUG bootstrap. Explicit relaunches, failed-test retries and hosted-runner launch retries all request the current PIN after terminating the old app; foreground reconnects retain the existing authenticated session and need no PIN. Failed tests are retried once. If the simulator itself crashes ("server died", a failed launch), xcodebuild aborts the whole run, so the script reboots the simulator and runs the suite once more, again requesting current invitations. `scripts/verify-xcresult.py` requires a nonempty passing result. xcodebuild prints the launch environment when a launch fails, so the script redacts the invitation from its log. All issued PINs, including the observer's and previous phones', remain in private 0600 history files only until teardown so redaction covers earlier launches too; none are uploaded.

   Setup and teardown turn the fixture's Dispatcher off, its only remaining global gate, and check that the desktop reports `flagOn: true`. This also isolates a retry after a timed-out test; individual tests still explicitly enable Dispatcher when needed. Refused mobile commands attach only HTTP status and an allowlisted error code, never the response body or command content.

   The manual workflow's optional `only_test` input accepts space-separated method names, for example `test9cAgentDispatcherSwitchesAndRealMCPDelivery test9eDispatcherInspectsARealHelper`. Empty runs the full suite; `desktop_ref` can pin the desktop commit for a controlled comparison.
   Set `no_retries: true` to disable both failed-test retries and the simulator-crash rerun, and require
   `ClubhouseGoUITests` to pass the strict no-retries result verifier. The script's equivalent is `E2E_NO_RETRIES=1`.
   The default nightly retry behavior is unchanged.

   Persistent approval rules are selected in Review request, not the transcript card (#392). Dispatcher tests use
   Settings > Dispatcher: desktop Agent-Clubhouse/Clubhouse#3228 and Go #358 deliberately hide raw Model, Runtime
   and Access when `notHonored` lists them. Behavior saves through its owning control; raw locked identity and
   orchestration writes must still refuse. Replay is checkpointed after the final agent cleanup, since cleanup can
   remove interior entries; all five live changes and their follow-up snapshots remain independently required.
   Lazy forms are opened by their summary, then scrolled to the requested row rather than waiting for an offscreen Name.
   Wait for a fresh permission's Review control before tapping it. Compare each Dispatcher change to the first
   follow-up snapshot's `enabled`, not object presence: null means off before first creation, and later off snapshots
   retain the chat record (desktop Agent-Clubhouse/Clubhouse#3514). Guided `providerControl`
   replaces the raw orchestrator menu with Runs on. Agent routes and locked-field refusals target the chat id from
   `GET /api/v1/mobile/dispatcher/settings`, never the desktop IPC state's hidden work-agent id; `404 agent_not_found`
   for a hidden id is not equivalent to the required `409 dispatcher_locked` for a locked chat-field write.
   Structured question choices also belong to Review request, not the read-only transcript. Close Settings using
   its Done control, never an offscreen lazy summary as the disappearance sentinel.
   Before the unchanged 20-second fixture disconnection check, verify the phone actually reaches runningBackground.
   Lifecycle attachments record app state and PressHome/background/disconnect Unix timestamps. `phone-disconnect.json`
   and the fixture log record accepted TLS upgrades and closes with opaque peer/socket ordinals (no fingerprints or
   certificates), so a duplicate phone socket can be distinguished from a socket that did not close. A backgrounded
   phone still counted as connected after that check is a suspension/close failure, not a reason to loosen replay.
   The composer shell is not chat readiness: wait within the existing budget for an enabled Wake or live control,
   then require the typed draft to commit and Send to enable within one shared Send budget. Readiness failures attach
   bounded UI state plus `phone-history.json`: passive chat-snapshot/history request timings, HTTP status, byte count,
   header/finish/close timings and opaque agent/peer/request ordinals, never paths, sessions or response contents.
   Null response timings identify unfinished desktop responses; a missing request distinguishes a phone-side read
   that never reached the desktop. A completed server response with a still-loading phone needs consumption/transport
   diagnosis, not a retry, refresh or longer timeout.
   The intermittent background socket-close failure is tracked in #416; its internal cause is unresolved.
   DEBUG live runs opt into closed-vocabulary `[live-connect]` events for the scene phase, lifecycle queued/wait/start/
   completion, transport disconnect entry/return and native socket cancel invocation/return. The per-launch capture
   reserves 64 lifecycle records separately from 256 connection records, emits one explicit limit marker per group,
   and never exports identities or arbitrary metadata. Producers only append a typed projection to a fixed 64-record
   ring under a short lock; they never encode, schedule writer work or access a file descriptor. A utility-queue timer
   drains it every 20ms, outside the ring lock, to an independently opened nonblocking PTY descriptor. It never changes
   stdout's shared flags or falls back to blocking output. Full buffers, EAGAIN, partial writes and output failures
   drop records and coalesce numeric dropped-count/total markers when output recovers; unavailable capture is not
   success. Exhaustion markers retain their reserved state until writable output is available.
   The hosted timing regression redirects actual stdout to a full blocking pipe, restores it in defer, and requires
   64 producer appends within 250ms. A delayed reader rescues the synchronous-write negative control after one second.
   Export the xcresult diagnostics and inspect the app's
   `StandardOutputAndStandardError-com.Agent-Clubhouse.Go.txt` to find the last observed boundary. A completed native
   cancel call is not proof of a server-observed close. Asynchronous output may lose a final record at suspension
   or termination, or contain a partial line: export retains available evidence without requiring a complete tail.
   Missing or dropped tail events are **inconclusive**, not proof that the corresponding product boundary was skipped.
   The synchronous producer writes at `696d5296` failed QA timing-neutrality review; nightly `43689511338` may have
   been timing-perturbed and cannot establish the #416 internal cause. A passing run does **not** fix #416;
   keep the real background, unchanged 20s disconnect check and every replay assertion.
5. **Tears everything down**, even on failure or Ctrl-C: the desktop and its Playwright runner (only the processes the script started), the profile, the invitation, and the simulator (`--keep-simulator` keeps it).

Results land in `build/e2e-live/` (set `E2E_OUT_DIR` to change it):

- `LiveE2E.xcresult`, which holds screenshots of each step;
- `xcodebuild-build.log` and `xcodebuild-test.log` (plus `xcodebuild-test-retry.log` after a simulator crash);
- `desktop-fixture.log`, `desktop-stdout.log`, `desktop-stderr.log`, the desktop's npm and build logs;
- `desktop-sha.txt`, the desktop commit that was tested;
- `dispatcher-wire.json`, redacted Dispatcher events, snapshots, replay and MCP-delivered message evidence.
- `desktop-annex.json`, a closed projection of this fixture profile's Annex pairing/REST outcomes and WebSocket admission/close timestamps; raw metadata is excluded. Phone `[live-connect]` records in the xcresult console contain only timestamps, operation names, durations, failure categories, diagnostic event names and an optional native WebSocket close code. These help locate an initial-connection stall without recording invitations, certificates, identities or tokens. Both paths use the artifact redaction step (`python3 scripts/e2e-live/test_redact_logs.py` checks it).

Other environment variables: `DESKTOP_REF`, `DESKTOP_REPO`, `DESKTOP_DIR`, `E2E_SIMULATOR`, `E2E_DERIVED_DATA`, and `E2E_SKIP_DESKTOP_CHECKOUT=1`, which builds `DESKTOP_DIR` as it is checked out.

### Background disconnect investigation (#416)

The original strict failure, [43678416927](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/43678416927),
predates the merged lifecycle diagnostics. At investigation time, `gh run list --workflow e2e-nightly.yml`
found only one run after #407 merged: [43731027202](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/43731027202)
at `2d6f50f9`, whose test9a passed. There is no post-merge failing trace from which to identify #416's last boundary.

That passing run's Unix-second timestamps are PressHome `1794762151.322`, background observed by XCTest
`2153.250`, scene observation/transition queued `2153.138`, transition waiting/started `2154.127`,
disconnect started/native cancel started `2154.128`, and desktop socket closed `2154.147`.
The 989ms queued-to-waiting interval is scheduling delay **before the lifecycle Task starts**.
The `transitionWaiting`-to-`transitionStarted` interval bounds any predecessor wait to at most 0.26ms.
Native cancel-completed and transition-completed records are missing despite the server-observed close;
the same stdout contains drop markers. Do not classify a missing tail as a stuck cancel.

`CompanionLifecycle.pending` waits only for the previous lifecycle transition, not arbitrary command/history tasks.
Background neither cancels that task nor bypasses it. Foreground can await `prepareResume`: sequential per-host
route probes, relocation/pairing-store work, registration, then transport disconnect/subscription/credential lookup.
`firstAnswering` has a 4s deadline and cancels its probe group; its structured scope still waits for children,
and real TLS probes use 10s URLSession timeouts. A relocated host can connect before the next host is probed.
A hosted probe held that remaining foreground preparation after reopening a socket: background did not close it
within 500ms, and releasing preparation allowed suspend to finish. This demonstrated multi-host head-of-line hazard
is tracked separately in #426; it does **not** establish the original test9a failure's cause. The intentionally red
probe and its failing xcresult are investigation evidence, not a committed test, expected failure or assertion of
the buggy behavior.

Transport disconnect always rotates its generation, cancels the loop and takes the socket before awaiting close;
there is no "already disconnecting" early return. Connection creation checks the generation both before and after
opening a socket, closing a late socket. Backoff is cancellable and checks that same fence before retrying.
The real URLSession wrapper calls `cancel(with: .goingAway)` synchronously; return is not a peer-close acknowledgement.
DEBUG `socketTaskCompleted` adds the later URLSession task callback and its numeric `webSocketCloseCode` to the
bounded lifecycle projection, without URLs, identities, error strings or arbitrary measurements. This callback
also is not proof of when the peer saw TCP close; retain the desktop fixture's independent socket audit.

`CompanionBackgroundDisconnectTests` uses the real runtime, lifecycle, service and transport with fake IO for
connect-in-flight, backoff, command-in-flight and rapid phases. Fake sockets can prove
the transport's close boundary, **not** native URLSession cancellation. The package's
`explicitSocketCancelReachesNativeCompletionAndSendsGoingAway` separately checks real pinned URLSession cancellation,
the native completion checkpoint and a loopback peer's received 1001 close frame.
That native check runs on macOS; it does not reproduce iOS process suspension or prove the original background close.

**#416 remains unresolved.** A main-actor stall before SwiftUI observes background, scheduling delay before the
lifecycle Task runs, a blocked predecessor, and native close delivery cannot be distinguished without a failing
diagnostic-era trace. No cancellation/lifecycle behavior, assertion, timeout or retry policy is changed here.
The next evidence-gathering run should be a full strict branch nightly, pinned to the desktop used by the passing
diagnostic-era baseline, not a local run against a person's desktop:

```sh
gh workflow run e2e-nightly.yml --ref go-416/investigate \
  -f desktop_ref=a680695e866cbb8b8f5b40354e6e08cbc5637e8c -f no_retries=true
```

This is a proposed dispatch, not a run result. Preserve the original real-background, 20s disconnect and replay
checks; correlate the phone's last available boundary with the desktop socket audit and all trace drop/limit markers.

### What one run covers

The fake CLI's scripted turns:

| You send | The CLI replies |
|---|---|
| `hello` | Streams "Hello". |
| `tool` | Asks to run `ls`, offering an "allow and don't ask again" rule. It replies `allowed:<input>:<rules>` or `denied:<message>`. |
| `ask` | Asks "Which DB?". |
| `crash` | Exits at once with code 3. |
| A message with images | `echo:<text>\|…\|images:<n>:<types>` |

The tests share the desktop and run in order. Each one copes with what an earlier attempt left behind, such as a waiting approval, an inactive project or an awake agent.

| Test | Covers |
|---|---|
| `test0ProjectPinAndIdleSync` | Pin, then Mark inactive and Mark active, each kept by the desktop across a fresh pairing. It runs first, while every agent sleeps, because Home never folds a project with an awake agent. |
| `test1PairingCatalogAndReconnect` | Pairing from the invitation; the project and agents from the desktop's catalog; the desktop's status words (Sleeping, Done); waking an agent; Home → background → foreground reconnect, then a fresh approval round trip |
| `test2ChatStreamApprovalsAndQuestion` | A streamed reply; Deny; Allow (no rule added); "Allow and don't ask again", whose rule reaches the CLI; a structured question and its answer |
| `test3ImageUploadReachesTheCLI` | Picking an image, uploading it to the desktop, and the CLI receiving it as an `image/png` block |
| `test4ModelAndLevelSwitch` | The composer's model menu (switching to Haiku) and level menu (switching to Plan, then back to Ask first) |
| `test5CreateDurableAgentAndSettings` | New agent creates a durable agent on the desktop; the desktop's agent settings rename it and change its colour; Home shows the new name |
| `test6ProjectAndAgentTerminals` | The project-root shell (spawn, echo, its directory, a resize on rotation, close) and Builder's worktree shell (its folder and branch) |
| `test7FinishedQuickAgent` | A quick agent started from the phone finishes, is listed under "Finished, waiting on you", and Dismiss removes it on the desktop |
| `test8AgentThatSleptWhileAwayReadsSleepingAfterForeground` | Echo is awake (Done); the phone goes to the background; the desktop puts Echo to sleep (the test writes `sleep-request` to the fixture folder, `TEST_RUNNER_CLUBHOUSE_E2E_FIXTURE_DIR`); back in the foreground, Home reads Sleeping without opening the chat (the reconnect catch-up) |
| `test9aDispatcherPhoneSwitchDesktopChangesAndReplay` | Phone Settings turns Dispatcher on/off; the pinned row; desktop changes while connected and backgrounded; phone catch-up; a real paired observer verifies `dispatcher:changed`, follow-up snapshots and `mobile:replay` |
| `test9bDispatcherChatSettingsSleepWakeAndResume` | Dispatcher chat send/stream, its editable and locked settings, desktop stop, phone wake/resume after reconnect |
| `test9cAgentDispatcherSwitchesAndRealMCPDelivery` | Echo's Orchestrate and Connect switches; the actual Dispatcher wire; authenticated MCP `wake_agent`, `send_message`, `sleep_agent`; phone wake/sleep state; structured `routed` sender/body on wire and screen, sender avatar, a real long delivery folding/unfolding, preserving inline tags and excluding CLI reply instructions; the settings route reports `mcpEnabled: true`; 409 `dispatcher_off`; with Dispatcher off, the phone's switch is enabled because no flag or MCP setting gates it |
| `test9dDispatcherSettingsSaveAndLockedFieldsRefuse` | Phone model/runtime/auto-sleep/Free Agent Mode saves persisted on desktop, plus 409 `dispatcher_locked` for identity and orchestration writes (the phone never sends the retired persona and Clubhouse mode) |
| `test9eDispatcherInspectsARealHelper` | Echo creates a genuine helper through `start_helper`; Dispatcher inspects it through `inspect_helper`; `parentAgentId` identifies it, the phone hides Connect while keeping other orchestration controls, and a raw true write still resolves false |

Dispatcher checks run last and support `--only` and retries. Phone gestures cover the UI; the private fixture action channel performs desktop changes, direct MCP calls and HTTP-only refusal checks. The observer's replay check proves the desktop retains the event, while the phone assertion proves foreground catch-up; it does not claim to distinguish replay from a fresh connection snapshot on the phone. The fake CLI does not decide to use tools: the fixture authenticates to the real MCP bridge as its own fake child and invokes them directly.

**Dispatcher gaps:** `dispatcher_layout_off` needs a separate Classic-layout desktop launch (layout is fixed at startup). The real MCP delivery covers one routed part; multi-sender bursts have deterministic preview coverage. Physical-device background suspension is separate from the simulator's Home/foreground check.

**Not covered: helper approval requests.** The live helper check uses a hands-off policy so `start_helper` creates a real helper directly. It does not exercise an ask-first request, approval or decline. `CompanionPreviewSmokeTests/testNeedsYouAnswersHelperRequestsWithTheDesktopRules` covers that phone flow against the preview desktop.

**Not covered: Clubhouse grant requests (#337).** No live check holds a Clubhouse MCP call for Ask first or makes a `request_grant` ask, so `grant.answer` against a real desktop, the audit record's `mobile` surface, and a lasting Allow appearing on the agent's permissions page are unverified. The contract tests drive the desktop's recorded snapshot, events and every `grant.answer` receipt through the live service and store (`CompanionGrantRequestLiveTests`), and `CompanionGrantRequestUITests` covers preview answers in Needs you and chat, including removal from both surfaces (#357).

**Not covered: Settings > Dispatcher (#338).** No live check changes Behavior or runs Clear chat or Forget everything against a real desktop. The contract tests drive the recorded settings route, every `dispatcher.*` receipt, the `stale_state` re-ask and `dispatcher:changed` through the live service and store (`AnnexContractDispatcherSettingsTests`), and `CompanionDispatcherUITests.testBehaviorClearChatAndForgetEverything` covers Behavior and both confirmations against the preview desktop.

`--companion-sample-images` replaces the photo picker in this suite, as in preview mode. In DEBUG builds it is honoured when a test invitation is present.

### Nightly workflow

Offline fixture regressions (Node from `.nvmrc`; no desktop or simulator launch):

```sh
node --test --test-concurrency=1 scripts/e2e-live/pairing-fixture.test.ts
python3 -m unittest discover -s scripts/e2e-live -p 'test_*.py'
```

The Python regressions execute the actual fixture request handler and Swift `dispatcherFixture`, `launchPaired`
and launch-retry methods with inert desktop/XCTest doubles. They cover acknowledged invitation delivery into the
phone launch environment, explicit expiry errors, relaunches and a fresh runner. Republishing the cached observer
status instead of reading the regenerated PIN makes the integration test fail with HTTP 410.

`.github/workflows/e2e-nightly.yml` runs the script on `macos-26` every night at 08:17 UTC. To run it on demand, use **Actions → Live E2E (nightly) → Run workflow**, which takes a `desktop_ref` input (default `main`):

```sh
gh workflow run e2e-nightly.yml --ref <branch> -f desktop_ref=main
```

It never runs on pull requests, which keeps CI minutes down: a run takes about 45 runner minutes, mostly building the desktop (`npm ci` about 6, `electron-forge package` about 23) and the suite itself (about 12). Each run uploads `live-e2e-<run id>` (the xcresult and logs) for 14 days.

The offline privacy regression checks the text logs and JSON evidence processed by `redact-logs.py`. That script
does not inspect or rewrite xcresult contents. An authorized live run must separately inspect xcresult diagnostics,
especially failed-launch framework records, for invitations/PINs/nonces before claiming those artifacts are clean.

When a nightly run, or a run on `main`, fails, the workflow opens an issue titled "Nightly live E2E failing", or comments on the open one. Close the issue once the suite is green again.

## Live integration (opt-in)

`CompanionLiveSmokeTests` runs only when `TEST_RUNNER_CLUBHOUSE_RUN_LIVE_SMOKE=1` is set on `xcodebuild`. Run it only against an isolated desktop fixture that you own:

- The desktop runs with `CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`, `CLUBHOUSE_ANNEX_EPHEMERAL=1` and a dedicated `CLUBHOUSE_USER_DATA`. That gives loopback-only sockets, no Bonjour advertisement, and identity, TLS and peer state held only in memory.
- The app receives an in-memory `SIMCTL_CHILD_CLUBHOUSE_COMPANION_TEST_INVITATION` JSON value `{host, port, hostID, certificatePin, pin, name?}`. Read the certificate pin and Ed25519 identity from the process you own. Never bypass certificate checks or install system trust. Keep PINs and credentials out of logs and test bundles.
- The expected fixture agent is `durable_sprint_fixture`, backed by the desktop repository's scripted `fake-claude.mjs` through the real `ChatAgentRuntime`. Each run needs a fresh runtime session.
- Build for testing, install the rebuilt app and the XCTest runner explicitly, then use `test-without-building` with the exact arm64 `.xctestrun`. Incremental installs have run stale tests, and a stale multi-architecture `.xctestrun` has selected zero tests. Zero tests is not evidence.

The same flag enables `CompanionPhoneWorkflowTests`, which covers wake, image and file preview, and feedback settings.

- `TEST_RUNNER_CLUBHOUSE_RUN_QUEUE_SMOKE=1` adds a client-queue assertion. It requires fixture capabilities `steer: false, queue: client`.
- `TEST_RUNNER_CLUBHOUSE_RUN_MANUAL_SMOKE=1` drives manual pairing (inspect, compare fingerprints, pair). Launch the app for it with `CLUBHOUSE_COMPANION_MANUAL_TEST=1`.

## Provider tests (opt-in)

`CompanionProviderSmokeTests` (`TEST_RUNNER_CLUBHOUSE_RUN_PROVIDER_SMOKE=1`) and `CompanionAdditionalProviderTests` (`TEST_RUNNER_CLUBHOUSE_RUN_ADDITIONAL_PROVIDER_SMOKE=1`) drive real providers through the same isolated profile. They need existing provider authentication and an invitation supplied outside the test bundle. Run one method per fresh fixture launch.

- Codex: the desktop uses `new CodexChatDriver({ ephemeralThread: true })` with a fresh project and session, `level: plan`, no resume ID and a no-tools instruction. Disable configured MCP servers for that child process only.
- Wake tests: also set `TEST_RUNNER_CLUBHOUSE_PROVIDER_STARTS_ASLEEP=1` and start the fixture asleep.
- Copilot active-generation control: set `TEST_RUNNER_CLUBHOUSE_PROVIDER_CLIENT_QUEUE=1`.
- Permission tests: set `TEST_RUNNER_CLUBHOUSE_PROVIDER_INTERACTIONS=1` and use a constrained interaction fixture.

Provider semantics to keep in mind when you read the results:

- **Claude SDK**: a direction sent during generation uses native `priority: next` and applies at the next tool boundary. A text-only turn can finish before it takes effect, so check runtime turn IDs and delivery events rather than the response marker alone.
- **Copilot ACP**: it advertises `steer: false`, `queue: client`, `interrupt: true`, `questions: false` and `planApproval: false`. Denying a tool cancels the operation and need not produce another response.
- **Image and file previews**: these follow the paired desktop's experimental rich-content policy. Phone uploads and arbitrary remote image fetches aren't implemented.

## Physical iPhone

Physical-device checks aren't automated. These still need to be done by hand: multicast discovery, device signing and Keychain, real media codecs, shake sensor detection, and LAN/Tailscale reachability.

1. Use an unlocked iPhone on iOS 26+ with Developer Mode on and development signing set up for the owner's team. Open `Annex/Annex.xcodeproj`, scheme `ClubhouseGo`.
2. Nearby discovery needs a desktop that is broadcasting and the iOS Local Network permission. Tailscale doesn't relay Bonjour, so enter its address and port manually.
3. For an isolated manual-address test, the desktop supports `CLUBHOUSE_ANNEX_BIND_ADDRESS=<one local IPv4>` with `CLUBHOUSE_ANNEX_EPHEMERAL=1` and a dedicated `CLUBHOUSE_USER_DATA`. That profile doesn't advertise. Don't combine it with `CLUBHOUSE_ANNEX_LOOPBACK_ONLY=1`. Get approval before starting a reachable listener.
4. Scan the QR code in desktop Settings → Annex, or pair manually by comparing both fingerprints and entering the PIN. Turn Remember off for an isolated test, and end the session pairing afterward.
