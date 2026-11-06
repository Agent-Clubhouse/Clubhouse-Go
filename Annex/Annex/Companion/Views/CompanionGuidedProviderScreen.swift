import SwiftUI
import ClubhouseTransport

struct CompanionGuidedProviderScreen: View {
    let store: CompanionStore
    let target: CompanionTarget
    let settings: CompanionAgentSettings
    @State private var flow: CompanionProviderFlow?

    var body: some View {
        Group {
            if let flow { CompanionGuidedProviderForm(store: store, target: target, settings: settings, flow: flow) }
            else { ProgressView() }
        }
        .navigationTitle("Provider")
        .task { flow = store.providerFlow(for: target) }
    }
}

private struct CompanionGuidedProviderForm: View {
    let store: CompanionStore
    let target: CompanionTarget
    let settings: CompanionAgentSettings
    @Bindable var flow: CompanionProviderFlow
    @State private var confirmStart = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Agent", value: store.agent(for: target)?.name ?? settings.name.value)
                LabeledContent("Desktop", value: store.host(for: target)?.name ?? "Desktop")
                LabeledContent("Saved provider", value: name(flow.savedProvider ?? flow.preview?.outcome.savedProvider ?? settings.resolvedOrchestrator))
                if store.agent(for: target)?.isSleepingOnDesktop != true || store.sleepRequests.contains(target) {
                    Text("Sleep the agent before choosing and saving a provider.")
                    CompanionSleepControl(store: store, target: target)
                    if let error = store.operationErrors[target] { Text(error).foregroundStyle(.red) }
                }
            }
            Section("Choose a provider") {
                ForEach(settings.options.orchestrators, id: \.id) { provider in
                    Button {
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
                }
            }
            if flow.busy { Section { ProgressView("Checking with desktop…") } }
            if let error = flow.error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("provider-flow-error") }
            }
            if flow.blocksMutations {
                Section {
                    Text("This action is not confirmed yet. Other changes stay locked until its result is known.")
                    Button("Check previous result") { Task { await flow.checkPreviousResult() } }
                        .disabled(flow.busy || store.host(for: target)?.connection.canOperate != true)
                        .accessibilityIdentifier("provider-check-result")
                }
            } else {
                if let preview = flow.preview { previewSection(preview.outcome) }
                if flow.selectedProvider != nil && !flow.startRequested {
                    Section {
                        Button("Refresh preview") { Task { await flow.refresh() } }
                            .disabled(!flow.canChoose)
                            .accessibilityIdentifier("provider-refresh")
                        if flow.savedProvider == nil {
                            Button("Save provider") { Task { await flow.save() } }
                                .disabled(!flow.canSave)
                                .accessibilityIdentifier("provider-save")
                        } else {
                            Text("Provider saved. Starting is a separate action.")
                                .accessibilityIdentifier("provider-saved")
                            Button("Start new session") { confirmStart = true }
                                .disabled(!flow.canStart)
                                .accessibilityIdentifier("provider-start-new")
                        }
                    }
                }
            }
            if flow.startRequested {
                Section { Text("Start requested. Return to the agent to see its session.").accessibilityIdentifier("provider-start-requested") }
            }
            Section {
                Text("Resume is unavailable in this flow, including when keeping the same provider. Starting new creates a fresh native session.")
                Text("CLI availability only checks this desktop's local installation. Sign-in, configuration and remaining quota are not verified.")
            }
        }
        .accessibilityIdentifier("provider-flow")
        .confirmationDialog("Start a new session?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start new session") { Task { await flow.startNew() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Start \(store.agent(for: target)?.name ?? "this agent") with \(name(flow.savedProvider ?? "")) on \(store.host(for: target)?.name ?? "the desktop")? This can use provider quota. Previous native context is not transferred.")
        }
    }

    @ViewBuilder private func previewSection(_ value: AnnexProviderOutcome) -> some View {
        Section("Preview") {
            LabeledContent("Selected provider", value: name(value.provider))
            LabeledContent("Agent state", value: value.state.rawValue.capitalized)
            LabeledContent("Runtime", value: value.targetRuntime == .chat ? "Chat" : "Terminal")
            Text(value.available ? "CLI found on this desktop." : "CLI unavailable on this desktop.")
            Text(instructionSummary(value.instructions))
            Text("Only native primary instruction files were compared. Skills, nested instructions and the full MCP setup are not verified.")
                .font(.caption)
            if value.historyRetained { Text("Recorded history is retained. Native conversation context is not transferred.") }
            else { Text("The desktop has not confirmed history retention.") }
            if !value.settingsReset.isEmpty {
                Text("Saving resets: \(value.settingsReset.map(resetName).joined(separator: ", ")).")
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
