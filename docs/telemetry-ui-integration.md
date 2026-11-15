# Screen/control telemetry integration for #433

This PR is **Refs #433**, not the closing PR. The remaining call sites below must be wired before the final follow-up closes the issue. Locations describe this branch's source snapshot; subsequent UX PRs may move them. Debug-only fixture controls are excluded. Native Back and system dismissal gestures are platform navigation, not synthesized button taps.

## Stable adoption API

```swift
import ClubhouseTransport

// In the existing user action, exactly once; never in onAppear or a destination builder:
AnnexTelemetry.shared.recordAction(screen: .home, control: .openSettings)
onSettings()

// Supply the originating screen to already-instrumented shared agent menus and sleep/wake controls:
content.companionTelemetryScreen(.home)
```

`AnnexUIAction.Screen` and `.Control` are closed enums in the transport/telemetry layer. Calls accept no target, project/host ID, accessibility ID, URL, provider/model value, name, prompt, or free-form attribute. Raw enum values are the stable dashboard dimensions. Do not rename a shipped raw value. New semantic enum cases may be added without changing the call signature.

The mapper emits one unparented `app.action` log with `screen`, `control`, `app.action.name=uiAction`, and `app.action.result=accepted`. This is the accepted UI intent, not successful completion of a desktop command. Existing operation spans continue to report command outcomes separately. UI intent does not supply an incident span reference. Existing capture/enrollment gates, generation fencing and ring bounds apply unchanged.

## Adopted here

- Project page: New agent, Wake with a message, Terminal, retained-run Dismiss (swipe, context menu and accessibility action share one action), Clear all, and the Wake sheet's Cancel/Wake.
- Agent details/settings sheets: Done, retry, cancellation of settings confirmation, and saved identity, color, emoji, provider/model/runtime, access, auto-sleep, context-window and behavior controls. Only the fixed control category is recorded, never its value.
- Shared agent menu items and sleep/wake controls: explicit screen context from `.companionTelemetryScreen(_:)`. A missing context records nothing, rather than guessing which Root/chat screen opened the control. Project page and settings form supply it; Root/chat adoption is still required.

## Required Root/settings follow-up

- Replace the undifferentiated Root `.navigation` tap event with explicit screen/control intents at each tab and navigation action. Set context separately for Home, Dispatcher, Needs you and Agents; do not apply one Home context around the whole tab tree.
- Remove the Settings `.onAppear { record(.settings) }` in **CompanionAppRoot.swift** and record `.openSettings` inside each actual Settings-opening action in **CompanionRootView.swift** and other entry points. Returning from a child page must not count as a new Settings open. No AppRoot, RootView, Navigation or HomeLayout changes are included here.
- Adopt the instrumented shared menus with the correct screen context. Instrument direct Root wake/decision controls independently; do not record a second intent for the same menu item.
- A native SwiftUI Menu opening must use a verified interaction hook that also handles accessibility activation. Do not infer it from destination appearance, add a tap gesture that breaks menu behavior, or record while constructing menu content. Menu item actions can be instrumented directly.

## Remaining source call sites

Each unchecked entry is a remaining interaction site, including the menu/picker opening and its item/selection action where they share a source declaration. A helper that generates several buttons needs the same closed control for each semantic action, with its caller's screen; never encode the selected identifier. Instrument explicit callbacks or selection setters, guarding equality when the native control can write an unchanged value. Follow-up owners must retain existing navigation, confirmation and disabled-state behavior.

