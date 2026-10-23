import SwiftUI

struct CompanionSpawnSheet: View {
    @Bindable var store: CompanionStore
    let initialProject: CompanionProjectTarget
    @Environment(\.dismiss) private var dismiss
    @State private var project: CompanionProjectTarget?
    @State private var prompt = ""
    @State private var provider = ""
    @State private var model = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Run on", selection: $project) {
                        ForEach(store.hosts) { host in
                            ForEach(host.projects) { item in
                                Text("\(host.name) / \(item.name)")
                                    .tag(Optional(CompanionProjectTarget(hostID: host.id, projectID: item.id)))
                            }
                        }
                    }
                    if let host = selectedHost, !host.connection.canOperate {
                        Label("\(host.name) is \(host.connection.label.lowercased()). Reconnect before starting an agent.", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: { Text("Desktop and project") }
                Section {
                    TextField("What should this agent accomplish?", text: $prompt, axis: .vertical)
                        .lineLimit(6...12).focused($promptFocused).accessibilityLabel("Agent task")
                } header: { Text("Task") } footer: {
                    Text("The agent runs in this project on your desktop. You can follow its progress and steer it from the conversation.")
                }
                Section {
                    TextField("Provider default", text: $provider).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Provider, optional")
                    TextField("Model default", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Model, optional")
                } header: { Text("Options") } footer: { Text("Leave these blank to use the project's configured provider and model.") }
                if let error = store.spawnError {
                    Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.spawnInProgress) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let project else { return }
                        Task {
                            if await store.spawn(project: project, prompt: prompt, provider: nonempty(provider), model: nonempty(model)) { dismiss() }
                        }
                    } label: {
                        if store.spawnInProgress { ProgressView().accessibilityLabel("Starting agent") }
                        else { Text("Start agent") }
                    }
                    .disabled(store.spawnInProgress || selectedHost?.connection.canOperate != true || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .interactiveDismissDisabled(store.spawnInProgress || !prompt.isEmpty)
            .onAppear { project = initialProject; store.spawnError = nil; promptFocused = true }
        }
        .presentationDetents([.large])
    }
    private var selectedHost: CompanionHost? { store.hosts.first { $0.id == project?.hostID } }
    private func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
