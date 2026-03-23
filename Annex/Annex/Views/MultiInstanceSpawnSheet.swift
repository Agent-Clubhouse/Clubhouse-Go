import SwiftUI

struct MultiInstanceSpawnSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedInstanceId: ServerInstanceID?
    @State private var selectedProjectId: String?
    @State private var prompt = ""
    @State private var selectedModel: String?
    @State private var selectedOrchestrator: String?
    @State private var freeAgentMode = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let availableModels = [
        ("claude-opus-4-6", "Opus 4.6"),
        ("claude-sonnet-4-6", "Sonnet 4.6"),
        ("claude-haiku-4-5", "Haiku 4.5"),
    ]

    private var selectedInstance: ServerInstance? {
        guard let id = selectedInstanceId else { return nil }
        return store.instanceByID(id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    if store.connectedInstances.count > 1 {
                        Picker("Instance", selection: $selectedInstanceId) {
                            Text("Select...").tag(ServerInstanceID?.none)
                            ForEach(store.connectedInstances) { inst in
                                Text(inst.serverName).tag(Optional(inst.id))
                            }
                        }
                        .onChange(of: selectedInstanceId) { _, _ in
                            selectedProjectId = nil
                        }
                    }

                    if let instance = selectedInstance {
                        Picker("Project", selection: $selectedProjectId) {
                            Text("Select...").tag(String?.none)
                            ForEach(instance.projects) { project in
                                Text(project.label).tag(Optional(project.id))
                            }
                        }
                    }
                }

                Section("Task") {
                    TextField("What should this agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Configuration") {
                    Picker("Model", selection: $selectedModel) {
                        Text("Default").tag(String?.none)
                        ForEach(availableModels, id: \.0) { id, label in
                            Text(label).tag(Optional(id))
                        }
                    }

                    if let instance = selectedInstance {
                        Picker("Orchestrator", selection: $selectedOrchestrator) {
                            Text("Default").tag(String?.none)
                            ForEach(Array(instance.orchestrators.keys.sorted()), id: \.self) { key in
                                Text(instance.orchestrators[key]?.displayName ?? key)
                                    .tag(Optional(key))
                            }
                        }
                    }

                    Toggle("Free Agent Mode", isOn: $freeAgentMode)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("New Quick Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spawn") {
                        Task { await spawn() }
                    }
                    .disabled(
                        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || selectedProjectId == nil
                        || isSubmitting
                    )
                }
            }
            .onAppear {
                // Default to first connected instance
                if selectedInstanceId == nil, let first = store.connectedInstances.first {
                    selectedInstanceId = first.id
                }
            }
        }
    }

    private func spawn() async {
        guard let projectId = selectedProjectId else { return }
        isSubmitting = true
        errorMessage = nil

        do {
            try await store.spawnQuickAgent(
                projectId: projectId,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                orchestrator: selectedOrchestrator,
                model: selectedModel,
                freeAgentMode: freeAgentMode ? true : nil
            )
            dismiss()
        } catch {
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            isSubmitting = false
        }
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return MultiInstanceSpawnSheet()
        .environment(store)
}
