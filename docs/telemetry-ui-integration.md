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

## Dashboard grouping recipe

At the collector, filter `app.action` logs to `app.action.name == "uiAction"`, then count by the two string attributes `screen` and `control`. In the collector's native query syntax, express this logical query:

```text
logs
  filter event == "app.action" and attributes["app.action.name"] == "uiAction"
  group by attributes["screen"], attributes["control"]
  count as taps
```

This deliberately separates tap intent from command-outcome `app.action` logs. `dashboardCanCountTheSameControlSeparatelyByScreen` exercises the actual mapper output: two project / openAgentSettings intents and one conversation / openAgentSettings intent produce counts 2 and 1. This is a local schema/grouping proof; deploying and observing the query in the live dashboard remains on the completion checklist.

## Adopted here

#442 extends project instrumentation to the desktop chips, machine chooser selection/Cancel, explicit project-state menu callbacks and offline Retry. Shared chips, project menu items and merged quiet-fold callbacks inherit the owning screen. Callers must supply `.companionTelemetryScreen(_:)`; do not count Dismiss/Clear again in owner callbacks. Root adoption remains pending.

- Project page: New agent, Wake with a message, Terminal, retained-run Dismiss (swipe, context menu and accessibility action share one action), Clear all, and the Wake sheet's Cancel/Wake.
- Project info: its actual opening action, Done, and explicit retry after a failed read.
- Agent details/settings sheets: Done, retry, cancellation of settings confirmation, and saved identity, color, emoji, provider/model/runtime, access, auto-sleep, context-window and behavior controls. Only the fixed control category is recorded, never its value. A setting choice that opens a warning is counted immediately, even when later cancelled; accepting the warning records a separate `.confirm` intent, without double-counting the selection.
- Shared helper/quiet disclosures, agent menu items, Terminal entries, Dispatcher switch and new-agent notice actions: explicit screen context from `.companionTelemetryScreen(_:)`. A missing context records nothing, rather than guessing which Root/chat screen opened the control. Project page and settings form supply it; Root/chat adoption is still required. Shared terminal entries, Dispatcher switch and created-agent notice also require their actual originating screen context; do not add a duplicate record in the caller.

## App-owned leaf follow-up

The single leaf follow-up adopts explicit Terminal toolbar/key-bar and banner callbacks; Welcome/demo actions; manual and QR pairing callbacks; the shared color-swatches button; Dispatcher and guided provider settings; desktop-update callbacks; helper preset settings; manual plan-limit refresh; diagnostics settings; and app-owned feedback shortcuts, prompts and confirmations. The fixed intent is emitted before the existing callback. Automatic reads, polling, destination construction and programmatic draft resets emit nothing. Native Menu, NavigationLink, ShareLink and implicit DisclosureGroup openings remain pending a separate accessibility-preserving hook spike and decision; no gesture hook is rolled out here.

The shared swatch button owns `.selectColor`, so agent and Dispatcher settings no longer count it again while saving. Dispatcher/agent settings supply their own screen context. **Managed-create still needs `.companionTelemetryScreen(.newAgent)` around its shared swatches in CompanionSpawnSheet.swift; inline chat Terminal panes need `.conversation` from their owning lane.** Neither file is edited in the leaf follow-up. Until a caller supplies context, shared controls deliberately record nothing.

App-owned feedback code can record settings toggles, held/queued-report prompts and confirmations, the screenshot offer, and enrollment-sheet Done. The SDK composer, editor and enrollment controls remain blocked on the upstream callback and re-vendor described below. Native/system dismissal and debug fixture controls are excluded; no synthetic Cancel event is inferred from state changes.

## Deferred native-opening experiment

The public PrimitiveButtonStyle / configuration.trigger() comparison spike is deferred to free simulator capacity (orchestrator decision, November 16). Its unvalidated DEBUG-only experiment is preserved on `ux-433/native-hook-spike` at `1630522736bc3453d22c1913439659081ad17e88`; no product control adopts it. Native Menu, NavigationLink, ShareLink and implicit DisclosureGroup openings remain unchecked follow-ups. Run the untouched-versus-wrapped accessibility/default-action comparison and obtain a decision before any rollout.

#451 uses shared Settings sections in production and preview. Its moved explicit Pair, Close, idle-selection, Retry, Forget/revoke prompt and confirmation callbacks are adopted with fixed settings/desktopSettings intent; phone-name submit now inherits the settings context. Feedback consent, options and shortcut callbacks remain byte-identical. New Settings navigation destinations still await the deferred native-opening hook; no tap gesture or appearance inference is added.

## Required Root/settings follow-up

- Replace the undifferentiated Root `.navigation` tap event with explicit screen/control intents at each tab and navigation action. Set context separately for Home, Dispatcher, Needs you and Agents; do not apply one Home context around the whole tab tree.
- Remove the Settings `.onAppear { record(.settings) }` in **CompanionAppRoot.swift** and record `.openSettings` inside each actual Settings-opening action in **CompanionRootView.swift** and other entry points. Returning from a child page must not count as a new Settings open. No AppRoot, RootView, Navigation or HomeLayout changes are included here.
- Adopt the instrumented shared menus with the correct screen context. Instrument direct Root wake/decision controls independently; do not record a second intent for the same menu item.
- A native SwiftUI Menu opening must use a verified interaction hook that also handles accessibility activation. Do not infer it from destination appearance, add a tap gesture that breaks menu behavior, or record while constructing menu content. Menu item actions can be instrumented directly.

## Remaining source call sites

Checked entries identify callbacks adopted by the API or app-owned leaf follow-up. Each unchecked entry is a remaining interaction site, including the menu/picker opening and its item/selection action where they share a source declaration. A helper that generates several buttons needs the same closed control for each semantic action, with its caller's screen; never encode the selected identifier. Instrument explicit callbacks or selection setters, guarding equality when the native control can write an unchanged value. Follow-up owners must retain existing navigation, confirmation and disabled-state behavior.

