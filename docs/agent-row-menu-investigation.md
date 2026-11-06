# Agent row long-press investigation (#247)

Status: diagnostic only; no production gesture or hit-shape change is justified by the evidence so far.

## Established evidence

- [Original failure, main e04821c / iOS 26.5](https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/41469238552/job/125374151856): one 1.2-second Juniper center press at `(201, 503.8333)` opened chat rather than the context menu. The next test attempt passed.
- [Issue #247 and its recorded comparisons](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/247): unchanged main on iOS 26.0 produced menus for 10/10 fresh center and 10/10 fresh name presses, and 3/3 center presses after details/settings navigation. These runs do not isolate OS version, SDK, runner speed or timing.
- [Later visible-name failure](https://github.com/Agent-Clubhouse/Clubhouse-Go/issues/247#issuecomment-6583992086): both the failed and successful attempts used `(104.5, 493.8333)` inside the same Juniper row `(16, 466.6667, 370, 74.3333)`. Restricting tests to the name does not establish a product fix.
- Dispatcher, helper-settings and auto-quota tests have also recorded long-press navigation. A missing menu item cannot explain a failure hierarchy containing the chat navigation bar and composer.

## Source ownership at b17f9f80

| Surface | Navigation target | Menu target | Adjacent control |
| --- | --- | --- | --- |
| Home/project agent tree | `CompanionAgentTreeNavigationRow`'s `NavigationLink` | Inner `CompanionAgentListRow` HStack, via `CompanionAgentMenu` | Separate 44 × 44 helper disclosure button when applicable; otherwise a clear disclosure-column placeholder |
| Dispatcher | `CompanionDispatcherRow`'s plain `Button` | Same inner list-row HStack | No helper disclosure |

The shared label has vertical padding and combined accessibility children, but no explicit full-width frame or content shape. The tree navigation link also has native link presentation. Accessibility row bounds therefore do not prove the native menu recognizer owns every point in the outer navigation target. This is a hypothesis about coverage, not a measured native hit-target explanation. The visible-name failure also prevents attributing the bug solely to empty trailing space.

`CompanionAgentMenu` installs the native SwiftUI context menu only when settings, wake choices or terminal actions exist. Its preview inputs offer details and settings. No custom row tap, high-priority or simultaneous gesture was found in these dedicated row/menu sources. The text attachment produced by the diagnostic is an accessibility hierarchy, not UIKit `hitTest` or recognizer evidence.

## Bounded diagnostic and test cases

`CompanionAgentRowMenuDiagnosticUITests` is opt-in and leaves every existing test and assertion unchanged. It makes no provider calls and launches only the isolated preview. Each test uses a fresh app launch with no launch or gesture retry, checks the complete row is clear of navigation and tab bars, captures the point and frames, and sends exactly one explicit 1.2-second coordinate press.

| Case | Setup | Target | Required result |
| --- | --- | --- | --- |
| Juniper center | River chat → details → settings → back → Done → Home → sleeping fold | Outer row center | Details and settings menu items; no chat title/composer; details action opens Juniper details |
| Juniper name | Same history | Visible name center | Same |
| Dispatcher center | Fresh Home with Dispatcher preview | Outer row center | Same, for Dispatcher |
| Dispatcher name | Same fresh launch | Visible name center | Same |

Setup navigation also uses single taps with asserted results. Scrolling remains bounded. No screenshot is requested or captured by the diagnostic; retained attachments contain only preview accessibility text and outcome metadata. XCTest's own result collection is unchanged. The parent owns new Framebriar captures.

Run only after the parent allocates the serial build/simulator slot. Prefer iOS 26.5 on the same device class and SDK as the failures; a further iOS 26.0 pass is a control, not a resolution. Keep derived data, logs and results inside this worktree. For example, substitute the **owned** simulator UUID below:

```sh
TEST_RUNNER_CLUBHOUSE_RUN_AGENT_ROW_MENU_DIAGNOSTIC=1 \
xcodebuild -project Annex/Annex.xcodeproj -scheme ClubhouseGo \
  -destination 'platform=iOS Simulator,id=<owned-simulator-uuid>' \
  -derivedDataPath build/issue247/DerivedData \
  -resultBundlePath build/issue247/row-menu.xcresult \
  -parallel-testing-enabled NO -retry-tests-on-failure NO \
  -only-testing:ClubhouseGoUITests/CompanionAgentRowMenuDiagnosticUITests \
  CODE_SIGNING_ALLOWED=NO test
```

Do not increase the gesture duration or menu wait, accept navigation as success, or repeatedly press until a menu appears. Report menu/navigation/unknown separately; both navigation and unknown fail. Preserve the first failure's event timing, video and hierarchy. After a failure, stop and inspect before scheduling another invocation.

## Deciding the next change

If these cases pass, leave production code unchanged and report the runtime/SDK/device, source commit and four outcomes. A pass does not disprove the existing intermittent failure.

If one fails, correlate its recorded point with native hit testing and the context-menu interaction's owning view in the same presentation. UIKit view bounds, recognizer ownership and the full event duration are still needed before claiming a coverage or gesture-arbitration cause. Compare center and name results without changing navigation history or the menu assertion. A native ownership trace should avoid private API behavior assertions and must not itself install a competing recognizer.

Only then test a focused candidate such as matching the menu's native owner/shape to the navigation target. Do not infer that moving the menu outward or adding `contentShape` fixes #247 from source structure alone. A tree-only candidate must preserve the sibling disclosure's independent tap and long-press behavior. A Dispatcher change touches `CompanionRootView.swift` and requires an overlap proposal to its owner before editing.

Before a product PR, require controlled before/after evidence plus the existing details, tree disclosure/navigation, Dispatcher settings, helper-settings and quota cases, followed by the project's build/test/lint checks in coordinated slots. Do not relax existing CI gates, timeouts or retries to obtain that evidence.

## Validation for this diagnostic change

Pending coordinated slot: compile the UI test target, confirm the four cases skip without the opt-in environment variable, then run the selected diagnostic once with retries disabled. No simulator, full build or test suite was run while preparing this change. Static diff checks are reported with the PR; they do not establish runtime correctness or a product fix.