| Pending | File and line | Follow-up ownership | Source interaction |
|---|---|---|---|
| [ ] | [CompanionRootView.swift:106](../Annex/Annex/Companion/Views/CompanionRootView.swift#L106) | Root lane | Replace generic navigation observation with explicit user intent at the actual originating action. |
| [ ] | [CompanionRootView.swift:719](../Annex/Annex/Companion/Views/CompanionRootView.swift#L719) | Root lane | Project reorder interaction. |
| [ ] | [CompanionRootView.swift:1354](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1354) | Root lane | Search presentation/submit; never export the query. |
| [ ] | [CompanionDispatcherSettingsSections.swift:215](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L215) | Dispatcher/settings owner | Identity draft submit; never export the draft. |
| [ ] | [CompanionDispatcherSettingsSections.swift:238](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L238) | Dispatcher/settings owner | Emoji draft submit; never export the value. |
| [ ] | [CompanionMarkdownBlockViews.swift:85](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L85) | Chat lane | Inline preview tap. |
| [ ] | [CompanionAgentDetailsSheet.swift:153](../Annex/Annex/Companion/Views/CompanionAgentDetailsSheet.swift#L153) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionAgentSettingsSheet.swift:180](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L180) | Follow-up owner to assign | `Button { selection = color.id } label: {` |
| [ ] | [CompanionAgentSettingsSheet.swift:375](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L375) | Follow-up owner to assign | `Button("Retry") { Task { await load() } }` |
| [ ] | [CompanionAgentSettingsSheet.swift:398](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L398) | Follow-up owner to assign | `NavigationLink("Auto provider and plan limits") { CompanionHelperPresetsView(store: store, hostID: target.hostID, agentID: target.agentID) }` |
| [ ] | [CompanionAgentSettingsSheet.swift:458](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L458) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionAgentSettingsSheet.swift:466](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L466) | Follow-up owner to assign | `Menu {` |
| [ ] | [CompanionAgentSettingsSheet.swift:817](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L817) | Follow-up owner to assign | `Toggle(isOn: Binding(get: { dispatcher.enabled },` |
| [ ] | [CompanionAgentSettingsSheet.swift:866](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L866) | Follow-up owner to assign | `Button("Wake with a message", systemImage: "text.bubble", action: onWakeWithMessage)` |
| [ ] | [CompanionAgentSettingsSheet.swift:871](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L871) | Follow-up owner to assign | `Button(choice.label, systemImage: choice.systemImage) { Task { await store.wake(agent.id, choice) } }` |
| [ ] | [CompanionAgentSettingsSheet.swift:878](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L878) | Follow-up owner to assign | `Button("Dismiss", systemImage: "xmark") { store.justCreated = nil }` |
| [ ] | [CompanionAgentTreeRows.swift:38](../Annex/Annex/Companion/Views/CompanionAgentTreeRows.swift#L38) | Follow-up owner to assign | `Button(action: toggle) {` |
| [ ] | [CompanionAgentTreeRows.swift:52](../Annex/Annex/Companion/Views/CompanionAgentTreeRows.swift#L52) | Follow-up owner to assign | `NavigationLink(value: row.id) {` |
| [ ] | [CompanionAgentTreeRows.swift:76](../Annex/Annex/Companion/Views/CompanionAgentTreeRows.swift#L76) | Follow-up owner to assign | `Button {` |
| [ ] | [CompanionAppRoot.swift:293](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L293) | Root/settings owner (shared file) | `Button("OK") { runtime.restoreError = nil }` |
| [ ] | [CompanionAppRoot.swift:341](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L341) | Root/settings owner (shared file) | `Button("Feedback needs a new invitation. Reports stay on this device. Open Settings.") { openSettings() }` |
| [ ] | [CompanionAppRoot.swift:412](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L412) | Root/settings owner (shared file) | `DisclosureGroup("Connection details") {` |
| [ ] | [CompanionAppRoot.swift:419](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L419) | Root/settings owner (shared file) | `Button("Pair another desktop", systemImage: "plus", action: pair)` |
| [ ] | [CompanionAppRoot.swift:432](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L432) | Root/settings owner (shared file) | `Picker("Fold idle projects after", selection: Bindable(runtime.preferences).idleDays) {` |
| [ ] | [CompanionAppRoot.swift:452](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L452) | Root/settings owner (shared file) | `NavigationLink("Connection diagnostics") { CompanionDiagnosticsView(exporter: runtime.telemetryExporter) }` |
| [ ] | [CompanionAppRoot.swift:463](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L463) | Root/settings owner (shared file) | `.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }` |
| [ ] | [CompanionAppRoot.swift:466](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L466) | Root/settings owner (shared file) | `Button("Forget desktop", role: .destructive) {` |
| [ ] | [CompanionAppRoot.swift:479](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L479) | Root/settings owner (shared file) | `Button("End session pairing", role: .destructive) {` |
| [ ] | [CompanionAppRoot.swift:512](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L512) | Root/settings owner (shared file) | `Button("Retry", action: retry)` |
| [ ] | [CompanionAppRoot.swift:516](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L516) | Root/settings owner (shared file) | `Button("End session pairing", role: .destructive, action: endSession)` |
| [ ] | [CompanionAppRoot.swift:520](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L520) | Root/settings owner (shared file) | `Button("Forget on this device", role: .destructive, action: forget)` |
| [ ] | [CompanionAppRoot.swift:540](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L540) | Root/settings owner (shared file) | `Button("Copy build SHA", systemImage: "doc.on.doc") { UIPasteboard.general.string = sha }` |
| [ ] | [CompanionAppRoot.swift:542](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L542) | Root/settings owner (shared file) | `Button("Copy version", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }` |
| [ ] | [CompanionAppRoot.swift:556](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L556) | Root/settings owner (shared file) | `Picker("Start screen", selection: $preferences.startScreen) {` |
| [ ] | [CompanionAppUpdateView.swift:12](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L12) | Follow-up owner to assign | `Button(alreadyChecking ? "Already checking" : checking ? "Checking…" : "Check for updates") {` |
| [ ] | [CompanionAppUpdateView.swift:31](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L31) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionAppUpdateView.swift:92](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L92) | Follow-up owner to assign | `Button("Cancel update request", role: .destructive) {` |
| [ ] | [CompanionAppUpdateView.swift:101](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L101) | Follow-up owner to assign | `Button("Restart to update to \(version)") {` |
| [ ] | [CompanionAppUpdateView.swift:112](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L112) | Follow-up owner to assign | `Button("Turn on Dispatcher") {` |
| [ ] | [CompanionArchiveView.swift:22](../Annex/Annex/Companion/Views/CompanionArchiveView.swift#L22) | Follow-up owner to assign | `Button("Try again") { Task { await load() } }` |
| [ ] | [CompanionArchiveView.swift:26](../Annex/Annex/Companion/Views/CompanionArchiveView.swift#L26) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionArchiveView.swift:45](../Annex/Annex/Companion/Views/CompanionArchiveView.swift#L45) | Follow-up owner to assign | `.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }` |
| [ ] | [CompanionArchiveView.swift:85](../Annex/Annex/Companion/Views/CompanionArchiveView.swift#L85) | Follow-up owner to assign | `Button("Try again") { Task { await transcript.loadEarlier() } }` |
| [ ] | [CompanionArchiveView.swift:87](../Annex/Annex/Companion/Views/CompanionArchiveView.swift#L87) | Follow-up owner to assign | `Button("Show earlier messages", systemImage: "arrow.up.circle") { shownEntries += CompanionTimelineWindow.pageSize }` |
| [ ] | [CompanionArchiveView.swift:90](../Annex/Annex/Companion/Views/CompanionArchiveView.swift#L90) | Follow-up owner to assign | `Button("Load earlier messages", systemImage: "arrow.up.circle") {` |
| [ ] | [CompanionAttachments.swift:31](../Annex/Annex/Companion/Views/CompanionAttachments.swift#L31) | Chat lane / follow-up owner | `Button { Task { await add([CompanionSampleImage.png(index: store.attachmentDrafts[target]?.count ?? 0)]) } } label: { icon }` |
| [ ] | [CompanionAttachments.swift:33](../Annex/Annex/Companion/Views/CompanionAttachments.swift#L33) | Chat lane / follow-up owner | `PhotosPicker(selection: $selection, maxSelectionCount: max(1, remaining), selectionBehavior: .ordered,` |
| [ ] | [CompanionAttachments.swift:97](../Annex/Annex/Companion/Views/CompanionAttachments.swift#L97) | Chat lane / follow-up owner | `Button { store.removeAttachment(image.id, from: target) } label: {` |
| [ ] | [CompanionAttachments.swift:147](../Annex/Annex/Companion/Views/CompanionAttachments.swift#L147) | Chat lane / follow-up owner | `Button { if let reference { presenter?.open(reference) } } label: {` |
| [ ] | [CompanionAutoQuotaViews.swift:45](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L45) | Follow-up owner to assign | `Toggle("Allow Copilot as a last resort", isOn: Binding(get: { copilotAuto }, set: { value in` |
| [ ] | [CompanionAutoQuotaViews.swift:68](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L68) | Follow-up owner to assign | `Button(valueText(value, scope: scopeID)) { change(value) }` |
| [ ] | [CompanionAutoQuotaViews.swift:129](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L129) | Follow-up owner to assign | `DisclosureGroup("Limits for individual models") { modelWindows }` |
| [ ] | [CompanionAutoQuotaViews.swift:222](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L222) | Follow-up owner to assign | `DisclosureGroup(provider + " limit at decision") { CompanionQuotaView(quota: quota, labels: labels) }` |
| [ ] | [CompanionAutoQuotaViews.swift:234](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L234) | Follow-up owner to assign | `Button("OK", role: .cancel) { }` |
| [ ] | [CompanionAutoQuotaViews.swift:237](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L237) | Follow-up owner to assign | `Button("OK", role: .cancel) { }` |
| [ ] | [CompanionChangesView.swift:34](../Annex/Annex/Companion/Views/CompanionChangesView.swift#L34) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionChangesView.swift:52](../Annex/Annex/Companion/Views/CompanionChangesView.swift#L52) | Follow-up owner to assign | `Button("Try again") { Task { await load() } }.buttonStyle(.bordered)` |
| [ ] | [CompanionChangesView.swift:162](../Annex/Annex/Companion/Views/CompanionChangesView.swift#L162) | Follow-up owner to assign | `Button("Try again") { Task { await load() } }.buttonStyle(.bordered)` |
| [ ] | [CompanionChatControlsBar.swift:27](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L27) | Chat lane / follow-up owner | `Menu {` |
| [ ] | [CompanionChatControlsBar.swift:54](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L54) | Chat lane / follow-up owner | `return Menu {` |
| [ ] | [CompanionChatControlsBar.swift:57](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L57) | Chat lane / follow-up owner | `Button {` |
| [ ] | [CompanionChatControlsBar.swift:95](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L95) | Chat lane / follow-up owner | `Menu {` |
| [ ] | [CompanionChatControlsBar.swift:98](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L98) | Chat lane / follow-up owner | `Button {` |
| [ ] | [CompanionChatControlsBar.swift:109](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L109) | Chat lane / follow-up owner | `Button("Try again", action: retrySavedModel)` |
| [ ] | [CompanionChatControlsBar.swift:131](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L131) | Chat lane / follow-up owner | `Menu {` |
| [ ] | [CompanionChatControlsBar.swift:135](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L135) | Chat lane / follow-up owner | `Button {` |
| [ ] | [CompanionChatControlsBar.swift:146](../Annex/Annex/Companion/Views/CompanionChatControlsBar.swift#L146) | Chat lane / follow-up owner | `Button {` |
| [ ] | [CompanionContentView.swift:84](../Annex/Annex/Companion/Views/CompanionContentView.swift#L84) | Follow-up owner to assign | `Button { presenter.open(reference) } label: {` |
| [ ] | [CompanionContentView.swift:160](../Annex/Annex/Companion/Views/CompanionContentView.swift#L160) | Follow-up owner to assign | `Button("Try again") { Task { await load() } }.frame(maxWidth: .infinity)` |
| [ ] | [CompanionContentView.swift:175](../Annex/Annex/Companion/Views/CompanionContentView.swift#L175) | Follow-up owner to assign | `Button("Copy image", systemImage: "doc.on.doc") { UIPasteboard.general.image = image }` |
| [ ] | [CompanionContentView.swift:194](../Annex/Annex/Companion/Views/CompanionContentView.swift#L194) | Follow-up owner to assign | `Button("Copy preview", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }` |
| [ ] | [CompanionContentView.swift:208](../Annex/Annex/Companion/Views/CompanionContentView.swift#L208) | Follow-up owner to assign | `.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close).accessibilityIdentifier("companion-preview-done") } }` |
| [ ] | [CompanionConversationComposer.swift:129](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L129) | Chat lane / follow-up owner | `Button { confirmCancel = true } label: {` |
| [ ] | [CompanionConversationComposer.swift:143](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L143) | Chat lane / follow-up owner | `Button(action: sendMessage) {` |
| [ ] | [CompanionConversationComposer.swift:181](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L181) | Chat lane / follow-up owner | `Button("Switch to \(level.label)") { Task { await store.setLevel(level, target: target) } }` |
| [ ] | [CompanionConversationComposer.swift:266](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L266) | Chat lane / follow-up owner | `Button(action: dismissKeyboard) {` |
| [ ] | [CompanionConversationComposer.swift:663](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L663) | Chat lane / follow-up owner | `Button("Close", action: close)` |
| [ ] | [CompanionConversationGrantRequests.swift:110](../Annex/Annex/Companion/Views/CompanionConversationGrantRequests.swift#L110) | Chat lane / follow-up owner | `Button("Close") { showsReview = false }` |
| [ ] | [CompanionConversationGrantRequests.swift:131](../Annex/Annex/Companion/Views/CompanionConversationGrantRequests.swift#L131) | Chat lane / follow-up owner | `Button { showsReview = true } label: {` |
| [ ] | [CompanionConversationHeader.swift:35](../Annex/Annex/Companion/Views/CompanionConversationHeader.swift#L35) | Chat lane / follow-up owner | `Button { isExpanded.toggle() } label: {` |
| [ ] | [CompanionConversationHeader.swift:265](../Annex/Annex/Companion/Views/CompanionConversationHeader.swift#L265) | Chat lane / follow-up owner | `NavigationLink { CompanionPlanLimitsView(store: store) } label: {` |
| [ ] | [CompanionConversationHeader.swift:273](../Annex/Annex/Companion/Views/CompanionConversationHeader.swift#L273) | Chat lane / follow-up owner | `.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }` |
| [ ] | [CompanionConversationPendingDecisions.swift:36](../Annex/Annex/Companion/Views/CompanionConversationPendingDecisions.swift#L36) | Chat lane / follow-up owner | `Button("Previous request", systemImage: "chevron.left") { selectedID = queue[index - 1].id }` |
| [ ] | [CompanionConversationPendingDecisions.swift:39](../Annex/Annex/Companion/Views/CompanionConversationPendingDecisions.swift#L39) | Chat lane / follow-up owner | `Button("Next request", systemImage: "chevron.right") { selectedID = queue[index + 1].id }` |
| [ ] | [CompanionConversationPendingDecisions.swift:43](../Annex/Annex/Companion/Views/CompanionConversationPendingDecisions.swift#L43) | Chat lane / follow-up owner | `Button("Show in chat", systemImage: "text.bubble") { showInChat(decision.id) }` |
| [ ] | [CompanionConversationPendingDecisions.swift:46](../Annex/Annex/Companion/Views/CompanionConversationPendingDecisions.swift#L46) | Chat lane / follow-up owner | `Button("Review request", systemImage: "hand.raised.fill") {` |
| [ ] | [CompanionConversationView.swift:110](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L110) | Chat lane / follow-up owner | `Button("Open on \(machine)", systemImage: "arrow.up.right.square") { store.openOnOtherMachine(from: target) }` |
| [ ] | [CompanionConversationView.swift:115](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L115) | Chat lane / follow-up owner | `Button("Dismiss", systemImage: "xmark") { store.dismissError(for: target) }.labelStyle(.iconOnly)` |
| [ ] | [CompanionConversationView.swift:167](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L167) | Chat lane / follow-up owner | `Button("Header alignment", systemImage: "circle") {}` |
| [ ] | [CompanionConversationView.swift:194](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L194) | Chat lane / follow-up owner | `Menu {` |
| [ ] | [CompanionConversationView.swift:195](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L195) | Chat lane / follow-up owner | `Button("Refresh conversation", systemImage: "arrow.clockwise") { Task { await store.load(target, force: true) } }` |
| [ ] | [CompanionConversationView.swift:196](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L196) | Chat lane / follow-up owner | `Button("Conversation archive", systemImage: "clock.arrow.circlepath") { showArchive = true }` |
| [ ] | [CompanionConversationView.swift:197](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L197) | Chat lane / follow-up owner | `Button("Context and plan limits", systemImage: "chart.pie") { showContextSettings = true }` |
| [ ] | [CompanionConversationView.swift:208](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L208) | Chat lane / follow-up owner | `Button(choice.label, systemImage: choice.systemImage) { Task { await store.wake(target, choice) } }` |
| [ ] | [CompanionConversationView.swift:213](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L213) | Chat lane / follow-up owner | `Button("Interrupt turn", systemImage: "stop.circle", role: .destructive) { confirmCancel = true }` |
| [ ] | [CompanionConversationView.swift:216](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L216) | Chat lane / follow-up owner | `if let sendFeedback { Button("Send feedback", systemImage: "exclamationmark.bubble", action: sendFeedback) }` |
| [ ] | [CompanionConversationView.swift:261](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L261) | Chat lane / follow-up owner | `Button("Interrupt turn", role: .destructive) { Task { await store.cancel(target) } }` |
| [ ] | [CompanionConversationView.swift:262](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L262) | Chat lane / follow-up owner | `Button("Cancel", role: .cancel) {}` |
| [ ] | [CompanionConversationView.swift:265](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L265) | Chat lane / follow-up owner | `Button("OK", role: .cancel) { }` |
| [ ] | [CompanionConversationView.swift:303](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L303) | Chat lane / follow-up owner | `Button { showContextSettings = true } label: {` |
| [ ] | [CompanionConversationView.swift:381](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L381) | Chat lane / follow-up owner | `Button { openAgent(other.id) } label: {` |
| [ ] | [CompanionConversationView.swift:392](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L392) | Chat lane / follow-up owner | `Button("View") { openAgent(other.id) }.buttonStyle(.glass)` |
| [ ] | [CompanionConversationView.swift:426](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L426) | Chat lane / follow-up owner | `Button("Show earlier messages", systemImage: "arrow.up.circle") {` |
| [ ] | [CompanionConversationView.swift:661](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L661) | Chat lane / follow-up owner | `Button("Read earlier messages in archive", systemImage: "clock.arrow.circlepath") { showArchive = true }` |
| [ ] | [CompanionConversationView.swift:1034](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L1034) | Chat lane / follow-up owner | `Button(action: previous) { icon("chevron.up") }` |
| [ ] | [CompanionConversationView.swift:1039](../Annex/Annex/Companion/Views/CompanionConversationView.swift#L1039) | Chat lane / follow-up owner | `Button(action: next) { icon("chevron.down") }` |
| [ ] | [CompanionDesign.swift:342](../Annex/Annex/Companion/Views/CompanionDesign.swift#L342) | Follow-up owner to assign | `Button { selection = value } label: {` |
| [ ] | [CompanionDiagnosticsView.swift:16](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L16) | Follow-up owner to assign | `Picker("Capture", selection: Binding(get: { settings.mode }, set: {` |
| [ ] | [CompanionDiagnosticsView.swift:37](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L37) | Follow-up owner to assign | `NavigationLink("Tracing destination") { CompanionTelemetryDestinationView() }` |
| [ ] | [CompanionDiagnosticsView.swift:40](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L40) | Follow-up owner to assign | `Button("Review diagnostic export") {` |
| [ ] | [CompanionDiagnosticsView.swift:45](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L45) | Follow-up owner to assign | `Button("Clear captured diagnostics", role: .destructive) {` |
| [ ] | [CompanionDiagnosticsView.swift:53](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L53) | Follow-up owner to assign | `DisclosureGroup {` |
| [ ] | [CompanionDiagnosticsView.swift:74](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L74) | Follow-up owner to assign | `.toolbar { Button("Refresh", systemImage: "arrow.clockwise", action: refresh) }` |
| [ ] | [CompanionDiagnosticsView.swift:81](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L81) | Follow-up owner to assign | `ToolbarItem(placement: .cancellationAction) { Button("Done") { reviewedExport = nil } }` |
| [ ] | [CompanionDiagnosticsView.swift:88](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L88) | Follow-up owner to assign | `.alert("Could not prepare bounded export", isPresented: $exportError) { Button("OK") {} }` |
| [ ] | [CompanionDiagnosticsView.swift:107](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L107) | Follow-up owner to assign | `Button("Save destination without enabling") {` |
| [ ] | [CompanionDiagnosticsView.swift:118](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L118) | Follow-up owner to assign | `Button(settings.remoteEnabled ? "Disable collector export" : "Enable reviewed collector export") {` |
| [ ] | [CompanionDiagnosticsView.swift:121](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L121) | Follow-up owner to assign | `Button("Remove destination", role: .destructive) { settings.removeDestination(); address = "" }` |
| [ ] | [CompanionDiagnosticsView.swift:129](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L129) | Follow-up owner to assign | `Button("I verified this collector — enable export") { settings.setRemoteEnabled(true) }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:88](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L88) | Follow-up owner to assign | `Button("Try again") { Task { await reload() } }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:115](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L115) | Follow-up owner to assign | `Button {` |
| [ ] | [CompanionDispatcherSettingsSections.swift:149](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L149) | Follow-up owner to assign | `Toggle("Choose models yourself", isOn: Binding(get: { settings.models.byHand }, set: { on in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:170](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L170) | Follow-up owner to assign | `Picker("CLI", selection: Binding(get: { provider ?? "" }, set: { id in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:179](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L179) | Follow-up owner to assign | `Picker("Model", selection: Binding(get: { pick?.model ?? "default" }, set: { id in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:189](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L189) | Follow-up owner to assign | `Picker("Effort", selection: Binding<String?>(get: { pick?.effort }, set: { effort in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:249](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L249) | Follow-up owner to assign | `Button("Clear emoji", systemImage: "xmark.circle.fill") { save(.emoji) { try await store.updateDispatcher(.init(emoji: .clear), hostID: hostID) } }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:265](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L265) | Follow-up owner to assign | `Picker("Personality", selection: Binding(get: { personality.preset ?? "custom" }, set: { preset in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:285](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L285) | Follow-up owner to assign | `Button("Revert") { drafts.personality.receive(personality.text, replacing: true) }.buttonStyle(.borderless)` |
| [ ] | [CompanionDispatcherSettingsSections.swift:287](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L287) | Follow-up owner to assign | `Button("Save personality") { save(.personality) { try await store.updateDispatcher(.init(personality: .init(text: text)), hostID: hostID) } }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:334](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L334) | Follow-up owner to assign | `Button("Clear chat", role: .destructive) { Task { await store.askDispatcherReset(.clearChat, hostID: hostID) } }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:337](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L337) | Follow-up owner to assign | `Button("Forget everything", role: .destructive) { Task { await store.askDispatcherReset(.forgetEverything, hostID: hostID) } }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:351](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L351) | Follow-up owner to assign | `Button(prompt.reset.action, role: .destructive) { Task { await store.confirmDispatcherReset(prompt) } }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:352](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L352) | Follow-up owner to assign | `Button("Cancel", role: .cancel) { store.cancelDispatcherReset() }` |
| [ ] | [CompanionFeedback.swift:127](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L127) | Follow-up owner to assign | `NavigationLink("Invitation & enrollment") { CompanionFeedbackEnrollment(model: model) }` |
| [ ] | [CompanionFeedback.swift:129](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L129) | Follow-up owner to assign | `NavigationLink("Send feedback") { CompanionFeedbackCapturedComposer(model: model, capture: initialCapture) }` |
| [ ] | [CompanionFeedback.swift:150](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L150) | Follow-up owner to assign | `Toggle("Shake to open feedback", isOn: $shakeEnabled)` |
| [ ] | [CompanionFeedback.swift:151](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L151) | Follow-up owner to assign | `Toggle("Attach a screenshot when you shake", isOn: $shakeAttachesScreenshot).disabled(!shakeEnabled)` |
| [ ] | [CompanionFeedback.swift:152](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L152) | Follow-up owner to assign | `Toggle("Offer feedback when you take a screenshot", isOn: $screenshotOffersFeedback)` |
| [ ] | [CompanionFeedback.swift:245](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L245) | Follow-up owner to assign | `Button("Change fixture enrollment", action: fixtureControls.changeEnrollment)` |
| [ ] | [CompanionFeedback.swift:246](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L246) | Follow-up owner to assign | `Button("Record later retry", action: fixtureControls.recordLater)` |
| [ ] | [CompanionFeedback.swift:281](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L281) | Follow-up owner to assign | `DisclosureGroup("Feedback diagnostics test") {` |
| [ ] | [CompanionFeedback.swift:282](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L282) | Follow-up owner to assign | `NavigationLink("Prepare one diagnostics test report…") {` |
| [ ] | [CompanionFeedback.swift:302](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L302) | Follow-up owner to assign | `NavigationLink("Prepare test report") { CompanionFeedbackComposer(model: model, isDiagnosticsTest: true) }` |
| [ ] | [CompanionFeedback.swift:346](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L346) | Follow-up owner to assign | `Button("Send with this enrollment…") {` |
| [ ] | [CompanionFeedback.swift:352](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L352) | Follow-up owner to assign | `Button("Send") { Task { await model.releaseHeldReports(releaseToken: release.token) } }` |
| [ ] | [CompanionFeedback.swift:356](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L356) | Follow-up owner to assign | `Button("Clear held reports", role: .destructive) {` |
| [ ] | [CompanionFeedback.swift:363](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L363) | Follow-up owner to assign | `Button("Clear held reports", role: .destructive) {` |
| [ ] | [CompanionFeedback.swift:380](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L380) | Follow-up owner to assign | `Button("Clear queued feedback", role: .destructive) { confirmingClear = true }` |
| [ ] | [CompanionFeedback.swift:383](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L383) | Follow-up owner to assign | `Button("Clear queued feedback", role: .destructive) { Task { await model.clearQueue() } }` |
| [ ] | [CompanionFeedbackPresenter.swift:364](../Annex/Annex/Companion/Views/CompanionFeedbackPresenter.swift#L364) | Follow-up owner to assign | `Button(action: open) {` |
| [ ] | [CompanionFeedbackPresenter.swift:369](../Annex/Annex/Companion/Views/CompanionFeedbackPresenter.swift#L369) | Follow-up owner to assign | `Button("Dismiss", systemImage: "xmark", action: close)` |
| [ ] | [CompanionFeedbackPresenter.swift:389](../Annex/Annex/Companion/Views/CompanionFeedbackPresenter.swift#L389) | Follow-up owner to assign | `ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }` |
| [ ] | [CompanionFolderList.swift:18](../Annex/Annex/Companion/Views/CompanionFolderList.swift#L18) | Follow-up owner to assign | `NavigationLink { destination(listing.path(of: entry)) } label: { row(entry, chevron: true) }` |
| [ ] | [CompanionFullEventReview.swift:24](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L24) | Follow-up owner to assign | `Button(reference.reviewLabel, systemImage: "doc.text.magnifyingglass") { presenter.open(reference) }` |
| [ ] | [CompanionFullEventReview.swift:78](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L78) | Follow-up owner to assign | `ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }` |
| [ ] | [CompanionFullEventReview.swift:81](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L81) | Follow-up owner to assign | `Button("Reviewed") {` |
| [ ] | [CompanionFullEventReview.swift:91](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L91) | Follow-up owner to assign | `Button("Close review") { dismiss() }` |
| [ ] | [CompanionGuidedProviderScreen.swift:41](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L41) | Follow-up owner to assign | `Button {` |
| [ ] | [CompanionGuidedProviderScreen.swift:66](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L66) | Follow-up owner to assign | `Button("Check previous result") { Task { await flow.checkPreviousResult() } }` |
| [ ] | [CompanionGuidedProviderScreen.swift:74](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L74) | Follow-up owner to assign | `Button("Refresh preview") { Task { await flow.refresh() } }` |
| [ ] | [CompanionGuidedProviderScreen.swift:78](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L78) | Follow-up owner to assign | `Button("Save provider") { Task { await flow.save() } }` |
| [ ] | [CompanionGuidedProviderScreen.swift:84](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L84) | Follow-up owner to assign | `Button("Start new session") { confirmStart = true }` |
| [ ] | [CompanionGuidedProviderScreen.swift:101](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L101) | Follow-up owner to assign | `Button("Start new session") { Task { await flow.startNew() } }` |
| [ ] | [CompanionGuidedProviderScreen.swift:102](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L102) | Follow-up owner to assign | `Button("Cancel", role: .cancel) {}` |
| [ ] | [CompanionHelperPresetsView.swift:15](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L15) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionHelperPresetsView.swift:60](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L60) | Follow-up owner to assign | `DisclosureGroup {` |
| [ ] | [CompanionHelperPresetsView.swift:89](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L89) | Follow-up owner to assign | `Button("Reset all presets") { reset(.init()) }.disabled(!canEdit)` |
| [ ] | [CompanionHelperPresetsView.swift:122](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L122) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionHelperPresetsView.swift:138](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L138) | Follow-up owner to assign | `Button("Reset provider presets") { reset(.init(provider: id)) }.disabled(!canEdit)` |
| [ ] | [CompanionHelperPresetsView.swift:153](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L153) | Follow-up owner to assign | `NavigationLink(agent.name) { CompanionHelperPresetsView(store: store, hostID: hostID, agentID: agent.id.agentID) }` |
| [ ] | [CompanionHelperPresetsView.swift:160](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L160) | Follow-up owner to assign | `NavigationLink(project.name) { CompanionHelperPresetsView(store: store, hostID: hostID, projectID: project.id) }` |
| [ ] | [CompanionHelperPresetsView.swift:205](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L205) | Follow-up owner to assign | `Picker("Model", selection: Binding(get: { model }, set: { model = $0; effort = nil })) {` |
| [ ] | [CompanionHelperPresetsView.swift:213](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L213) | Follow-up owner to assign | `Picker("Effort", selection: $effort) {` |
| [ ] | [CompanionHelperPresetsView.swift:219](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L219) | Follow-up owner to assign | `Button(screen.saving ? "Saving…" : "Save preset") {` |
| [ ] | [CompanionHelperPresetsView.swift:232](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L232) | Follow-up owner to assign | `Button("Reset preset") {` |
| [ ] | [CompanionMarkdownBlockViews.swift:57](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L57) | Chat lane / follow-up owner | `Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: open)` |
| [ ] | [CompanionMarkdownBlockViews.swift:61](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L61) | Chat lane / follow-up owner | `Button("Copy", systemImage: "doc.on.doc", action: copy)` |
| [ ] | [CompanionMarkdownBlockViews.swift:75](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L75) | Chat lane / follow-up owner | `Button(action: open) {` |
| [ ] | [CompanionMarkdownBlockViews.swift:87](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L87) | Chat lane / follow-up owner | `Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: open)` |
| [ ] | [CompanionMarkdownBlockViews.swift:88](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L88) | Chat lane / follow-up owner | `Button(preview.copyTitle, systemImage: "doc.on.doc", action: copy)` |
| [ ] | [CompanionMarkdownBlockViews.swift:277](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L277) | Chat lane / follow-up owner | `Button("Done", action: close).accessibilityIdentifier("companion-markdown-block-done")` |
| [ ] | [CompanionMarkdownBlockViews.swift:280](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L280) | Chat lane / follow-up owner | `Button(preview.copyTitle, systemImage: "doc.on.doc") { UIPasteboard.general.string = preview.copyText }` |
| [ ] | [CompanionMarkdownFileView.swift:25](../Annex/Annex/Companion/Views/CompanionMarkdownFileView.swift#L25) | Chat lane / follow-up owner | `Picker("Markdown view", selection: $mode) {` |
| [ ] | [CompanionMarkdownFileView.swift:61](../Annex/Annex/Companion/Views/CompanionMarkdownFileView.swift#L61) | Chat lane / follow-up owner | `Button("Try again") { attempt += 1 }` |
| [ ] | [CompanionMarkdownFileView.swift:79](../Annex/Annex/Companion/Views/CompanionMarkdownFileView.swift#L79) | Chat lane / follow-up owner | `Button("Copy preview", systemImage: "doc.on.doc") { UIPasteboard.general.string = source }` |
| [ ] | [CompanionMarkdownFileView.swift:151](../Annex/Annex/Companion/Views/CompanionMarkdownFileView.swift#L151) | Chat lane / follow-up owner | `Button("Load image") { requested = true }.disabled(loading)` |
| [ ] | [CompanionPairingSheet.swift:60](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L60) | Follow-up owner to assign | `Button { scanning = true } label: {` |
| [ ] | [CompanionPairingSheet.swift:78](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L78) | Follow-up owner to assign | `Button("Scan again") { discovery.stop(); discovery.start() }` |
| [ ] | [CompanionPairingSheet.swift:82](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L82) | Follow-up owner to assign | `Button {` |
| [ ] | [CompanionPairingSheet.swift:103](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L103) | Follow-up owner to assign | `Button {` |
| [ ] | [CompanionPairingSheet.swift:115](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L115) | Follow-up owner to assign | `Toggle("These fingerprints match my desktop", isOn: $verified)` |
| [ ] | [CompanionPairingSheet.swift:124](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L124) | Follow-up owner to assign | `Toggle("Remember this desktop", isOn: $remember)` |
| [ ] | [CompanionPairingSheet.swift:135](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L135) | Follow-up owner to assign | `ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isPairing) }` |
| [ ] | [CompanionPairingSheet.swift:137](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L137) | Follow-up owner to assign | `Button { Task { await pair() } } label: {` |
| [ ] | [CompanionPlanLimitsView.swift:9](../Annex/Annex/Companion/Views/CompanionPlanLimitsView.swift#L9) | Follow-up owner to assign | `NavigationLink { CompanionPlanLimitsView(store: store) } label: {` |
| [ ] | [CompanionProjectPage.swift:182](../Annex/Annex/Companion/Views/CompanionProjectPage.swift#L182) | Follow-up owner to assign | `NavigationLink(value: run.target) { label }` |
| [ ] | [CompanionProjectPage.swift:230](../Annex/Annex/Companion/Views/CompanionProjectPage.swift#L230) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionProjectPage.swift:307](../Annex/Annex/Companion/Views/CompanionProjectPage.swift#L307) | Follow-up owner to assign | `Picker("Agent", selection: $selection) {` |
| [ ] | [CompanionQRPairing.swift:37](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L37) | Follow-up owner to assign | `Button("Cancel", systemImage: "xmark", action: onCancel)` |
| [ ] | [CompanionQRPairing.swift:49](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L49) | Follow-up owner to assign | `Button("Pair manually", action: onCancel).buttonStyle(.glass).controlSize(.large).padding(.top, 12)` |
| [ ] | [CompanionQRPairing.swift:127](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L127) | Follow-up owner to assign | `Toggle("Remember this desktop", isOn: $remember)` |
| [ ] | [CompanionQRPairing.swift:138](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L138) | Follow-up owner to assign | `Button { Task { await pair() } } label: {` |
| [ ] | [CompanionQRPairing.swift:142](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L142) | Follow-up owner to assign | `Button("Scan again", action: onScanAgain).disabled(isPairing)` |
| [ ] | [CompanionQuestionCard.swift:29](../Annex/Annex/Companion/Views/CompanionQuestionCard.swift#L29) | Chat lane / follow-up owner | `Button {` |
| [ ] | [CompanionQuestionCard.swift:62](../Annex/Annex/Companion/Views/CompanionQuestionCard.swift#L62) | Chat lane / follow-up owner | `Button("Send answers", systemImage: "arrow.up") { respond(answers) }` |
| [ ] | [CompanionRecoveryStatusView.swift:68](../Annex/Annex/Companion/Views/CompanionRecoveryStatusView.swift#L68) | Follow-up owner to assign | `Button { onRetry(action) } label: {` |
| [ ] | [CompanionRecoveryStatusView.swift:76](../Annex/Annex/Companion/Views/CompanionRecoveryStatusView.swift#L76) | Follow-up owner to assign | `Button { showsDetails = true } label: {` |
| [ ] | [CompanionRecoveryStatusView.swift:106](../Annex/Annex/Companion/Views/CompanionRecoveryStatusView.swift#L106) | Follow-up owner to assign | `Button {` |
| [ ] | [CompanionRecoveryStatusView.swift:128](../Annex/Annex/Companion/Views/CompanionRecoveryStatusView.swift#L128) | Follow-up owner to assign | `Button { dismiss() } label: {` |
| [ ] | [CompanionReviewView.swift:27](../Annex/Annex/Companion/Views/CompanionReviewView.swift#L27) | Follow-up owner to assign | `Button("Review", systemImage: "rectangle.stack") { openReview(.init(needsYouOnly: needsYouOnly)) }` |
| [ ] | [CompanionReviewView.swift:91](../Annex/Annex/Companion/Views/CompanionReviewView.swift#L91) | Follow-up owner to assign | `Button("Done") { dismiss() }.accessibilityIdentifier("review-done")` |
| [ ] | [CompanionReviewView.swift:138](../Annex/Annex/Companion/Views/CompanionReviewView.swift#L138) | Follow-up owner to assign | `Button { isOn.toggle() } label: {` |
| [ ] | [CompanionReviewView.swift:191](../Annex/Annex/Companion/Views/CompanionReviewView.swift#L191) | Follow-up owner to assign | `Button("Wake") { Task { await store.wake(entry.id) } }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)` |
| [ ] | [CompanionReviewView.swift:194](../Annex/Annex/Companion/Views/CompanionReviewView.swift#L194) | Follow-up owner to assign | `Button("Show sleeping") { filters.includeSleeping = true }` |
| [ ] | [CompanionReviewView.swift:199](../Annex/Annex/Companion/Views/CompanionReviewView.swift#L199) | Follow-up owner to assign | `Button("Show everyone") { filters.needsYouOnly = false }` |
| [ ] | [CompanionRootView.swift:188](../Annex/Annex/Companion/Views/CompanionRootView.swift#L188) | Root lane | `Menu {` |
| [ ] | [CompanionRootView.swift:191](../Annex/Annex/Companion/Views/CompanionRootView.swift#L191) | Root lane | `Button {` |
| [ ] | [CompanionRootView.swift:211](../Annex/Annex/Companion/Views/CompanionRootView.swift#L211) | Root lane | `Button {} label: {` |
| [ ] | [CompanionRootView.swift:229](../Annex/Annex/Companion/Views/CompanionRootView.swift#L229) | Root lane | `Button("Settings", systemImage: "gearshape") { navigation.interact(); onSettings() }` |
| [ ] | [CompanionRootView.swift:331](../Annex/Annex/Companion/Views/CompanionRootView.swift#L331) | Root lane | `Button("Pair a desktop", action: onPair).buttonStyle(.glassProminent).companionProminentLabel().controlSize(.large)` |
| [ ] | [CompanionRootView.swift:358](../Annex/Annex/Companion/Views/CompanionRootView.swift#L358) | Root lane | `Button("OK", role: .cancel) {}` |
| [ ] | [CompanionRootView.swift:363](../Annex/Annex/Companion/Views/CompanionRootView.swift#L363) | Root lane | `Button("Settings", systemImage: "gearshape", action: onSettings)` |
| [ ] | [CompanionRootView.swift:367](../Annex/Annex/Companion/Views/CompanionRootView.swift#L367) | Root lane | `Menu {` |
| [ ] | [CompanionRootView.swift:368](../Annex/Annex/Companion/Views/CompanionRootView.swift#L368) | Root lane | `Button("Send feedback", systemImage: "exclamationmark.bubble", action: sendFeedback)` |
| [ ] | [CompanionRootView.swift:374](../Annex/Annex/Companion/Views/CompanionRootView.swift#L374) | Root lane | `Button("New agent", systemImage: "plus") {` |
| [ ] | [CompanionRootView.swift:413](../Annex/Annex/Companion/Views/CompanionRootView.swift#L413) | Root lane | `Button("Retry") { Task { await store.reconnect(hostID: host.id) } }` |
| [ ] | [CompanionRootView.swift:437](../Annex/Annex/Companion/Views/CompanionRootView.swift#L437) | Root lane | `NavigationLink(value: item.agent.id) {` |
| [ ] | [CompanionRootView.swift:495](../Annex/Annex/Companion/Views/CompanionRootView.swift#L495) | Root lane | `Menu {` |
| [ ] | [CompanionRootView.swift:496](../Annex/Annex/Companion/Views/CompanionRootView.swift#L496) | Root lane | `Picker("Sort projects", selection: $preferences.projectSort) {` |
| [ ] | [CompanionRootView.swift:500](../Annex/Annex/Companion/Views/CompanionRootView.swift#L500) | Root lane | `Button("Arrange projects…", systemImage: "line.3.horizontal") { arranging = true }` |
| [ ] | [CompanionRootView.swift:513](../Annex/Annex/Companion/Views/CompanionRootView.swift#L513) | Root lane | `Button {` |
| [ ] | [CompanionRootView.swift:560](../Annex/Annex/Companion/Views/CompanionRootView.swift#L560) | Root lane | `Button { onNewAgent(entry.id) } label: { Image(systemName: "plus") }` |
| [ ] | [CompanionRootView.swift:602](../Annex/Annex/Companion/Views/CompanionRootView.swift#L602) | Root lane | `Menu {` |
| [ ] | [CompanionRootView.swift:607](../Annex/Annex/Companion/Views/CompanionRootView.swift#L607) | Root lane | `Menu(group.entry.label(for: member)) {` |
| [ ] | [CompanionRootView.swift:634](../Annex/Annex/Companion/Views/CompanionRootView.swift#L634) | Root lane | `Button(group.isPinned ? "Unpin project" : "Pin project", systemImage: group.isPinned ? "pin.slash" : "pin") {` |
| [ ] | [CompanionRootView.swift:638](../Annex/Annex/Companion/Views/CompanionRootView.swift#L638) | Root lane | `Button("Mark active", systemImage: "sun.max") {` |
| [ ] | [CompanionRootView.swift:642](../Annex/Annex/Companion/Views/CompanionRootView.swift#L642) | Root lane | `Button("Mark inactive", systemImage: "moon.zzz") {` |
| [ ] | [CompanionRootView.swift:676](../Annex/Annex/Companion/Views/CompanionRootView.swift#L676) | Root lane | `NavigationLink(value: CompanionRoute.project(entry.id)) {` |
| [ ] | [CompanionRootView.swift:725](../Annex/Annex/Companion/Views/CompanionRootView.swift#L725) | Root lane | `ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }` |
| [ ] | [CompanionRootView.swift:727](../Annex/Annex/Companion/Views/CompanionRootView.swift#L727) | Root lane | `Button("Done") { preferences.setProjectOrder(order.map(\.orderKey)); dismiss() }` |
| [ ] | [CompanionRootView.swift:746](../Annex/Annex/Companion/Views/CompanionRootView.swift#L746) | Root lane | `Button { openAgent(agent.id) } label: {` |
| [ ] | [CompanionRootView.swift:791](../Annex/Annex/Companion/Views/CompanionRootView.swift#L791) | Root lane | `Button("Turn on Dispatcher") { Task { await store.setDispatcher(enabled: true, hostID: hostID) } }` |
| [ ] | [CompanionRootView.swift:803](../Annex/Annex/Companion/Views/CompanionRootView.swift#L803) | Root lane | `Button("Retry") { Task { await store.reconnect(hostID: hostID) } }` |
| [ ] | [CompanionRootView.swift:823](../Annex/Annex/Companion/Views/CompanionRootView.swift#L823) | Root lane | `Button("Dismiss", systemImage: "xmark") { store.dismissDecisionNotice(notice) }` |
| [ ] | [CompanionRootView.swift:884](../Annex/Annex/Companion/Views/CompanionRootView.swift#L884) | Root lane | `Button("Undo") { decisions.undo(pending.id) }.buttonStyle(.glass)` |
| [ ] | [CompanionRootView.swift:894](../Annex/Annex/Companion/Views/CompanionRootView.swift#L894) | Root lane | `Button("OK", role: .cancel) { }` |
| [ ] | [CompanionRootView.swift:903](../Annex/Annex/Companion/Views/CompanionRootView.swift#L903) | Root lane | `Button("Allow", systemImage: "checkmark") { schedule(item, option) }.tint(Color(palette.success))` |
| [ ] | [CompanionRootView.swift:908](../Annex/Annex/Companion/Views/CompanionRootView.swift#L908) | Root lane | `Button("Deny", systemImage: "xmark") { schedule(item, option) }.tint(Color(palette.error))` |
| [ ] | [CompanionRootView.swift:950](../Annex/Annex/Companion/Views/CompanionRootView.swift#L950) | Root lane | `Button("Retry") { Task { await store.reconnect(hostID: hostID) } }` |
| [ ] | [CompanionRootView.swift:1033](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1033) | Root lane | `Button { Task { await store.respond(approval, option: deny, target: item.agent.id) } } label: {` |
| [ ] | [CompanionRootView.swift:1039](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1039) | Root lane | `Button { Task { await store.respond(approval, option: allow, target: item.agent.id) } } label: {` |
| [ ] | [CompanionRootView.swift:1050](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1050) | Root lane | `NavigationLink(value: item.agent.id) { Text("Review full request in chat") }` |
| [ ] | [CompanionRootView.swift:1057](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1057) | Root lane | `NavigationLink(value: item.agent.id) { Text(item.kind == .failure ? "Open chat" : "Answer in chat") }` |
| [ ] | [CompanionRootView.swift:1089](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1089) | Root lane | `Button { Task { await store.answer(request, approve: false) } } label: {` |
| [ ] | [CompanionRootView.swift:1095](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1095) | Root lane | `Button {` |
| [ ] | [CompanionRootView.swift:1117](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1117) | Root lane | `Button(request.approveLabel, role: .destructive) { Task { await store.answer(request, approve: true) } }` |
| [ ] | [CompanionRootView.swift:1118](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1118) | Root lane | `Button("Cancel", role: .cancel) {}` |
| [ ] | [CompanionRootView.swift:1201](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1201) | Root lane | `Button("Open chat") { openAgent(request.agentTarget) }` |
| [ ] | [CompanionRootView.swift:1203](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1203) | Root lane | `NavigationLink(value: request.agentTarget) { Text("Open chat") }` |
| [ ] | [CompanionRootView.swift:1215](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1215) | Root lane | `Button("Restart now") { Task { await store.answer(request, with: .allowOnce, updateMode: .now) } }` |
| [ ] | [CompanionRootView.swift:1218](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1218) | Root lane | `Button("Restart when idle") { Task { await store.answer(request, with: .allowOnce, updateMode: .whenIdle) } }` |
| [ ] | [CompanionRootView.swift:1223](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1223) | Root lane | `Button("Cancel", role: .cancel) { Task { await store.answer(request, with: .decline) } }` |
| [ ] | [CompanionRootView.swift:1229](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1229) | Root lane | `Button { Task { await store.answer(request, with: .decline) } } label: {` |
| [ ] | [CompanionRootView.swift:1236](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1236) | Root lane | `Button { Task { await store.answer(request, with: allow) } } label: {` |
| [ ] | [CompanionRootView.swift:1269](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1269) | Root lane | `NavigationLink(value: agent.id) {` |
| [ ] | [CompanionRootView.swift:1288](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1288) | Root lane | `Button("New agent", systemImage: "plus") {` |
| [ ] | [CompanionRootView.swift:1324](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1324) | Root lane | `NavigationLink(value: agent.id) {` |
| [ ] | [CompanionRootView.swift:1336](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1336) | Root lane | `NavigationLink {` |
| [ ] | [CompanionRootView.swift:1364](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1364) | Root lane | `NavigationLink(value: agent.id) {` |
| [ ] | [CompanionSlashMenuView.swift:34](../Annex/Annex/Companion/Views/CompanionSlashMenuView.swift#L34) | Chat lane / follow-up owner | `Button { pick(command) } label: {` |
| [ ] | [CompanionSpawnSheet.swift:34](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L34) | Managed-create lane | `Button("Cancel", systemImage: "xmark") { dismiss() }.disabled(store.spawnInProgress \|\| store.createInProgress)` |
| [ ] | [CompanionSpawnSheet.swift:42](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L42) | Managed-create lane | `Button("Continue with a new task") {` |
| [ ] | [CompanionSpawnSheet.swift:48](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L48) | Managed-create lane | `Button("Create another agent") { store.acknowledgeReviewedCreate() }` |
| [ ] | [CompanionSpawnSheet.swift:51](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L51) | Managed-create lane | `Button("Use \(pendingAccess?.label ?? "elevated Access")", role: .destructive) {` |
| [ ] | [CompanionSpawnSheet.swift:55](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L55) | Managed-create lane | `Button("Cancel", role: .cancel) { pendingAccess = nil }` |
| [ ] | [CompanionSpawnSheet.swift:91](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L91) | Managed-create lane | `Picker("Kind", selection: $kind) {` |
| [ ] | [CompanionSpawnSheet.swift:115](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L115) | Managed-create lane | `Picker("Runs on", selection: $provider) {` |
| [ ] | [CompanionSpawnSheet.swift:153](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L153) | Managed-create lane | `Button { showOptions.toggle() } label: {` |
| [ ] | [CompanionSpawnSheet.swift:164](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L164) | Managed-create lane | `Menu {` |
| [ ] | [CompanionSpawnSheet.swift:165](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L165) | Managed-create lane | `Picker("Project", selection: Binding(get: { selectedEntry?.id }, set: { if let id = $0 { selectEntry(id) } })) {` |
| [ ] | [CompanionSpawnSheet.swift:190](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L190) | Managed-create lane | `Picker("Machine", selection: $project) {` |
| [ ] | [CompanionSpawnSheet.swift:214](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L214) | Managed-create lane | `Button {` |
| [ ] | [CompanionSpawnSheet.swift:236](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L236) | Managed-create lane | `Button("Check previous request") { Task { if await store.checkSpawnOutcome() { dismiss() } } }` |
| [ ] | [CompanionSpawnSheet.swift:238](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L238) | Managed-create lane | `Button("View agents") { dismiss() }` |
| [ ] | [CompanionSpawnSheet.swift:239](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L239) | Managed-create lane | `Button("I've checked the agents") { confirmReviewedSpawn = true }` |
| [ ] | [CompanionSpawnSheet.swift:332](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L332) | Managed-create lane | `Button("Try again") { Task { await loadOptions() } }` |
| [ ] | [CompanionSpawnSheet.swift:355](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L355) | Managed-create lane | `Button("Randomize name", systemImage: "shuffle") { durable.name = CompanionAgentName.random() }` |
| [ ] | [CompanionSpawnSheet.swift:370](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L370) | Managed-create lane | `Picker("Runs on", selection: $durable.orchestrator) {` |
| [ ] | [CompanionSpawnSheet.swift:384](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L384) | Managed-create lane | `Picker("Model", selection: $durable.model) {` |
| [ ] | [CompanionSpawnSheet.swift:398](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L398) | Managed-create lane | `Toggle("Orchestrate", isOn: $durable.orchestrate)` |
| [ ] | [CompanionSpawnSheet.swift:408](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L408) | Managed-create lane | `Toggle("Own worktree and branch", isOn: $durable.useWorktree)` |
| [ ] | [CompanionSpawnSheet.swift:420](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L420) | Managed-create lane | `Picker("Access", selection: Binding(get: { durable.access ?? options.defaultAccess }, set: { level in` |
| [ ] | [CompanionSpawnSheet.swift:465](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L465) | Managed-create lane | `Toggle(isOn: Binding(get: { durable.mcpIDs.contains(server.id) },` |
| [ ] | [CompanionSpawnSheet.swift:480](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L480) | Managed-create lane | `Button {` |
| [ ] | [CompanionSpawnSheet.swift:508](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L508) | Managed-create lane | `Button("Check again") { Task { if await store.checkCreateOutcome() { dismiss() } } }` |
| [ ] | [CompanionSpawnSheet.swift:510](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L510) | Managed-create lane | `Button("I've checked the agents") { confirmReviewedCreate = true }` |
| [ ] | [CompanionTerminalView.swift:29](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L29) | Follow-up owner to assign | `Button("Terminal", systemImage: "terminal") { terminal.open(scope) }` |
| [ ] | [CompanionTerminalView.swift:62](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L62) | Follow-up owner to assign | `Button { dismiss() } label: {` |
| [ ] | [CompanionTerminalView.swift:69](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L69) | Follow-up owner to assign | `Menu {` |
| [ ] | [CompanionTerminalView.swift:70](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L70) | Follow-up owner to assign | `Button("Copy all", systemImage: "doc.on.doc") {` |
| [ ] | [CompanionTerminalView.swift:74](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L74) | Follow-up owner to assign | `if case .exited = session.state { Button(restartLabel, systemImage: "arrow.clockwise") { session.restart() } }` |
| [ ] | [CompanionTerminalView.swift:75](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L75) | Follow-up owner to assign | `if case .failed = session.state { Button("Try again", systemImage: "arrow.clockwise") { session.restart() } }` |
| [ ] | [CompanionTerminalView.swift:182](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L182) | Follow-up owner to assign | `if let action { Button(action.0, action: action.1).font(.footnote.weight(.semibold)).accessibilityIdentifier("terminal-retry") }` |
| [ ] | [CompanionTerminalView.swift:227](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L227) | Follow-up owner to assign | `PasteButton(payloadType: String.self) { strings in` |
| [ ] | [CompanionTerminalView.swift:232](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L232) | Follow-up owner to assign | `Button { focus.toggle() } label: {` |
| [ ] | [CompanionTerminalView.swift:247](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L247) | Follow-up owner to assign | `Button(action: action) {` |
| [ ] | [CompanionTerminalView.swift:257](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L257) | Follow-up owner to assign | `Button(action: action) {` |
| [ ] | [CompanionTimelineCards.swift:63](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L63) | Chat lane / follow-up owner | `Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }` |
| [ ] | [CompanionTimelineCards.swift:118](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L118) | Chat lane / follow-up owner | `Button("Remove from queue", systemImage: "minus.circle", action: removeQueued)` |
| [ ] | [CompanionTimelineCards.swift:132](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L132) | Chat lane / follow-up owner | `Button("Try sending again", action: retry).font(.subheadline.weight(.semibold)).disabled(!canRetry)` |
| [ ] | [CompanionTimelineCards.swift:227](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L227) | Chat lane / follow-up owner | `Button { expansion.open = !open } label: {` |
| [ ] | [CompanionTimelineCards.swift:277](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L277) | Chat lane / follow-up owner | `Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }` |
| [ ] | [CompanionTimelineCards.swift:427](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L427) | Chat lane / follow-up owner | `Button { expansion.open = !expanded } label: { Label(expanded ? "Hide output" : "Show output", systemImage: expanded ? "chevron.up" : "chevron.down") }` |
| [ ] | [CompanionTimelineCards.swift:434](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L434) | Chat lane / follow-up owner | `Button { expansion.open = !expanded } label: {` |
| [ ] | [CompanionTimelineCards.swift:522](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L522) | Chat lane / follow-up owner | `Button { state.open = !open } label: {` |
| [ ] | [CompanionTimelineCards.swift:597](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L597) | Chat lane / follow-up owner | `Button { expanded.toggle() } label: {` |
| [ ] | [CompanionTimelineCards.swift:680](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L680) | Chat lane / follow-up owner | `DisclosureGroup("Review details", isExpanded: $showDetails) {` |
| [ ] | [CompanionTimelineCards.swift:758](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L758) | Chat lane / follow-up owner | `Button(option.label) { respond(option) }` |
| [ ] | [CompanionTimelineCards.swift:773](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L773) | Chat lane / follow-up owner | `Button { respond(option) } label: {` |
| [ ] | [CompanionTimelineCards.swift:778](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L778) | Chat lane / follow-up owner | `Button(role: .destructive) { respond(option) } label: {` |
| [ ] | [CompanionTimelineCards.swift:789](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L789) | Chat lane / follow-up owner | `Menu("More", systemImage: "ellipsis") {` |
| [ ] | [CompanionTimelineCards.swift:792](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L792) | Chat lane / follow-up owner | `Button(option.label) { choose(option) }.disabled(option.allows && !canAllow)` |
| [ ] | [CompanionTimelineCards.swift:811](../Annex/Annex/Companion/Views/CompanionTimelineCards.swift#L811) | Chat lane / follow-up owner | `Button {` |
| [ ] | [CompanionWelcome.swift:32](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L32) | Follow-up owner to assign | `Button(action: onPair) { Text("Pair your Mac").frame(maxWidth: .infinity) }` |
| [ ] | [CompanionWelcome.swift:34](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L34) | Follow-up owner to assign | `Button("Look around first", action: onDemo).buttonStyle(.glass).controlSize(.large)` |
| [ ] | [CompanionWelcome.swift:78](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L78) | Follow-up owner to assign | `Button("Pair your Mac", action: onPair).buttonStyle(.glassProminent).companionProminentLabel()` |
| [ ] | [CompanionWelcome.swift:79](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L79) | Follow-up owner to assign | `Button("Close demo", systemImage: "xmark", action: onClose).labelStyle(.iconOnly).buttonStyle(.glass)` |

## Completion evidence

- [ ] All entries above are wired, or the final PR explicitly explains any intentional exclusion.
- [ ] UI tests show one Settings-open action for a tap and no new action after returning from a child page.
- [ ] At least one tab, toolbar, menu item, sheet-open and decision action is observed through the telemetry bridge with the expected screen/control.
- [ ] A dashboard query groups app.action logs by screen and control.
- [ ] The last integration PR closes #433.
