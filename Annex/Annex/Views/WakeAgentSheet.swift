import SwiftUI

struct WakeAgentSheet: View {
    let agent: DurableAgent

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var selectedModel: String?
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
                Section("Message") {
                    TextField("What should \(agent.name ?? "the agent") do?", text: $message, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("Configuration") {
                    Picker("Model", selection: $selectedModel) {
                        if let current = agent.model {
                            let label = current.contains("opus") ? "Opus"
                                : current.contains("sonnet") ? "Sonnet"
                                : current.contains("haiku") ? "Haiku" : current
                            Text("\(label) (default)").tag(String?.none)
                        } else {
                            Text("Default").tag(String?.none)
                        }
                        ForEach(availableModels, id: \.0) { id, label in
                            Text(label).tag(Optional(id))
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Wake Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Wake") {
                        Task { await wake() }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
        }
    }

    private func wake() async {
        isSubmitting = true
        errorMessage = nil

        do {
            try await store.wakeAgent(
                agentId: agent.id,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines),
                model: selectedModel
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
    return WakeAgentSheet(agent: MockData.agents["proj_001"]![1])
        .environment(store)
}
