# Actor deinitialization on older iOS runtimes (#218)

The app's minimum deployment target remains iOS 26.0. Debug and Release use default MainActor isolation. With local Xcode 26.0.1 / Swift 6.2, compiler SIL proves that this setting synthesizes isolated deinits even for an explicitly `@MainActor` class whose source contains no deinit. Without the setting, the same explicit class has an ordinary deinit. Changing the setting app-wide would change other inferred actor isolation; this patch preserves it.

A standalone UIKit startup app, without XCTest or Swift Testing, reproduces SIGABRT on iOS 26.0 (23A343): main thread, no current Swift task, a private synchronous Int TaskLocal scope, and release of an implicit-deinit actor class. Its crash reports show malloc pointer-not-allocated → TaskLocal::StopLookupScope → swift_task_deinitOnExecutorImpl. State churn and Go telemetry are not prerequisites. Outside the scope, after the scope, in a Swift task, with an unisolated class, or with explicit empty/nonisolated deinit, the controls complete. `simctl launch` can return zero after this abort; probes require a completion marker instead.

[Swift issue #88036](https://github.com/swiftlang/swift/issues/88036) reports: “This reproduces on iOS 26.2 and older, and appears fixed on iOS 26.4.” That is the reporter's observation, not an Apple release guarantee. [Swift runtime PR #85204](https://github.com/swiftlang/swift/pull/85204) explains: “Item::destroy will call free when there's no task”; its allocation fix merged October 30, 2025. It does not identify an iOS shipping version. Local runtimes are only 18.2 and 26.0; 18.2 cannot run the Go app. Versions 26.1, 26.2, 26.3, 26.4, 26.5 and newer are not locally tested. CI runs an unguarded control and prints its actual runtime/compiler; do not infer a 26.4 boundary from a 26.5 pass.

## Production reachability and limits

The source audit of Go plus pinned Framebriar v0.5.0 finds three `withValue` sites: AnnexTelemetry.measure, AnnexTransport.run, and SDK Telemetry.withSpan. All use async operations, so those scopes execute inside a Swift task. measurePerformance and measureRoutine install no task-local scope. No synchronous app-owned no-task scope was found. Re-audit after SDK adoption.

Five offline production-shaped cycles on 26.0 mounted the actual root, navigated to Dispatcher, applied offline/resync/synchronizing/connected state, returned, recreated root values and tore down the window/store. These ran through DispatchQueue callbacks without XCTest, without adding a scope, and with currentTask=false / AnnexTelemetry.current=nil. Both lazy-only and fixed variants completed. This is synthetic reconnect state, not URLSession/network/device proof. Internal SwiftUI/framework scopes are not exhaustively observable from these public APIs. We have not demonstrated the crashing combination during ordinary production navigation, and cannot prove it is test-only. Forcing a private or Annex scope in the same no-XCTest app reproduces real Queue/Part/Transcript/holder releases before the fix.

Lazy queue ownership removes repeated allocation/discard on SwiftUI root initialization; it does not fix arbitrary class release. The lifetime wrapper itself needed the deinit review. CompanionNavigation on origin/go-dispatcher-tab/first-tab is a value struct: it repeats preference/restoration work but has no actor-class deinit. Preview/demo Store and Preferences construction, SDK preview presenter construction and terminal focus State construction were audited; this patch does not redesign all their ownership. The exact viewport declaration and value helpers extracted from the unmerged reading branch abort in the same no-XCTest scope control; adding only its empty nonisolated deinit makes that control complete. This is declaration-level evidence, not a full reading-branch integration test; its ownership fix remains with that branch.

## Field affinity decisions

An empty nonisolated deinit can release fields on the thread performing the last release. It is not a universal workaround. UI owners and unknown callback/protocol owners retain compiler-generated isolated teardown so their fields still release on MainActor. This leaves those runtime paths vulnerable to the old allocation bug if the missing production combination occurs.

`arc_only` means the current stored fields and concrete constructor captures were reviewed. Queue's production commit captures only Store, whose concrete service/persistence graph is also reviewed as UI-free. The generic lifetime wrapper is approved only at the reviewed constructor sites; it must not acquire raw UI values or UI-capturing factories. The existing #213 Runtime use needs a fresh constructor review when integrated; its Runtime must retain isolated teardown. Weak references in terminal focus do not own or release the UIKit view. None of these deinits invokes actor-isolated APIs, persists data or cancels work.

| Class | Policy | Owned fields / decision |
|---|---|---|
| `AnnexManualClock` | arc_only | Lock-protected value state and Sendable task continuations; no UIKit ownership. |
| `CompanionArchiveReader` | arc_only | Sendable transport reference and value target/session/event dictionary; no UI fields. |
| `CompanionArchiveTranscript` | main_actor | Injected reader protocol is not constrained to UI-free implementations. |
| `CompanionCodeScanner.Coordinator` | main_actor | DataScanner delegate owns an injected callback; possible UI captures. |
| `CompanionComposerPasteHook.Coordinator` | main_actor | Owns UITextPasteItem array and injected main-actor callback; preserve isolation. |
| `CompanionComposerPasteHook.HookView` | main_actor | UIView superclass owns main-only UIKit state, even though explicit references are weak. |
| `CompanionDecisionQueue` | arc_only | Values/tasks plus commit closure. Reviewed production construction captures only CompanionStore, whose reviewed concrete service/persistence graph is UI-free; no raw UI capture permitted. |
| `CompanionImageBytes` | arc_only | Immutable Data bytes, Sendable; no decoded UIImage is stored. |
| `CompanionLifecycle` | main_actor | Owns injected main-actor transition closure; arbitrary captures not proved UI-free. |
| `CompanionLiveService` | arc_only | Transport/value/task state; all three production callbacks in AppRoot capture Runtime WEAKLY, not raw UI. New assignments require capture review. |
| `CompanionLiveTerminalChannel` | arc_only | Sendable transport/tasks/continuation and text/number state; no UIView, layer or delegate owned. |
| `CompanionLocalDrafts` | arc_only | UserDefaults (thread-safe Foundation) plus fixed String; deinit performs no write. |
| `CompanionLocalFinished` | arc_only | UserDefaults plus fixed String; no UI fields or deinit I/O. |
| `CompanionMarkdown.Box` | arc_only | Immutable markdown document value; NSObject cache wrapper has no UI fields. |
| `CompanionMessageSlices.Box` | arc_only | Immutable array of message-slice values; NSObject cache wrapper has no UI fields. |
| `CompanionPartExpansion` | arc_only | Optional Bool and Observation registrar only. |
| `CompanionPreferences` | arc_only | Stored choices are values and UserDefaults; UIDevice is read during init, not retained. |
| `CompanionPreviewService` | arc_only | Boolean flags and Sendable AsyncStream continuation; no UI object/callback fields. |
| `CompanionPreviewTerminalChannel` | arc_only | Value scope/text/size and Sendable stream continuation; no UI fields. |
| `CompanionRuntime` | main_actor | Owns feedback presenter with UIKit windows/controllers; retain main-actor field destruction. |
| `CompanionStateLifetime` | arc_only | Restricted reviewed production constructors: Queue or Int; factory captures only actor-owned model references, never raw UI. Any new constructor site requires review. Runtime use from #213 requires re-review when merged. |
| `CompanionStore` | arc_only | Reviewed concrete production owners: LiveService/PreviewService, LocalDrafts/LocalFinished, value state and Sendable task/clock handles. Those implementations are UI-free; new Store constructor sites require review. |
| `CompanionStreamDiagnostics` | arc_only | Value cursor map, lock-protected Sendable transport diagnostic scopes and telemetry; no UI fields. |
| `CompanionTelemetry` | main_actor | Owns SDK/MetricKit/subscription objects; their destruction affinity is not proved here. |
| `CompanionTerminalFocus` | arc_only | Only a WEAK UIKit reference and Bool/Observation registrar. Weak-slot destruction does not release the view. |
| `CompanionTerminalKeyInput` | main_actor | UIView/UIKeyInput subclass, session and UIKit superclass state; preserve isolation. |
| `CompanionTerminalSession` | main_actor | Injected terminal-channel protocol can own main-only objects; preserve isolation. |
| `CompanionTerminalUIView` | main_actor | UIView subclass strongly owns key-input view, layers and UI state; preserve isolation. |
| `CompanionTranscriptExpansion` | arc_only | Dictionary owns only ARC-safe CompanionPartExpansion values. |
| `EnrollmentShakeReceiver.Receiver` | main_actor | UIViewController subclass and main-only presentation/callback context. |
| `PassthroughWindow` | main_actor | UIWindow subclass owns UIKit/controller/layer state. |
| `ResourceBundleClass` | generated | Xcode-generated bundle-accessor class; no source patch. Runtime path remains unprotected. |

## Enforcement and validation

scripts/check-isolated-deinits.py checks the Debug binary's demangled isolated-deinit symbols against scripts/isolated-deinit-policy.json. A new synthesized isolated deinit requires classification. ARC-only entries must lose the thunk; main-actor/generated entries must retain it. Source fingerprints require an explicit ownership re-review after edits. New Queue/lifetime/Store constructor sites or LiveService callback assignment sites fail review. This is a review gate, not a Swift ownership theorem; changing a fingerprint requires checking fields/captures, not merely accepting a test pass. The negative control rejects the lazy-only, unfixed binary. There are 19 ARC-only protections and 13 retained isolated paths in the table; the latter remain unprotected on an affected runtime if the triggering scope/release combination occurs.

The runtime-control script always executes the unfixed implicit class release, without an OS skip. CI runs it on its selected simulator and uploads mode logs. Local 26.0 intentionally fails that diagnostic control for `inside` and `explicit`; positive nonisolated controls and the actual fixed Go-type regression pass. The hosted regression dispatches to a no-current-task main callback and releases the actual types under both a private Int scope and AnnexTelemetry scope, with no OS guard.

The first hosted batch after protecting 17 classes still aborted in CompanionStore while SwiftUI released a prior avatar fixture. That failure prompted the concrete Store/LiveService ownership audit and two additional ARC-only protections rather than a retry-only claim. After rebasing through #216, #221 and #230 (68a11b2), the final hosted batch passed 13 tests repeated three times (39 passing executions), with two pre-existing optional profiling skips. The new deinit tests have no skip or version guard. Package tests passed (951 in 113 suites), coverage ratchet passed (Transport 96.43%, Domain 94.01%), Debug and Release built, and the unchanged vendored SDK passed 66 tests and its 26-file hash check. On the #216 base, all eight selected UI tests passed: tree/relaunch, LongReply, preview navigation/content dismissal and all terminal tests. Those UI results precede the last two queue-projection merges; final-base CI remains required.

The DEBUG-only --deinit-probe route supports offline `cycles`, `queue`, `part`, `expansion` and `holder` modes, with optional --deinit-private-scope / --deinit-annex-scope. It prints context and exits; it never constructs a feedback client, pairs, contacts a desktop or sends a report. Use only in a disposable simulator. Normal production launch does not select it, and it is excluded from Release.

## Read-only phone evidence

Both devices were still on Go 2.0.0 (147): iPhone 17 Pro Max on iOS 26.7.1 (23H30), iPhone 16 Pro on 26.6.1 (23G83). Their devicectl systemCrashLogs listings contained no ClubhouseGo allocator crash. The former had one CPU-resource report, action taken none: Nov 1, 2026 20:00:23.986–20:03:15.898 -0800, 171.91 seconds, 90 CPU seconds (~52%), foreground/user-interactive. Footprint rose 192.91→222.77 MB. Heaviest unsymbolicated samples traverse SwiftUI/SwiftUICore/AttributeGraph and Go offsets; they do not identify a Go function without matching symbols. This is separate performance evidence, not a deinit crash. Build 147 lacks newer classes, and retained-log absence is not a safety proof. No phone install/launch/reset/force-quit was performed.