| Pending | File and line | Follow-up ownership | Source interaction |
|---|---|---|---|
| [ ] | [CompanionRootView.swift:107](../Annex/Annex/Companion/Views/CompanionRootView.swift#L107) | Root lane | Replace generic navigation observation with explicit user intent at the actual originating action. |
| [ ] | [CompanionRootView.swift:723](../Annex/Annex/Companion/Views/CompanionRootView.swift#L723) | Root lane | Project reorder interaction. |
| [ ] | [CompanionRootView.swift:1358](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1358) | Root lane | Search presentation/submit; never export the query. |
| [x] | [CompanionDispatcherSettingsSections.swift:218](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L218) | ux-structure leaf callbacks | Identity draft submit; never export the draft. |
| [x] | [CompanionDispatcherSettingsSections.swift:242](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L242) | ux-structure leaf callbacks | Emoji draft submit; never export the value. |
| [ ] | [CompanionMarkdownBlockViews.swift:85](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L85) | Chat lane | Inline preview tap. |
| [ ] | [CompanionAgentDetailsSheet.swift:153](../Annex/Annex/Companion/Views/CompanionAgentDetailsSheet.swift#L153) | Follow-up owner to assign | `NavigationLink {` |
| [x] | [CompanionAgentSettingsSheet.swift:181](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L181) | ux-structure leaf callbacks | Shared color button owns `selectColor` once; Agent settings removes its prior save-side event in this same change. Other callers supply their originating screen. |
| [ ] | [CompanionAgentSettingsSheet.swift:405](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L405) | Native opening hook pending | `NavigationLink("Auto provider and plan limits") { CompanionHelperPresetsView(store: store, hostID: target.hostID, agentID: target.agentID) }` |
| [ ] | [CompanionAgentSettingsSheet.swift:468](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L468) | Native opening hook pending | `NavigationLink {` |
| [ ] | [CompanionAgentSettingsSheet.swift:476](../Annex/Annex/Companion/Views/CompanionAgentSettingsSheet.swift#L476) | Native opening hook pending | `Menu {` |
| [ ] | [CompanionAgentTreeRows.swift:129](../Annex/Annex/Companion/Views/CompanionAgentTreeRows.swift#L129) | Follow-up owner to assign | `NavigationLink(value: row.id) {` |
| [ ] | [CompanionAppRoot.swift:293](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L293) | Root/settings owner (shared file) | `Button("OK") { runtime.restoreError = nil }` |
| [ ] | [CompanionAppRoot.swift:341](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L341) | Root/settings owner (shared file) | `Button("Feedback needs a new invitation. Reports stay on this device. Open Settings.") { openSettings() }` |
| [ ] | [CompanionSettingsSections.swift:22](../Annex/Annex/Companion/Views/CompanionSettingsSections.swift#L22) | Native opening hook deferred | `CompanionSettingsDesktopPage(store: store, hostID: host.id,` |
| [x] | [CompanionSettingsSections.swift:33](../Annex/Annex/Companion/Views/CompanionSettingsSections.swift#L33) | ux-structure #451 callbacks | `CompanionUIActions.record(.connectDesktop, on: .settings)` |
| [x] | [CompanionSettingsSections.swift:96](../Annex/Annex/Companion/Views/CompanionSettingsSections.swift#L96) | ux-structure #451 callbacks | `Picker("Fold idle projects after", selection: Binding(get: { preferences.idleDays }, set: {` |
| [ ] | [CompanionSettingsSections.swift:72](../Annex/Annex/Companion/Views/CompanionSettingsSections.swift#L72) | Native opening hook deferred | `NavigationLink { CompanionDiagnosticsView(exporter: exporter) } label: {` |
| [x] | [CompanionAppRoot.swift:413](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L413) | ux-structure #451 callbacks | `Button("Close", systemImage: "xmark") {` |
| [x] | [CompanionAppRoot.swift:423](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L423) | ux-structure #451 callbacks | `Button("Forget desktop", role: .destructive) {` |
| [x] | [CompanionAppRoot.swift:437](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L437) | ux-structure #451 callbacks | `Button("End session pairing", role: .destructive) {` |
| [x] | [CompanionAppRoot.swift:471](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L471) | ux-structure #451 callbacks | `CompanionUIActions.record(.retry, on: .desktopSettings)` |
| [x] | [CompanionAppRoot.swift:478](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L478) | ux-structure #451 callbacks | `CompanionUIActions.record(.revokeSession, on: .desktopSettings)` |
| [x] | [CompanionAppRoot.swift:487](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L487) | ux-structure #451 callbacks | `CompanionUIActions.record(.forgetDesktop, on: .desktopSettings)` |
| [ ] | [CompanionAppRoot.swift:537](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L537) | Root/settings owner (shared file) | `Button("Copy build SHA", systemImage: "doc.on.doc") { UIPasteboard.general.string = sha }` |
| [ ] | [CompanionAppRoot.swift:539](../Annex/Annex/Companion/Views/CompanionAppRoot.swift#L539) | Root/settings owner (shared file) | `Button("Copy version", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }` |
| [x] | [CompanionAppUpdateView.swift:13](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L13) | ux-structure leaf callbacks | `Button(alreadyChecking ? "Already checking" : checking ? "Checking…" : "Check for updates") {` |
| [ ] | [CompanionAppUpdateView.swift:33](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L33) | Native opening hook pending | `NavigationLink {` |
| [x] | [CompanionAppUpdateView.swift:94](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L94) | ux-structure leaf callbacks | `Button("Cancel update request", role: .destructive) {` |
| [x] | [CompanionAppUpdateView.swift:104](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L104) | ux-structure leaf callbacks | `Button("Restart to update to \(version)") {` |
| [x] | [CompanionAppUpdateView.swift:116](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift#L116) | ux-structure leaf callbacks | `Button("Turn on Dispatcher") {` |
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
| [x] | [CompanionAutoQuotaViews.swift:45](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L45) | ux-structure leaf callbacks | `Toggle("Allow Copilot as a last resort", isOn: Binding(get: { copilotAuto }, set: { value in` |
| [x] | [CompanionAutoQuotaViews.swift:69](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L69) | ux-structure leaf callbacks | `Button(valueText(value, scope: scopeID)) { change(value) }` |
| [ ] | [CompanionAutoQuotaViews.swift:131](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L131) | Native opening hook pending | `DisclosureGroup("Limits for individual models") { modelWindows }` |
| [ ] | [CompanionAutoQuotaViews.swift:224](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L224) | Native opening hook pending | `DisclosureGroup(provider + " limit at decision") { CompanionQuotaView(quota: quota, labels: labels) }` |
| [ ] | [CompanionAutoQuotaViews.swift:236](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L236) | Follow-up owner to assign | `Button("OK", role: .cancel) { }` |
| [ ] | [CompanionAutoQuotaViews.swift:239](../Annex/Annex/Companion/Views/CompanionAutoQuotaViews.swift#L239) | Follow-up owner to assign | `Button("OK", role: .cancel) { }` |
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
| [ ] | [CompanionConversationComposer.swift:130](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L130) | Chat lane / follow-up owner | `Button { confirmCancel = true } label: {` |
| [ ] | [CompanionConversationComposer.swift:144](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L144) | Chat lane / follow-up owner | `Button(action: sendMessage) {` |
| [ ] | [CompanionConversationComposer.swift:182](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L182) | Chat lane / follow-up owner | `Button("Switch to \(level.label)") { Task { await store.setLevel(level, target: target) } }` |
| [ ] | [CompanionConversationComposer.swift:272](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L272) | Chat lane / follow-up owner | `Button(action: dismissKeyboard) {` |
| [ ] | [CompanionConversationComposer.swift:672](../Annex/Annex/Companion/Views/CompanionConversationComposer.swift#L672) | Chat lane / follow-up owner | `Button("Close", action: close)` |
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
| [ ] | [CompanionDesign.swift:364](../Annex/Annex/Companion/Views/CompanionDesign.swift#L364) | Follow-up owner to assign | `Button { selection = value } label: {` |
| [ ] | [CompanionDiagnosticsView.swift:16](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L16) | Native opening hook pending; selection wired here | `Picker("Capture", selection: Binding(get: { settings.mode }, set: {` |
| [ ] | [CompanionDiagnosticsView.swift:38](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L38) | Native opening hook pending | `NavigationLink("Tracing destination") { CompanionTelemetryDestinationView() }` |
| [x] | [CompanionDiagnosticsView.swift:41](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L41) | ux-structure leaf callbacks | `Button("Review diagnostic export") {` |
| [x] | [CompanionDiagnosticsView.swift:47](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L47) | ux-structure leaf callbacks | `Button("Clear captured diagnostics", role: .destructive) {` |
| [ ] | [CompanionDiagnosticsView.swift:56](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L56) | Native opening hook pending | `DisclosureGroup {` |
| [x] | [CompanionDiagnosticsView.swift:77](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L77) | ux-structure leaf callbacks | `.toolbar {` |
| [x] | [CompanionDiagnosticsView.swift:89](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L89) | ux-structure leaf callbacks | `}` |
| [x] | [CompanionDiagnosticsView.swift:101](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L101) | ux-structure leaf callbacks | `}` |
| [x] | [CompanionDiagnosticsView.swift:122](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L122) | ux-structure leaf callbacks | `Text("Use an existing HTTPS OTLP/HTTP JSON collector that forwards to your App Insights instance. An App Insights connection string is not an OTLP URL. This configuration is independent of developer feedback.")` |
| [x] | [CompanionDiagnosticsView.swift:134](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L134) | ux-structure leaf callbacks | `Section("Reviewed destination") {` |
| [x] | [CompanionDiagnosticsView.swift:138](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L138) | ux-structure leaf callbacks | `CompanionUIActions.record(.toggleCollectorExport, on: .telemetryDestination)` |
| [x] | [CompanionDiagnosticsView.swift:149](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L149) | ux-structure leaf callbacks | `.navigationTitle("Tracing destination")` |
| [x] | [CompanionDispatcherSettingsSections.swift:88](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L88) | ux-structure leaf callbacks | `Button("Try again") {` |
| [x] | [CompanionDispatcherSettingsSections.swift:118](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L118) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionDispatcherSettingsSections.swift:152](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L152) | ux-structure leaf callbacks | `Toggle("Choose models yourself", isOn: Binding(get: { settings.models.byHand }, set: { on in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:173](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L173) | Native opening hook pending; selection wired here | `Picker("CLI", selection: Binding(get: { provider ?? "" }, set: { id in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:182](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L182) | Native opening hook pending; selection wired here | `Picker("Model", selection: Binding(get: { pick?.model ?? "default" }, set: { id in` |
| [ ] | [CompanionDispatcherSettingsSections.swift:192](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L192) | Native opening hook pending; selection wired here | `Picker("Effort", selection: Binding<String?>(get: { pick?.effort }, set: { effort in` |
| [x] | [CompanionDispatcherSettingsSections.swift:253](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L253) | ux-structure leaf callbacks | `Button("Clear emoji", systemImage: "xmark.circle.fill") { save(.emoji, control: .selectEmoji) { try await store.updateDispatcher(.init(emoji: .clear), hostID: hostID) } }` |
| [ ] | [CompanionDispatcherSettingsSections.swift:269](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L269) | Native opening hook pending; selection wired here | `Picker("Personality", selection: Binding(get: { personality.preset ?? "custom" }, set: { preset in` |
| [x] | [CompanionDispatcherSettingsSections.swift:289](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L289) | ux-structure leaf callbacks | `Button("Revert") {` |
| [x] | [CompanionDispatcherSettingsSections.swift:294](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L294) | ux-structure leaf callbacks | `Button("Save personality") { save(.personality, control: .savePersonality) { try await store.updateDispatcher(.init(personality: .init(text: text)), hostID: hostID) } }` |
| [x] | [CompanionDispatcherSettingsSections.swift:341](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L341) | ux-structure leaf callbacks | `Button("Clear chat", role: .destructive) {` |
| [x] | [CompanionDispatcherSettingsSections.swift:347](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L347) | ux-structure leaf callbacks | `Button("Forget everything", role: .destructive) {` |
| [x] | [CompanionDispatcherSettingsSections.swift:364](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L364) | ux-structure leaf callbacks | `Button(prompt.reset.action, role: .destructive) {` |
| [x] | [CompanionDispatcherSettingsSections.swift:368](../Annex/Annex/Companion/Views/CompanionDispatcherSettingsSections.swift#L368) | ux-structure leaf callbacks | `Button("Cancel", role: .cancel) {` |
| [ ] | [CompanionFeedback.swift:127](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L127) | Native opening hook pending | `NavigationLink("Invitation & enrollment") { CompanionFeedbackEnrollment(model: model) }` |
| [ ] | [CompanionFeedback.swift:129](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L129) | Native opening hook pending | `NavigationLink("Send feedback") { CompanionFeedbackCapturedComposer(model: model, capture: initialCapture) }` |
| [x] | [CompanionFeedback.swift:150](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L150) | ux-structure leaf callbacks | `Toggle("Shake to open feedback", isOn: Binding(get: { shakeEnabled }, set: { value in` |
| [x] | [CompanionFeedback.swift:154](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L154) | ux-structure leaf callbacks | `Toggle("Attach a screenshot when you shake", isOn: Binding(get: { shakeAttachesScreenshot }, set: { value in` |
| [x] | [CompanionFeedback.swift:158](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L158) | ux-structure leaf callbacks | `Toggle("Offer feedback when you take a screenshot", isOn: Binding(get: { screenshotOffersFeedback }, set: { value in` |
| [ ] | [CompanionFeedback.swift:290](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L290) | Native opening hook pending | `DisclosureGroup("Feedback diagnostics test") {` |
| [ ] | [CompanionFeedback.swift:291](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L291) | Native opening hook pending | `NavigationLink("Prepare one diagnostics test report…") {` |
| [ ] | [CompanionFeedback.swift:311](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L311) | Native opening hook pending | `NavigationLink("Prepare test report") { CompanionFeedbackComposer(model: model, isDiagnosticsTest: true) }` |
| [x] | [CompanionFeedback.swift:355](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L355) | ux-structure leaf callbacks | `Button("Send with this enrollment…") {` |
| [x] | [CompanionFeedback.swift:362](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L362) | ux-structure leaf callbacks | `Button("Send") {` |
| [x] | [CompanionFeedback.swift:369](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L369) | ux-structure leaf callbacks | `Button("Clear held reports", role: .destructive) {` |
| [x] | [CompanionFeedback.swift:377](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L377) | ux-structure leaf callbacks | `Button("Clear held reports", role: .destructive) {` |
| [x] | [CompanionFeedback.swift:395](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L395) | ux-structure leaf callbacks | `Button("Clear queued feedback", role: .destructive) {` |
| [x] | [CompanionFeedback.swift:401](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L401) | ux-structure leaf callbacks | `Button("Clear queued feedback", role: .destructive) {` |
| [x] | [CompanionFeedbackPresenter.swift:364](../Annex/Annex/Companion/Views/CompanionFeedbackPresenter.swift#L364) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionFeedbackPresenter.swift:372](../Annex/Annex/Companion/Views/CompanionFeedbackPresenter.swift#L372) | ux-structure leaf callbacks | `Button("Dismiss", systemImage: "xmark") {` |
| [x] | [CompanionFeedbackPresenter.swift:395](../Annex/Annex/Companion/Views/CompanionFeedbackPresenter.swift#L395) | ux-structure leaf callbacks | `ToolbarItem(placement: .confirmationAction) {` |
| [ ] | [CompanionFolderList.swift:18](../Annex/Annex/Companion/Views/CompanionFolderList.swift#L18) | Follow-up owner to assign | `NavigationLink { destination(listing.path(of: entry)) } label: { row(entry, chevron: true) }` |
| [ ] | [CompanionFullEventReview.swift:24](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L24) | Follow-up owner to assign | `Button(reference.reviewLabel, systemImage: "doc.text.magnifyingglass") { presenter.open(reference) }` |
| [ ] | [CompanionFullEventReview.swift:78](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L78) | Follow-up owner to assign | `ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }` |
| [ ] | [CompanionFullEventReview.swift:81](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L81) | Follow-up owner to assign | `Button("Reviewed") {` |
| [ ] | [CompanionFullEventReview.swift:91](../Annex/Annex/Companion/Views/CompanionFullEventReview.swift#L91) | Follow-up owner to assign | `Button("Close review") { dismiss() }` |
| [x] | [CompanionGuidedProviderScreen.swift:41](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L41) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionGuidedProviderScreen.swift:67](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L67) | ux-structure leaf callbacks | `Button("Check previous result") {` |
| [x] | [CompanionGuidedProviderScreen.swift:78](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L78) | ux-structure leaf callbacks | `Button("Refresh preview") {` |
| [x] | [CompanionGuidedProviderScreen.swift:85](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L85) | ux-structure leaf callbacks | `Button("Save provider") {` |
| [x] | [CompanionGuidedProviderScreen.swift:94](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L94) | ux-structure leaf callbacks | `Button("Start new session") {` |
| [x] | [CompanionGuidedProviderScreen.swift:115](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L115) | ux-structure leaf callbacks | `Button("Start new session") {` |
| [x] | [CompanionGuidedProviderScreen.swift:119](../Annex/Annex/Companion/Views/CompanionGuidedProviderScreen.swift#L119) | ux-structure leaf callbacks | `Button("Cancel", role: .cancel) { CompanionUIActions.record(.cancel, on: .providerSettings) }` |
| [ ] | [CompanionHelperPresetsView.swift:15](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L15) | Native opening hook pending | `NavigationLink {` |
| [ ] | [CompanionHelperPresetsView.swift:60](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L60) | Native opening hook pending | `DisclosureGroup {` |
| [x] | [CompanionHelperPresetsView.swift:89](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L89) | ux-structure leaf callbacks | `Button("Reset all presets") { reset(.init(), control: .resetAllHelperPresets) }.disabled(!canEdit)` |
| [ ] | [CompanionHelperPresetsView.swift:125](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L125) | Native opening hook pending | `NavigationLink {` |
| [x] | [CompanionHelperPresetsView.swift:141](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L141) | ux-structure leaf callbacks | `Button("Reset provider presets") { reset(.init(provider: id), control: .resetProviderPresets) }.disabled(!canEdit)` |
| [ ] | [CompanionHelperPresetsView.swift:156](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L156) | Native opening hook pending | `NavigationLink(agent.name) { CompanionHelperPresetsView(store: store, hostID: hostID, agentID: agent.id.agentID) }` |
| [ ] | [CompanionHelperPresetsView.swift:163](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L163) | Native opening hook pending | `NavigationLink(project.name) { CompanionHelperPresetsView(store: store, hostID: hostID, projectID: project.id) }` |
| [ ] | [CompanionHelperPresetsView.swift:209](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L209) | Native opening hook pending; selection wired here | `Picker("Model", selection: Binding(get: { model }, set: { model = $0; effort = nil })) {` |
| [ ] | [CompanionHelperPresetsView.swift:220](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L220) | Native opening hook pending; selection wired here | `Picker("Effort", selection: $effort) {` |
| [x] | [CompanionHelperPresetsView.swift:229](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L229) | ux-structure leaf callbacks | `Button(screen.saving ? "Saving…" : "Save preset") {` |
| [x] | [CompanionHelperPresetsView.swift:243](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift#L243) | ux-structure leaf callbacks | `Button("Reset preset") {` |
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
| [x] | [CompanionPairingSheet.swift:61](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L61) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionPairingSheet.swift:82](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L82) | ux-structure leaf callbacks | `Button("Scan again") {` |
| [x] | [CompanionPairingSheet.swift:89](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L89) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionPairingSheet.swift:111](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L111) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionPairingSheet.swift:124](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L124) | ux-structure leaf callbacks | `Toggle("These fingerprints match my desktop", isOn: Binding(get: { verified }, set: {` |
| [x] | [CompanionPairingSheet.swift:137](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L137) | ux-structure leaf callbacks | `Toggle("Remember this desktop", isOn: Binding(get: { remember }, set: {` |
| [x] | [CompanionPairingSheet.swift:152](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L152) | ux-structure leaf callbacks | `ToolbarItem(placement: .cancellationAction) {` |
| [x] | [CompanionPairingSheet.swift:159](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift#L159) | ux-structure leaf callbacks | `Button {` |
| [ ] | [CompanionPlanLimitsView.swift:9](../Annex/Annex/Companion/Views/CompanionPlanLimitsView.swift#L9) | Follow-up owner to assign | `NavigationLink { CompanionPlanLimitsView(store: store) } label: {` |
| [ ] | [CompanionProjectPage.swift:50](../Annex/Annex/Companion/Views/CompanionProjectPage.swift#L50) | Project lane | Native Project options menu opening; the Project info item itself is instrumented. |
| [ ] | [CompanionProjectPage.swift:193](../Annex/Annex/Companion/Views/CompanionProjectPage.swift#L193) | Follow-up owner to assign | `NavigationLink(value: run.target) { label }` |
| [ ] | [CompanionProjectPage.swift:241](../Annex/Annex/Companion/Views/CompanionProjectPage.swift#L241) | Follow-up owner to assign | `NavigationLink {` |
| [ ] | [CompanionProjectPage.swift:318](../Annex/Annex/Companion/Views/CompanionProjectPage.swift#L318) | Follow-up owner to assign | `Picker("Agent", selection: $selection) {` |
| [x] | [CompanionQRPairing.swift:37](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L37) | ux-structure leaf callbacks | `Button("Cancel", systemImage: "xmark") {` |
| [x] | [CompanionQRPairing.swift:52](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L52) | ux-structure leaf callbacks | `Button("Pair manually") {` |
| [x] | [CompanionQRPairing.swift:133](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L133) | ux-structure leaf callbacks | `Toggle("Remember this desktop", isOn: Binding(get: { remember }, set: {` |
| [x] | [CompanionQRPairing.swift:148](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L148) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionQRPairing.swift:155](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L155) | ux-structure leaf callbacks | `Button("Scan again") {` |
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
| [x] | [CompanionDispatcherChips.swift](../Annex/Annex/Companion/Views/CompanionDispatcherChips.swift) | #444 | Explicit chip and collapsed-menu selection records `dispatcher/selectDesktop`. |
| [ ] | [CompanionDispatcherChips.swift](../Annex/Annex/Companion/Views/CompanionDispatcherChips.swift) | #433 follow-up | Native collapsed switcher Menu opening; AX-preserving hook experiment remains deferred. |
| [ ] | [CompanionDispatcherChips.swift](../Annex/Annex/Companion/Views/CompanionDispatcherChips.swift) | #433 follow-up | Explicit “Show Dispatcher chips” and “Collapse Dispatchers” callbacks need dedicated enum-only controls. |
| [ ] | [CompanionRootView.swift:343](../Annex/Annex/Companion/Views/CompanionRootView.swift#L343) | Root lane | `Button("Pair a desktop", action: onPair).buttonStyle(.glassProminent).companionProminentLabel().controlSize(.large)` |
| [ ] | [CompanionRootView.swift:369](../Annex/Annex/Companion/Views/CompanionRootView.swift#L369) | Root lane | `Button("OK", role: .cancel) {}` |
| [ ] | [CompanionRootView.swift:374](../Annex/Annex/Companion/Views/CompanionRootView.swift#L374) | Root lane | `Button("Settings", systemImage: "gearshape", action: onSettings)` |
| [ ] | [CompanionRootView.swift:378](../Annex/Annex/Companion/Views/CompanionRootView.swift#L378) | Root lane | `Menu {` |
| [ ] | [CompanionRootView.swift:379](../Annex/Annex/Companion/Views/CompanionRootView.swift#L379) | Root lane | `Button("Send feedback", systemImage: "exclamationmark.bubble", action: sendFeedback)` |
| [ ] | [CompanionRootView.swift:385](../Annex/Annex/Companion/Views/CompanionRootView.swift#L385) | Root lane | `Button("New agent", systemImage: "plus") {` |
| [ ] | [CompanionRootView.swift:426](../Annex/Annex/Companion/Views/CompanionRootView.swift#L426) | Root lane | `Button("Retry") { Task { await store.reconnect(hostID: host.id) } }` |
| [ ] | [CompanionRootView.swift:450](../Annex/Annex/Companion/Views/CompanionRootView.swift#L450) | Root lane | `NavigationLink(value: item.agent.id) {` |
| [ ] | [CompanionRootView.swift:508](../Annex/Annex/Companion/Views/CompanionRootView.swift#L508) | Root lane | `Menu {` |
| [ ] | [CompanionRootView.swift:509](../Annex/Annex/Companion/Views/CompanionRootView.swift#L509) | Root lane | `Picker("Sort projects", selection: $preferences.projectSort) {` |
| [ ] | [CompanionRootView.swift:513](../Annex/Annex/Companion/Views/CompanionRootView.swift#L513) | Root lane | `Button("Arrange projects…", systemImage: "line.3.horizontal") { arranging = true }` |
| [ ] | [CompanionRootView.swift:526](../Annex/Annex/Companion/Views/CompanionRootView.swift#L526) | Root lane | `Button {` |
| [ ] | [CompanionRootView.swift:573](../Annex/Annex/Companion/Views/CompanionRootView.swift#L573) | Root lane | `Button { onNewAgent(entry.id) } label: { Image(systemName: "plus") }` |
| [ ] | [CompanionRootView.swift:615](../Annex/Annex/Companion/Views/CompanionRootView.swift#L615) | Root lane | `Menu {` |
| [ ] | [CompanionRootView.swift:620](../Annex/Annex/Companion/Views/CompanionRootView.swift#L620) | Root lane | `Menu(group.entry.label(for: member)) {` |
| [ ] | [CompanionRootView.swift:647](../Annex/Annex/Companion/Views/CompanionRootView.swift#L647) | Root lane | `Button(group.isPinned ? "Unpin project" : "Pin project", systemImage: group.isPinned ? "pin.slash" : "pin") {` |
| [ ] | [CompanionRootView.swift:651](../Annex/Annex/Companion/Views/CompanionRootView.swift#L651) | Root lane | `Button("Mark active", systemImage: "sun.max") {` |
| [ ] | [CompanionRootView.swift:655](../Annex/Annex/Companion/Views/CompanionRootView.swift#L655) | Root lane | `Button("Mark inactive", systemImage: "moon.zzz") {` |
| [ ] | [CompanionRootView.swift:689](../Annex/Annex/Companion/Views/CompanionRootView.swift#L689) | Root lane | `NavigationLink(value: CompanionRoute.project(entry.id)) {` |
| [ ] | [CompanionRootView.swift:729](../Annex/Annex/Companion/Views/CompanionRootView.swift#L729) | Root lane | `ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }` |
| [ ] | [CompanionRootView.swift:731](../Annex/Annex/Companion/Views/CompanionRootView.swift#L731) | Root lane | `Button("Done") { preferences.setProjectOrder(order.map(\.orderKey)); dismiss() }` |
| [ ] | [CompanionRootView.swift:750](../Annex/Annex/Companion/Views/CompanionRootView.swift#L750) | Root lane | `Button { openAgent(agent.id) } label: {` |
| [ ] | [CompanionRootView.swift:795](../Annex/Annex/Companion/Views/CompanionRootView.swift#L795) | Root lane | `Button("Turn on Dispatcher") { Task { await store.setDispatcher(enabled: true, hostID: hostID) } }` |
| [ ] | [CompanionRootView.swift:807](../Annex/Annex/Companion/Views/CompanionRootView.swift#L807) | Root lane | `Button("Retry") { Task { await store.reconnect(hostID: hostID) } }` |
| [ ] | [CompanionRootView.swift:827](../Annex/Annex/Companion/Views/CompanionRootView.swift#L827) | Root lane | `Button("Dismiss", systemImage: "xmark") { store.dismissDecisionNotice(notice) }` |
| [ ] | [CompanionRootView.swift:888](../Annex/Annex/Companion/Views/CompanionRootView.swift#L888) | Root lane | `Button("Undo") { decisions.undo(pending.id) }.buttonStyle(.glass)` |
| [ ] | [CompanionRootView.swift:898](../Annex/Annex/Companion/Views/CompanionRootView.swift#L898) | Root lane | `Button("OK", role: .cancel) { }` |
| [ ] | [CompanionRootView.swift:907](../Annex/Annex/Companion/Views/CompanionRootView.swift#L907) | Root lane | `Button("Allow", systemImage: "checkmark") { schedule(item, option) }.tint(Color(palette.success))` |
| [ ] | [CompanionRootView.swift:912](../Annex/Annex/Companion/Views/CompanionRootView.swift#L912) | Root lane | `Button("Deny", systemImage: "xmark") { schedule(item, option) }.tint(Color(palette.error))` |
| [ ] | [CompanionRootView.swift:954](../Annex/Annex/Companion/Views/CompanionRootView.swift#L954) | Root lane | `Button("Retry") { Task { await store.reconnect(hostID: hostID) } }` |
| [ ] | [CompanionRootView.swift:1037](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1037) | Root lane | `Button { Task { await store.respond(approval, option: deny, target: item.agent.id) } } label: {` |
| [ ] | [CompanionRootView.swift:1043](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1043) | Root lane | `Button { Task { await store.respond(approval, option: allow, target: item.agent.id) } } label: {` |
| [ ] | [CompanionRootView.swift:1054](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1054) | Root lane | `NavigationLink(value: item.agent.id) { Text("Review full request in chat") }` |
| [ ] | [CompanionRootView.swift:1061](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1061) | Root lane | `NavigationLink(value: item.agent.id) { Text(item.kind == .failure ? "Open chat" : "Answer in chat") }` |
| [ ] | [CompanionRootView.swift:1093](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1093) | Root lane | `Button { Task { await store.answer(request, approve: false) } } label: {` |
| [ ] | [CompanionRootView.swift:1099](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1099) | Root lane | `Button {` |
| [ ] | [CompanionRootView.swift:1121](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1121) | Root lane | `Button(request.approveLabel, role: .destructive) { Task { await store.answer(request, approve: true) } }` |
| [ ] | [CompanionRootView.swift:1122](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1122) | Root lane | `Button("Cancel", role: .cancel) {}` |
| [ ] | [CompanionRootView.swift:1205](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1205) | Root lane | `Button("Open chat") { openAgent(request.agentTarget) }` |
| [ ] | [CompanionRootView.swift:1207](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1207) | Root lane | `NavigationLink(value: request.agentTarget) { Text("Open chat") }` |
| [ ] | [CompanionRootView.swift:1219](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1219) | Root lane | `Button("Restart now") { Task { await store.answer(request, with: .allowOnce, updateMode: .now) } }` |
| [ ] | [CompanionRootView.swift:1222](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1222) | Root lane | `Button("Restart when idle") { Task { await store.answer(request, with: .allowOnce, updateMode: .whenIdle) } }` |
| [ ] | [CompanionRootView.swift:1227](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1227) | Root lane | `Button("Cancel", role: .cancel) { Task { await store.answer(request, with: .decline) } }` |
| [ ] | [CompanionRootView.swift:1233](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1233) | Root lane | `Button { Task { await store.answer(request, with: .decline) } } label: {` |
| [ ] | [CompanionRootView.swift:1240](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1240) | Root lane | `Button { Task { await store.answer(request, with: allow) } } label: {` |
| [ ] | [CompanionRootView.swift:1273](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1273) | Root lane | `NavigationLink(value: agent.id) {` |
| [ ] | [CompanionRootView.swift:1292](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1292) | Root lane | `Button("New agent", systemImage: "plus") {` |
| [ ] | [CompanionRootView.swift:1328](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1328) | Root lane | `NavigationLink(value: agent.id) {` |
| [ ] | [CompanionRootView.swift:1340](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1340) | Root lane | `NavigationLink {` |
| [ ] | [CompanionRootView.swift:1368](../Annex/Annex/Companion/Views/CompanionRootView.swift#L1368) | Root lane | `NavigationLink(value: agent.id) {` |
| [ ] | [CompanionSlashMenuView.swift:34](../Annex/Annex/Companion/Views/CompanionSlashMenuView.swift#L34) | Chat lane / follow-up owner | `Button { pick(command) } label: {` |
| [ ] | [CompanionSpawnSheet.swift:36](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L36) | Managed-create lane | `Button("Cancel", systemImage: "xmark") { dismiss() }.disabled(store.spawnInProgress \|\| store.createInProgress)` |
| [ ] | [CompanionSpawnSheet.swift:44](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L44) | Managed-create lane | `Button("Continue with a new task") {` |
| [ ] | [CompanionSpawnSheet.swift:50](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L50) | Managed-create lane | `Button("Create another agent") { store.acknowledgeReviewedCreate() }` |
| [ ] | [CompanionSpawnSheet.swift:53](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L53) | Managed-create lane | `Button("Use \(pendingAccess?.label ?? "elevated Access")", role: .destructive) {` |
| [ ] | [CompanionSpawnSheet.swift:57](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L57) | Managed-create lane | `Button("Cancel", role: .cancel) { pendingAccess = nil }` |
| [ ] | [CompanionSpawnSheet.swift:94](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L94) | Managed-create lane | `Picker("Kind", selection: $kind) {` |
| [ ] | [CompanionSpawnSheet.swift:118](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L118) | Managed-create lane | `choiceMenu("Runs on", value: providers.first { $0.id == provider }?.name ?? "Project default", selection: $provider) {` |
| [ ] | [CompanionSpawnSheet.swift:157](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L157) | Managed-create lane | `Button { showOptions.toggle() } label: {` |
| [ ] | [CompanionSpawnSheet.swift:167](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L167) | Managed-create lane | `Menu {` |
| [ ] | [CompanionSpawnSheet.swift:168](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L168) | Managed-create lane | `Picker("Project", selection: Binding(get: { selectedEntry?.id }, set: { if let id = $0 { selectEntry(id) } })) {` |
| [ ] | [CompanionSpawnSheet.swift:193](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L193) | Managed-create lane | `Picker("Machine", selection: $project) {` |
| [ ] | [CompanionSpawnSheet.swift:217](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L217) | Managed-create lane | `Button {` |
| [ ] | [CompanionSpawnSheet.swift:239](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L239) | Managed-create lane | `Button("Check previous request") { Task { if await store.checkSpawnOutcome() { dismiss() } } }` |
| [ ] | [CompanionSpawnSheet.swift:241](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L241) | Managed-create lane | `Button("View agents") { dismiss() }` |
| [ ] | [CompanionSpawnSheet.swift:242](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L242) | Managed-create lane | `Button("I've checked the agents") { confirmReviewedSpawn = true }` |
| [ ] | [CompanionSpawnSheet.swift:338](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L338) | Managed-create lane | `Button("Try again") { Task { await loadOptions() } }` |
| [ ] | [CompanionSpawnSheet.swift:387](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L387) | Managed-create lane | `Menu { Picker(label, selection: selection) { choices() } } label: { pickerRow(label, value: value) }` |
| [ ] | [CompanionSpawnSheet.swift:429](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L429) | Managed-create lane | `choiceMenu("Runs on", value: options.options.orchestrator(durable.orchestrator)?.displayName ?? durable.orchestrator,` |
| [ ] | [CompanionSpawnSheet.swift:443](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L443) | Managed-create lane | `choiceMenu("Model", value: models.first { $0.id == durable.model }?.label ?? durable.model, selection: $durable.model) {` |
| [ ] | [CompanionSpawnSheet.swift:455](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L455) | Managed-create lane | `NavigationLink {` |
| [ ] | [CompanionSpawnSheet.swift:476](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L476) | Managed-create lane | `Button("Randomize name", systemImage: "shuffle") { durable.name = CompanionAgentName.random() }` |
| [ ] | [CompanionSpawnSheet.swift:486](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L486) | Managed-create lane | `choiceMenu("Access", value: current.map { level in` |
| [ ] | [CompanionSpawnSheet.swift:522](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L522) | Managed-create lane | `Toggle("Own worktree and branch", isOn: $durable.useWorktree)` |
| [ ] | [CompanionSpawnSheet.swift:532](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L532) | Managed-create lane | `Toggle("Can start helpers", isOn: $durable.orchestrate)` |
| [ ] | [CompanionSpawnSheet.swift:541](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L541) | Managed-create lane | `Toggle(isOn: Binding(get: { durable.mcpIDs.contains(server.id) },` |
| [ ] | [CompanionSpawnSheet.swift:561](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L561) | Managed-create lane | `Button {` |
| [ ] | [CompanionSpawnSheet.swift:589](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L589) | Managed-create lane | `Button("Check again") { Task { if await store.checkCreateOutcome() { dismiss() } } }` |
| [ ] | [CompanionSpawnSheet.swift:591](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift#L591) | Managed-create lane | `Button("I've checked the agents") { confirmReviewedCreate = true }` |
| [x] | [CompanionTerminalView.swift:67](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L67) | ux-structure leaf callbacks | `Button {` |
| [ ] | [CompanionTerminalView.swift:77](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L77) | Native opening hook pending | `Menu {` |
| [x] | [CompanionTerminalView.swift:78](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L78) | ux-structure leaf callbacks | `Button("Copy all", systemImage: "doc.on.doc") {` |
| [x] | [CompanionTerminalView.swift:84](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L84) | ux-structure leaf callbacks | `Button(restartLabel, systemImage: "arrow.clockwise") {` |
| [x] | [CompanionTerminalView.swift:90](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L90) | ux-structure leaf callbacks | `Button("Try again", systemImage: "arrow.clockwise") {` |
| [x] | [CompanionTerminalView.swift:203](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L203) | ux-structure leaf callbacks | `if let action {` |
| [x] | [CompanionTerminalView.swift:256](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L256) | ux-structure leaf callbacks | `PasteButton(payloadType: String.self) { strings in` |
| [x] | [CompanionTerminalView.swift:262](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L262) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionTerminalView.swift:279](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L279) | ux-structure leaf callbacks | `private func key(_ title: String, _ label: String, id: String, control: AnnexUIAction.Control, selected: Bool = false, action: @escaping () -> Void) -> some View {` |
| [x] | [CompanionTerminalView.swift:292](../Annex/Annex/Companion/Views/CompanionTerminalView.swift#L292) | ux-structure leaf callbacks | `private func icon(_ systemImage: String, _ label: String, id: String, control: AnnexUIAction.Control, action: @escaping () -> Void) -> some View {` |
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
| [x] | [CompanionWelcome.swift:33](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L33) | ux-structure leaf callbacks | `Button {` |
| [x] | [CompanionWelcome.swift:38](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L38) | ux-structure leaf callbacks | `Button("Look around first") {` |
| [x] | [CompanionWelcome.swift:85](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L85) | ux-structure leaf callbacks | `Button("Pair your Mac") {` |
| [x] | [CompanionWelcome.swift:89](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L89) | ux-structure leaf callbacks | `Button("Close demo", systemImage: "xmark") {` |

| [ ] | [CompanionSettingsSections.swift:52](../Annex/Annex/Companion/Views/CompanionSettingsSections.swift#L52) | Native opening hook deferred | `CompanionIdleProjectSettings(store: store, preferences: preferences)` |
| [ ] | [CompanionSettingsSections.swift:68](../Annex/Annex/Companion/Views/CompanionSettingsSections.swift#L68) | Native opening hook deferred | `}.accessibilityIdentifier("settings-phone-name")` |
| [ ] | [CompanionSettingsSections.swift:82](../Annex/Annex/Companion/Views/CompanionSettingsSections.swift#L82) | Native opening hook deferred | `}.navigationTitle("Direct connection").navigationBarTitleDisplayMode(.inline)` |
| [ ] | [CompanionFeedback.swift:130](../Annex/Annex/Companion/Views/CompanionFeedback.swift#L130) | Native opening hook deferred | `Form { CompanionFeedbackOptions(model: model, initialCapture: initialCapture, showsSend: false) }` |

## Completion evidence

- [ ] All entries above are wired, or the final PR explicitly explains any intentional exclusion.
- [ ] UI tests show one Settings-open action for a tap and no new action after returning from a child page.
- [ ] At least one tab, toolbar, menu item, sheet-open and decision action is observed through the telemetry bridge with the expected screen/control.
- [ ] A dashboard query groups app.action logs by screen and control.
- [ ] The last integration PR closes #433.

The vocabulary includes the adopted `projectInfo` screen and reserves `workspaceTools`, `openWorkspaceTools`, `selectMCP`, `toggleWorktree`, and `toggleHelpers` for the merged #455 surface. Project info now records its explicit opening, Done and retry actions here. The managed-create checklist above includes the real Workspace navigation, the shared native `choiceMenu` wrapper and each semantic call site. Its future wrapper should receive an explicit closed control argument; do not derive a control from its displayed string or selected value. These are closed semantic values; adopting lanes never pass project, machine, provider, model, MCP-server or agent identifiers. Newly introduced controls remain pending until their owning lane wires them.

The helper and quiet disclosures introduced by #434 are instrumented in their existing button callbacks. The row equality includes the explicit screen context, so a reused row cannot retain the previous originating screen. NavigationLink activation remains in the integration checklist.


## Additional explicit callbacks and remaining context

| Status | File | Interaction / remaining work |
|---|---|---|
| [x] | [CompanionPlanLimitsView.swift](../Annex/Annex/Companion/Views/CompanionPlanLimitsView.swift) | User pull-to-refresh only; automatic polls excluded. |
| [x] | [CompanionHelperPresetsView.swift](../Annex/Annex/Companion/Views/CompanionHelperPresetsView.swift) | User pull-to-refresh only; reconnect and foreground reads excluded. |
| [x] | [CompanionPairingSheet.swift](../Annex/Annex/Companion/Views/CompanionPairingSheet.swift) | Shared phone-name field submit records `.renamePhone` with explicit originating context, never the name. |
| [ ] | [CompanionAppRoot.swift](../Annex/Annex/Companion/Views/CompanionAppRoot.swift) | Settings owner must supply `.settings` context to the shared phone-name field. Shared file stays with Root/settings owner. |
| [ ] | [CompanionSpawnSheet.swift](../Annex/Annex/Companion/Views/CompanionSpawnSheet.swift) | Managed-create owner supplies `.newAgent` context to shared swatches. Native picker openings and remaining buttons retain their individual checklist entries above. |
| [ ] | [CompanionConversationView.swift](../Annex/Annex/Companion/Views/CompanionConversationView.swift) | Chat owner supplies `.conversation` context to inline Terminal panes (and the other instrumented shared controls). |
| [ ] | [CompanionDiagnosticsView.swift](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift) | Native export ShareLink needs the separately verified interaction hook. |
| [ ] | [CompanionAppUpdateView.swift](../Annex/Annex/Companion/Views/CompanionAppUpdateView.swift) | Root/settings owner supplies originating context to inline shared Check for updates actions; the standalone update page supplies `.desktopUpdate` itself. |

## Native link, share and photo-picker callbacks still pending

These native controls retain their system activation behavior. They need the separately verified hook or their owning lane's explicit selection callback; no content or destination value may enter telemetry.

| Pending | File | Interaction / owner |
|---|---|---|
| [ ] | [CompanionWelcome.swift:45](../Annex/Annex/Companion/Views/CompanionWelcome.swift#L45) | Website Link opening; native hook spike/decision. |
| [ ] | [CompanionQRPairing.swift:29](../Annex/Annex/Companion/Views/CompanionQRPairing.swift#L29) | System Settings Link opening; native hook spike/decision. |
| [ ] | [CompanionDiagnosticsView.swift:99](../Annex/Annex/Companion/Views/CompanionDiagnosticsView.swift#L99) | Reviewed export ShareLink; native hook spike/decision. |
| [ ] | [CompanionMarkdownBlockViews.swift:284](../Annex/Annex/Companion/Views/CompanionMarkdownBlockViews.swift#L284) | Preview ShareLink; chat owner plus verified native hook. |
| [ ] | [CompanionContentView.swift:176](../Annex/Annex/Companion/Views/CompanionContentView.swift#L176) | Image ShareLink; content/chat owner plus verified native hook. |
| [ ] | [CompanionAttachments.swift:33](../Annex/Annex/Companion/Views/CompanionAttachments.swift#L33) | Native photo-picker opening and explicit selection; chat owner. Never export image/content/selection identifiers. |

## Embedded feedback SDK controls

The app-owned boundary is `CompanionFeedbackComposer` in `CompanionFeedback.swift`; the composer and screenshot editor controls themselves live in the vendored FramebriarUI sources below. They are remaining integration sites, not instrumented by changing the vendor in this PR. **Requires an upstream Framebriar change (optional enum-only interaction callback), then re-vendor.** This includes the enrollment controls in `FeedbackModel.swift`. CI verifies the vendored directory byte-for-byte against `Vendor/Framebriar/SOURCE.json`; never instrument those files in place. After the upstream tag is re-vendored, the app-owned boundary can adopt its callback without forwarding any SDK data. Never forward feedback text, screenshots, marks, ink values or identifiers into telemetry.

| Pending | SDK file and line | Source interaction |
|---|---|---|
| [ ] | [FeedbackView.swift:75](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L75) | `ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() }.disabled(phase == .saving) }` |
| [ ] | [FeedbackView.swift:77](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L77) | `Button("Send") { send() }.disabled(sendBlock != nil \|\| draft == nil).accessibilityIdentifier("framebriar-send")` |
| [ ] | [FeedbackView.swift:80](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L80) | `ToolbarItem(placement: .confirmationAction) { Button("Done") { close() }.accessibilityIdentifier("framebriar-done") }` |
| [ ] | [FeedbackView.swift:97](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L97) | `TextEditor(text: $notes).frame(minHeight: 100).accessibilityLabel("Feedback notes").accessibilityIdentifier("framebriar-notes")` |
| [ ] | [FeedbackView.swift:103](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L103) | `PhotosPicker(attachment == nil ? "Add screenshot" : "Replace screenshot", selection: $selection, matching: .images)` |
| [ ] | [FeedbackView.swift:106](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L106) | `Button("Remove", role: .destructive) { selection = nil; attachment = nil }` |
| [ ] | [FeedbackView.swift:114](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L114) | `Toggle(FeedbackDisclosure.screenshotToggle, isOn: Binding(get: { self.attachment?.included ?? false }, set: { self.attachment?.included = $0 }))` |
| [ ] | [FeedbackView.swift:130](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L130) | `.gesture(TapGesture().onEnded { openEditor() })` |
| [ ] | [FeedbackView.swift:132](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L132) | `.accessibilityAction(named: "Zoom and mark up") { openEditor() }` |
| [ ] | [FeedbackView.swift:136](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L136) | `DisclosureGroup("What this means") {` |
| [ ] | [FeedbackView.swift:168](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackView.swift#L168) | `Toggle(FeedbackDisclosure.diagnosticsToggle, isOn: $includeDiagnostics).font(.footnote).accessibilityIdentifier("framebriar-diagnostics-switch")` |
| [ ] | [FeedbackScreenshotEditor.swift:62](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackScreenshotEditor.swift#L62) | `Button("Cancel") { onCancel() }.disabled(flattening).accessibilityIdentifier("framebriar-editor-cancel")` |
| [ ] | [FeedbackScreenshotEditor.swift:65](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackScreenshotEditor.swift#L65) | `Button("Undo") { _ = marks.popLast() }.disabled(marks.isEmpty \|\| flattening).accessibilityIdentifier("framebriar-editor-undo")` |
| [ ] | [FeedbackScreenshotEditor.swift:69](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackScreenshotEditor.swift#L69) | `Button("Done") { finish() }.disabled(image == nil).accessibilityIdentifier("framebriar-editor-done")` |
| [ ] | [FeedbackScreenshotEditor.swift:86](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackScreenshotEditor.swift#L86) | `Picker("Tool", selection: $tool) {` |
| [ ] | [FeedbackScreenshotEditor.swift:94](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackScreenshotEditor.swift#L94) | `Button("Clear edits", role: .destructive) { confirmClear = true }` |
| [ ] | [FeedbackScreenshotEditor.swift:102](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackScreenshotEditor.swift#L102) | `Button("Clear edits", role: .destructive) { marks = [] }.accessibilityIdentifier("framebriar-editor-clear-confirm")` |
| [ ] | [FeedbackScreenshotEditor.swift:109](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackScreenshotEditor.swift#L109) | `Button { ink = choice } label: {` |
| [ ] | [FeedbackModel.swift:225](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L225) | Redeem invitation — upstream enum-only callback, then re-vendor. Never export the invitation. |
| [ ] | [FeedbackModel.swift:229](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L229) | Clear enrollment prompt — upstream callback, then re-vendor. |
| [ ] | [FeedbackModel.swift:239](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L239) | Send held reports prompt — upstream callback, then re-vendor. Never export the token or count. |
| [ ] | [FeedbackModel.swift:243](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L243) | Clear held reports prompt — upstream callback, then re-vendor. |
| [ ] | [FeedbackModel.swift:247](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L247) | Retry delivery — upstream callback, then re-vendor. |
| [ ] | [FeedbackModel.swift:248](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L248) | Clear queued reports prompt — upstream callback, then re-vendor. |
| [ ] | [FeedbackModel.swift:256](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L256) | Clear queued reports confirmation — upstream callback, then re-vendor. |
| [ ] | [FeedbackModel.swift:260](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L260) | Send held reports confirmation — upstream callback, then re-vendor. |
| [ ] | [FeedbackModel.swift:265](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L265) | Clear held reports confirmation — upstream callback, then re-vendor. |
| [ ] | [FeedbackModel.swift:269](../Vendor/Framebriar/Sources/FramebriarUI/FeedbackModel.swift#L269) | Clear enrollment confirmation — upstream callback, then re-vendor. |
