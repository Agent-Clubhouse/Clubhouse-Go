import SwiftUI

struct SpawnQuickAgentSheet: View {
    let projectId: String
    let parentAgentId: String?
    let orchestrators: [String: OrchestratorEntry]

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var selectedModel: String?
    @State private var selectedOrchestrator: String?
    @State private var freeAgentMode = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private let availableModels = [
        ("claude-opus-4-6", "Opus 4.6"),
        ("claude-sonnet-4-6", "Sonnet 4.6"),
        ("claude-haiku-4-5", "Haiku"),
    ]

    var body: some View {
        NavigationStack {
            Form {
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

                    if parentAgentId == nil {
                        Picker("Orchestrator", selection: $selectedOrchestrator) {
                            Text("Default").tag(String?.none)
                            ForEach(Array(orchestrators.keys.sorted()), id: \.self) { key in
                                Text(orchestrators[key]?.displayName ?? key)
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
            .navigationTitle("Quick Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Spawn") {
                        Task { await spawn() }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
        }
    }

    private func spawn() async {
        isSubmitting = true
        errorMessage = nil

        do {
            if let parentAgentId {
                try await store.spawnQuickAgentUnder(
                    parentAgentId: parentAgentId,
                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: selectedModel,
                    freeAgentMode: freeAgentMode ? true : nil
                )
            } else {
                try await store.spawnQuickAgent(
                    projectId: projectId,
                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    orchestrator: selectedOrchestrator,
                    model: selectedModel,
                    freeAgentMode: freeAgentMode ? true : nil
                )
            }
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
    return SpawnQuickAgentSheet(
        projectId: "proj_001",
        parentAgentId: nil,
        orchestrators: MockData.orchestrators
    )
    .environment(store)
}
