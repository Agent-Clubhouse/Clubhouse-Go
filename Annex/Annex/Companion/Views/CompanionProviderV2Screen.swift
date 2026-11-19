import SwiftUI
import ClubhouseTransport

struct CompanionProviderV2Screen: View {
    let store: CompanionStore
    let target: CompanionTarget
    let settings: CompanionAgentSettings
    @State private var flow: CompanionProviderV2Flow?

    var body: some View {
        Group {
            if let flow, flow.target == target {
                CompanionProviderV2Form(store: store, target: target, settings: settings, flow: flow)
            } else { ProgressView() }
        }
        .task(id: target) { flow = store.providerV2Flow(for: target, requestedRuntime: settings.runtime.value) }
    }
}

private struct CompanionProviderV2Form: View {
    let store: CompanionStore
    let target: CompanionTarget
    let settings: CompanionAgentSettings
    @Bindable var flow: CompanionProviderV2Flow
    @State private var confirmStart = false

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    LabeledContent("Agent", value: store.agent(for: target)?.name ?? settings.name.value)
                    LabeledContent("Desktop", value: store.host(for: target)?.name ?? "Desktop")
                    LabeledContent("Last reported agent state", value: reportedState)
                    LabeledContent("Requested runtime (last loaded)", value: settings.runtime.value)
                    LabeledContent("Current session", value: "Not verified by this screen")
                        .accessibilityIdentifier("provider-session-unverified")
                    LabeledContent("Last loaded saved model", value: settings.model.value == "default" ? "Provider default (saved setting)" : settings.modelLabel)
                    Text("Saved effort is not available until a host preview reports it.")
                    Text("Choosing previews a provider. Apply saves the reviewed next-start settings. Start is separate and requires desktop support and your confirmation.")
                    if store.agent(for: target)?.isSleepingOnDesktop != true || store.sleepRequests.contains(target) {
                        CompanionSleepControl(store: store, target: target)
                    }
                }
                Section("Review change") {
                    if let saved = flow.reportedSaved { nextWake(saved, title: "Last reported saved settings", prefix: "provider-v2-saved") }
                    else { Text("Saved model and effort have not been reported by this flow yet.") }
                    LabeledContent("Proposed provider", value: flow.selectedProvider.map(name) ?? "Choose below")
                        .accessibilityIdentifier("provider-proposed-value")
                    if let value = flow.preview?.value {
                        nextWake(value.contract.proposed, title: "Previewed next start", prefix: "provider-v2-proposed")
                        if !value.preview.outcome.settingsReset.isEmpty {
                            Text("Applying resets: \(value.preview.outcome.settingsReset.joined(separator: ", ")).")
                                .accessibilityIdentifier("provider-reset-impacts")
                        }
                        Text("This provider-only choice sends no model or effort selection. The saved and proposed values above show the desktop's defaults and retained settings.")
                        Text("Native context is not transferred. Recorded history: \(value.preview.outcome.historyRetained ? "retained" : "not confirmed").")
                        if value.preview.outcome.instructionScope == "managed_composition" {
                            Text("Managed preparation is unloaded. Native instructions are prepared on Apply; skills are unsupported and MCP uses launch flags. Start rechecks preparation. This is not proof of a running provider.")
                        } else {
                            Text("Native primary instruction equivalence only. Skills, nested instructions and MCP delivery are not verified by that comparison.")
                        }
                    }
                    if let receipt = flow.lastApply {
                        Text("Apply reported saving \(name(receipt.value.contract.saved.provider)) (historical). It started no session. Current runtime unverified.")
                            .accessibilityIdentifier("provider-saved")
                        nextWake(receipt.value.contract.saved, title: "Saved in that receipt", prefix: "provider-v2-receipt")
                        Button("Start new session") { confirmStart = true }
                            .disabled(!flow.canStart)
                            .accessibilityIdentifier("provider-start-new")
                        Text(startReason)
                            .accessibilityIdentifier("provider-start-reason")
                    }
                    if let conflict = flow.conflict {
                        Text("Acknowledged conflicting write: the requested selection was not saved. No Start is authorized.")
                        if let actual = conflict.saved { nextWake(actual, title: "Host-reported differing saved settings", prefix: "provider-v2-conflict") }
                        else { Text("The effective saved provider is unknown. Raw override evidence is not an effective provider selection.") }
                    }
                }
                .id("provider-v2-review")
                if let start = flow.lastStart {
                    Section("Historical Start evidence") {
                        Text(start.start.wasObserved ? "The host observed PTY creation with \(name(start.start.providerSelection ?? "unknown")). This is not a provider handshake." : "Runtime creation is unknown.")
                            .accessibilityIdentifier("provider-v2-start-creation")
                        LabeledContent("Command outcome", value: start.result.status)
                        LabeledContent("Observed at", value: start.start.observedAt ?? "Not reported")
                        LabeledContent("Running at that command", value: start.running.state)
                        LabeledContent("App session ID", value: start.running.appSessionId ?? "Not reported")
                        LabeledContent("Native provider session ID", value: start.running.nativeProviderSessionId ?? "Not reported")
                        Text("Current running provider, model and effort remain unverified. The observation above is historical.")
                    }
                    .accessibilityIdentifier("provider-v2-start-evidence")
                }
                Section("Choose a provider") {
                    ForEach(settings.options.orchestrators, id: \.id) { provider in
                        Button { Task { await flow.select(provider.id) } } label: {
                            VStack(alignment: .leading) {
                                Text(provider.displayName)
                                if !provider.available { Text(provider.unavailableReason ?? "Unavailable on this desktop").font(.caption) }
                            }
                        }
                        .disabled(!provider.available || !flow.canChoose)
                        .accessibilityIdentifier("provider-choice-\(provider.id)")
                        .accessibilityAddTraits(flow.selectedProvider == provider.id ? .isSelected : [])
                    }
                }
                if flow.busy { Section { ProgressView("Checking with desktop…") } }
                if let error = flow.error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("provider-flow-error") } }
                if flow.blocksMutations {
                    Section {
                        Text("This action is unresolved or requires desktop review. Apply and Start stay locked across reopen and reconnect. Equal freshly read settings cannot prove the old command's outcome.")
                        Button("Review held result") { flow.reviewHeldResult() }
                            .accessibilityIdentifier("provider-review-held-result")
                        Text("Reviewing held evidence sends no command. Check the desktop for an unconfirmed action; this phone will not send it again.")
                    }
                }
                if flow.selectedProvider != nil {
                    Section {
                        Button("Refresh reported settings") { Task { await flow.refresh() } }
                            .disabled(flow.busy || store.host(for: target)?.connection.canOperate != true)
                            .accessibilityIdentifier("provider-refresh")
                        Text("Read-only. This cannot confirm an unresolved Apply or Start.")
                    }
                }
                Section { Text("Resume is unavailable here. The requested runtime is kept. If the desktop cannot preserve it, this change is unavailable. Provider sign-in and quota are not verified here.") }
            }
            .accessibilityIdentifier("provider-flow")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Review change") { proxy.scrollTo("provider-v2-review", anchor: .top) }
                            .buttonStyle(.bordered).accessibilityIdentifier("provider-review-change")
                        Button("Apply provider") { Task { await flow.apply() } }
                            .buttonStyle(.borderedProminent).disabled(!flow.canApply)
                            .accessibilityIdentifier("provider-save").accessibilityHint(applyReason)
                    }
                    Text(applyReason).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("provider-apply-reason")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.regularMaterial)
            }
        }
        .confirmationDialog("Start a new session?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start new session") { Task { await flow.startNew() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Start \(store.agent(for: target)?.name ?? "this agent") on \(store.host(for: target)?.name ?? "the desktop") using the held Apply receipt? The host must revalidate the full next-start settings. This can use provider quota; previous native context is not transferred.")
        }
    }
    @ViewBuilder private func nextWake(_ value: AnnexProviderNextWakeV2, title: String, prefix: String) -> some View {
        Text(title).font(.headline)
        LabeledContent("Provider", value: name(value.provider))
            .accessibilityElement(children: .combine).accessibilityIdentifier(prefix + "-provider")
        LabeledContent("Provider override", value: value.providerOverride ?? "Inherited desktop default")
            .accessibilityElement(children: .combine).accessibilityIdentifier(prefix + "-override")
        LabeledContent("Model", value: setting(value.model))
            .accessibilityElement(children: .combine).accessibilityIdentifier(prefix + "-model")
        LabeledContent("Effort", value: setting(value.effort))
            .accessibilityElement(children: .combine).accessibilityIdentifier(prefix + "-effort")
    }
    private func setting(_ value: AnnexProviderNextWakeV2.Value) -> String {
        value.source == .providerDefault ? "Provider default (host reported)" : "\(value.value ?? "Unknown") (saved agent override)"
    }
    private func name(_ value: String) -> String { settings.options.orchestrators.first { $0.id == value }?.displayName ?? value }
    private var reportedState: String {
        guard let sleeping = store.agent(for: target)?.isSleepingOnDesktop else { return "Unknown" }
        return sleeping ? "Sleeping" : "Awake"
    }
    private var startReason: String {
        if flow.blocksMutations { return "The previous action remains unresolved. No additional Start will be sent." }
        guard store.host(for: target)?.providerStartV2?.isSupported == true else { return "This desktop does not separately support this checked Start action." }
        guard flow.lastApply?.value.nextWake?.readyToken != nil else { return "The Apply receipt does not authorize Start. Review the desktop's blocked or unverified next-wake state." }
        return "The desktop must freshly confirm the saved settings still match this Apply receipt. Your separate confirmation is required. Creation evidence is not a provider handshake."
    }
    private var applyReason: String {
        guard store.host(for: target)?.connection.canOperate == true else { return "Reconnect before reading a fresh proposal. All shown settings and state are last reported." }
        guard store.host(for: target)?.providerApplyV2?.isSupported == true else { return "This desktop reported provider controls this phone cannot safely use. Update the desktop before Apply." }
        if flow.blocksMutations { return "The previous operation requires desktop review. Apply and Start remain locked." }
        if flow.busy { return "Checking with desktop…" }
        guard store.agent(for: target)?.isSleepingOnDesktop == true else { return "Sleep the agent and wait for desktop confirmation." }
        guard flow.selectedProvider != nil else { return "Choose a provider. Selection only previews; Apply does not start it." }
        if flow.lastApply != nil && flow.preview == nil { return "A historical Apply receipt is shown. Start remains separate; choose again to review another proposal." }
        guard let preview = flow.preview else { return "Refresh and review the proposal before Apply." }
        guard flow.preservesRuntime else { return "The proposed runtime differs from the requested runtime. Unsupported; no runtime swap will be made." }
        guard preview.value.permitsApply(capability: preview.capability) else { return CompanionProviderReason.message(preview.value.preview.outcome.blocked) }
        return flow.canApply ? "Apply saves the displayed provider, model, effort and reset impacts for the next start. It starts no session." : "Another operation or a changed host state prevents Apply. Refresh before continuing."
    }
}
