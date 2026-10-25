import SwiftUI

/// Task first: the sheet opens on what the agent should do, with project, desktop and options as chips under it.
struct CompanionSpawnSheet: View {
    @Bindable var store: CompanionStore
    let initialProject: CompanionProjectTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionPalette) private var palette
    @State private var project: CompanionProjectTarget?
    @State private var prompt = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var showOptions = false
    @State private var confirmReviewedSpawn = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("What should this agent accomplish?", text: $prompt, axis: .vertical)
                        .lineLimit(6...12).font(.title3).focused($promptFocused).accessibilityLabel("Agent task")
                        .padding(16)
                        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    chips
                    if showOptions {
                        VStack(spacing: 0) {
                            if let providers = selectedHost?.providers, !providers.isEmpty {
                                Picker("Provider", selection: $provider) {
                                    Text("Project default").tag("")
                                    ForEach(providers) { Text($0.name).tag($0.id) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                            } else {
                                TextField("Provider default", text: $provider).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityLabel("Provider, optional").padding(14)
                            }
                            Divider().padding(.leading, 14)
                            TextField("Model default", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel("Model, optional").padding(14)
                        }
                        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        Text("Leave these blank to use the project's configured provider and model.")
                            .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    }
                    if let host = selectedHost, !host.connection.canOperate {
                        Label("\(host.name) is \(host.connection.label.lowercased()). Reconnect before starting an agent.", systemImage: "wifi.exclamationmark")
                            .font(.subheadline).foregroundStyle(Color(palette.warning))
                    }
                    if let error = store.spawnError {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Color(palette.error))
                    }
                    if let request = store.uncertainSpawnRequest { uncertain(request) }
                    startButton
                    Text("The agent runs in this project on your desktop. You can follow its progress and steer it from the conversation.")
                        .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .companionBackground()
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }.disabled(store.spawnInProgress)
                }
            }
            .interactiveDismissDisabled(store.spawnInProgress || !prompt.isEmpty)
            .confirmationDialog("Finish reviewing the previous request?", isPresented: $confirmReviewedSpawn, titleVisibility: .visible) {
                Button("Continue with a new task") {
                    store.acknowledgeReviewedSpawn()
                    prompt = ""
                }
            } message: { Text("The earlier agent may still be running. Continue only after checking the desktop's agent list; starting a new task does not cancel it.") }
            .onAppear { project = initialProject; if store.uncertainSpawnRequest == nil { store.spawnError = nil }; promptFocused = true }
        }
        .presentationDetents([.large])
    }

    private var chips: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Run on", selection: $project) {
                    ForEach(store.hosts) { host in
                        Section(host.name) {
                            ForEach(host.projects) { item in
                                Text(item.name).tag(Optional(CompanionProjectTarget(hostID: host.id, projectID: item.id)))
                            }
                        }
                    }
                }
            } label: {
                chip(systemImage: "folder", text: selectedProjectName)
            }
            .accessibilityLabel("Run on \(selectedProjectName)")
            Button { showOptions.toggle() } label: {
                chip(systemImage: "slider.horizontal.3", text: optionsLabel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Provider and model, \(optionsLabel)")
        }
    }

    private func chip(systemImage: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color(palette.label))
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(Color(palette.fill), in: Capsule())
    }

    private var startButton: some View {
        Button {
            guard let project else { return }
            Task { if await store.spawn(project: project, prompt: prompt, provider: nonempty(provider), model: nonempty(model)) { dismiss() } }
        } label: {
            Group {
                if store.spawnInProgress { ProgressView().accessibilityLabel("Starting agent") }
                else { Text("Start agent") }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent).controlSize(.large)
        .disabled(store.spawnInProgress || store.uncertainSpawnRequest != nil || selectedHost?.connection.canOperate != true || selectedHost?.canSpawn != true || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func uncertain(_ request: CompanionSpawnRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("We couldn't confirm the agent started", systemImage: "exclamationmark.triangle").font(.headline)
                .foregroundStyle(Color(palette.warning))
            Text("Your desktop may already have started it. Check before trying again, so you don't get two.").font(.subheadline)
            Text(request.prompt).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
            HStack {
                Button("Check previous request") { Task { if await store.checkSpawnOutcome() { dismiss() } } }
                    .disabled(store.spawnInProgress)
                Button("View agents") { dismiss() }
                Button("I've checked the agents") { confirmReviewedSpawn = true }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).font(.subheadline)
        }
        .padding(16)
        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var selectedHost: CompanionHost? { store.hosts.first { $0.id == project?.hostID } }
    private var selectedProjectName: String {
        guard let host = selectedHost, let name = host.projects.first(where: { $0.id == project?.projectID })?.name else { return "Choose a project" }
        return store.hosts.count > 1 ? "\(name) · \(host.name)" : name
    }
    private var optionsLabel: String {
        let providerName = selectedHost?.providers.first { $0.id == provider }?.name ?? nonempty(provider)
        let parts = [providerName, nonempty(model)].compactMap { $0 }
        return parts.isEmpty ? "Default model" : parts.joined(separator: " · ")
    }
    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
