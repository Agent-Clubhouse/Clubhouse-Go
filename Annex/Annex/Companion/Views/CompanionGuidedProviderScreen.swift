import SwiftUI
import ClubhouseTransport

struct CompanionGuidedProviderScreen: View {
    let store: CompanionStore
    let target: CompanionTarget
    let settings: CompanionAgentSettings
    @State private var flow: CompanionProviderFlow?

    var body: some View {
        Group {
            if let flow, flow.target == target {
                CompanionGuidedProviderForm(store: store, target: target, settings: settings, flow: flow).id(target)
            }
            else { ProgressView() }
        }
        .navigationTitle("Provider")
        .task(id: target) { flow = store.providerFlow(for: target) }
    }
}

private struct CompanionGuidedProviderForm: View {
    let store: CompanionStore
    let target: CompanionTarget
    let settings: CompanionAgentSettings
    @Bindable var flow: CompanionProviderFlow
    @State private var confirmStart = false

    var body: some View {
        ScrollViewReader { proxy in form(proxy: proxy) }
    }

    private func form(proxy: ScrollViewProxy) -> some View {
        Form {
            Section {
                LabeledContent("Agent", value: store.agent(for: target)?.name ?? settings.name.value)
                LabeledContent("Desktop", value: store.host(for: target)?.name ?? "Desktop")
                LabeledContent("Last reported agent state", value: reportedState)
                    .accessibilityIdentifier("provider-reported-state")
                LabeledContent("Requested runtime (last reported)", value: settings.runtime.value == "default" ? "Provider default" : settings.runtime.value.capitalized)
                LabeledContent("Session provider", value: "Not verified here")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("provider-session-unverified")
                LabeledContent("Last loaded saved model", value: savedModelSummary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("provider-saved-model")
                LabeledContent("Saved effort", value: "Not reported by this host")
                LabeledContent("Last reported session model", value: reportedSessionModel)
                LabeledContent("Last reported session effort", value: reportedSessionEffort)
                Text("Choosing checks a proposal. Apply saves it on the desktop. Starting a session is separate.")
                if store.agent(for: target)?.isSleepingOnDesktop != true || store.sleepRequests.contains(target) {
                    Text("Sleep the agent before choosing and applying a provider.")
                    CompanionSleepControl(store: store, target: target)
                    if let error = store.operationErrors[target] { Text(error).foregroundStyle(.red) }
                }
            }
            Section("Proposed change") {
                LabeledContent("Last reported saved provider", value: name(flow.reportedSavedProvider ?? settings.resolvedOrchestrator))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("provider-saved-value")
                LabeledContent("Proposed provider", value: flow.selectedProvider.map(name) ?? "Choose below")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("provider-proposed-value")
                if let saved = flow.savedProvider {
                    Text("Last Apply receipt: \(name(saved)) saved on the desktop. No session was started by Apply.")
                        .accessibilityIdentifier("provider-saved")
                    if let reported = flow.preview?.outcome.savedProvider, reported != saved {
                        Text("The desktop now reports \(name(reported)) saved. Choose a provider again to review a new change.")
                            .accessibilityIdentifier("provider-saved-changed")
                    }
                    Button("Start new session") {
                        guard preservesRequestedRuntime else { return }
                        CompanionUIActions.record(.startNewSession, on: .providerSettings)
                        confirmStart = true
                    }
                    .disabled(!flow.canStart || !preservesRequestedRuntime)
                    .accessibilityIdentifier("provider-start-new")
                    Text("Start requires a fresh matching desktop check and a separate confirmation.")
                }
            }
            .id("provider-review")
            Section("Choose a provider") {
                ForEach(settings.options.orchestrators, id: \.id) { provider in
                    Button {
                        CompanionUIActions.record(.selectProvider, on: .providerSettings)
                        Task { await flow.select(provider.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(provider.displayName)
                                Spacer()
                                if flow.selectedProvider == provider.id { Image(systemName: "checkmark") }
                            }
                            if !provider.available {
                                Text(provider.unavailableReason ?? "Unavailable on this desktop").font(.caption)
                            }
                        }
                    }
                    .disabled(!provider.available || !flow.canChoose)
                    .accessibilityIdentifier("provider-choice-\(provider.id)")
                    .accessibilityAddTraits(flow.selectedProvider == provider.id ? .isSelected : [])
                }
            }
            if flow.busy { Section { ProgressView("Checking with desktop…") } }
            if let error = flow.error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("provider-flow-error") }
            }
            if flow.blocksMutations {
                Section {
                    Text("This action is not confirmed yet. Other changes stay locked until its result is known.")
                    Button("Check previous result") {
                            CompanionUIActions.record(.checkProviderResult, on: .providerSettings)
                            Task { await flow.checkPreviousResult() }
                        }
                        .disabled(flow.busy || store.host(for: target)?.connection.canOperate != true)
                        .accessibilityIdentifier("provider-check-result")
                }
            } else {
                if let preview = flow.preview { previewSection(preview.outcome) }
                if flow.selectedProvider != nil && !flow.startRequested {
                    Section {
                        Button("Refresh preview") {
                            CompanionUIActions.record(.refresh, on: .providerSettings)
                            Task { await flow.refresh() }
                        }
                            .disabled(!flow.canChoose)
                            .accessibilityIdentifier("provider-refresh")
                    }
                }
            }
            if flow.startRequested {
                Section { Text("Start requested. The running provider and session are not verified here. Return to the agent to check its reported session.").accessibilityIdentifier("provider-start-requested") }
            }
            Section {
                Text("Resume is unavailable in this flow, including when keeping the same provider. Starting new creates a fresh native session.")
                Text("CLI availability only checks this desktop's local installation. Sign-in, configuration and remaining quota are not verified.")
            }
        }
        .safeAreaInset(edge: .bottom) { applyBar(proxy: proxy) }
        .accessibilityIdentifier("provider-flow")
        .companionTelemetryScreen(.providerSettings)
        .confirmationDialog("Start a new session?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start new session") {
                guard preservesRequestedRuntime else { return }
                CompanionUIActions.record(.confirm, on: .providerSettings)
                Task { await flow.startNew() }
            }
            Button("Cancel", role: .cancel) { CompanionUIActions.record(.cancel, on: .providerSettings) }
        } message: {
            Text("Start \(store.agent(for: target)?.name ?? "this agent") with \(name(flow.savedProvider ?? "")) on \(store.host(for: target)?.name ?? "the desktop")? This can use provider quota. Previous native context is not transferred.")
        }
    }

    private func applyBar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Review change") { proxy.scrollTo("provider-review", anchor: .top) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("provider-review-change")
                Button("Apply provider") {
                    guard preservesRequestedRuntime else { return }
                    CompanionUIActions.record(.saveProvider, on: .providerSettings)
                    Task { await flow.save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!flow.canSave || !preservesRequestedRuntime)
                .accessibilityIdentifier("provider-save")
                .accessibilityHint(applyReason)
            }
            Text(applyReason).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("provider-apply-reason")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial)
    }

    private var savedModelSummary: String {
        if settings.notHonored.contains("model") { return "Not used by this agent" }
        if flow.appliedSettingsReset.contains("model") { return "Reset by Apply; new value not reported" }
        if let reported = flow.reportedSavedProvider, reported != settings.resolvedOrchestrator {
            return "Read for the previous provider; reload Agent settings"
        }
        return settings.model.value == "default" ? "Provider default (saved setting)" : settings.modelLabel
    }
    private var reportedSessionModel: String {
        guard store.agent(for: target)?.isSleepingOnDesktop == false else { return "Not reported for an awake session" }
        return store.agent(for: target)?.chatControls?.model ?? "Not reported"
    }
    private var reportedSessionEffort: String {
        guard let agent = store.agent(for: target), agent.isSleepingOnDesktop == false else { return "Not reported for an awake session" }
        if agent.chatControls?.effortReported == true { return agent.chatControls?.effortLabel ?? "Not reported" }
        return agent.session?.effort ?? "Not reported"
    }

    /// Catalog lifecycle is a last report, including while disconnected. A preview's
    /// target runtime and an Apply receipt never establish the running session.
    private var reportedState: String {
        guard let sleeping = store.agent(for: target)?.isSleepingOnDesktop else { return "Not reported" }
        return sleeping ? "Sleeping" : "Awake"
    }

    private var applyReason: String {
        guard store.host(for: target)?.connection.canOperate == true else {
            return "Reconnect to the desktop, then refresh the proposal. Saved values and agent state above are last reported."
        }
        guard store.host(for: target)?.canControlProvider == true else { return "This desktop does not offer provider Apply for this agent." }
        guard store.agent(for: target)?.isSleepingOnDesktop == true, !store.sleepRequests.contains(target) else {
            return "Wait for the desktop to confirm the agent is asleep before applying a provider."
        }
        if flow.blocksMutations { return "The previous action is not confirmed. Check its result before applying another change." }
        if flow.busy { return "Checking with desktop…" }
        if flow.startRequested { return "Start was requested separately. Check the agent for its reported session." }
        if flow.savedProvider != nil { return "Apply was confirmed by the desktop. Starting remains a separate action; choose again to propose another change." }
        guard flow.selectedProvider != nil else { return "Choose a provider below. Nothing is saved or started by choosing." }
        guard let outcome = flow.preview?.outcome else { return "Refresh the proposal before applying. No change is confirmed by a preview." }
        guard preservesRequestedRuntime else {
            return "This proposal does not preserve the requested runtime. This transition is unsupported; review it on the desktop. Apply will not change the runtime for you."
        }
        guard outcome.permitsSave else { return CompanionProviderReason.message(outcome.blocked) }
        guard flow.canSave else { return "Another agent action must finish before Apply is available." }
        return "Apply saves this provider for the next start. It does not wake the agent."
    }

    private var preservesRequestedRuntime: Bool {
        guard let preview = flow.preview else { return true }
        return settings.runtime.value == "default" || settings.runtime.value == preview.outcome.targetRuntime.rawValue
    }

    @ViewBuilder private func previewSection(_ value: AnnexProviderOutcome) -> some View {
        Section("Preview") {
            LabeledContent("Proposed provider", value: name(value.provider))
            LabeledContent("Previewed agent state", value: value.state.rawValue.capitalized)
            LabeledContent("Next-start runtime", value: value.targetRuntime == .chat ? "Chat" : "Terminal")
            Text(value.available ? "CLI found on this desktop." : "CLI unavailable on this desktop.")
            Text(instructionSummary(value.instructions))
            Text("Only native primary instruction files were compared. This preview does not prepare or load skills or MCP setup; their delivery and nested instructions are not verified.")
                .font(.caption)
            if value.historyRetained { Text("Recorded history is retained. Native conversation context is not transferred.") }
            else { Text("The desktop has not confirmed history retention.") }
            if !value.settingsReset.isEmpty {
                Text("Applying resets: \(value.settingsReset.map(resetName).joined(separator: ", ")).")
            }
            if !value.permitsSave {
                Text(CompanionProviderReason.message(value.blocked)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("provider-blocked")
            }
        }
    }
    private func name(_ id: String) -> String { settings.options.orchestrators.first { $0.id == id }?.displayName ?? id }
    private func instructionSummary(_ value: AnnexProviderOutcome.Instructions) -> String {
        switch value {
        case .equivalent: "Native primary instruction files match."
        case .different: "Native primary instruction files differ."
        case .unverified: "Native primary instruction files could not be verified."
        }
    }
    private func resetName(_ value: String) -> String {
        switch value {
        case "model": "model"
        case "effort": "effort"
        case "contextWindow": "context window"
        case "routing": "provider routing"
        case "resumePointer": "resume selection"
        default: "other provider settings"
        }
    }
}
