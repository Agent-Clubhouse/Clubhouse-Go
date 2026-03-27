import SwiftUI

struct CreateDurableAgentSheet: View {
    let projectId: String
    let orchestrators: [String: OrchestratorEntry]
    var onCreated: ((String) -> Void)? = nil

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selectedColor: String = "indigo"
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

    private var nameValidationError: String? {
        validateAgentName(name)
    }

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && nameValidationError == nil && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Agent name (e.g. brave-falcon)", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let error = nameValidationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ColorPickerRow(selectedColor: $selectedColor)
                }

                Section("Configuration") {
                    Picker("Model", selection: $selectedModel) {
                        Text("Default").tag(String?.none)
                        ForEach(availableModels, id: \.0) { id, label in
                            Text(label).tag(Optional(id))
                        }
                    }

                    Picker("Orchestrator", selection: $selectedOrchestrator) {
                        Text("Default").tag(String?.none)
                        ForEach(Array(orchestrators.keys.sorted()), id: \.self) { key in
                            Text(orchestrators[key]?.displayName ?? key)
                                .tag(Optional(key))
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
            .navigationTitle("New Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func create() async {
        isSubmitting = true
        errorMessage = nil

        do {
            let response = try await store.createDurableAgent(
                projectId: projectId,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                color: selectedColor,
                model: selectedModel,
                orchestrator: selectedOrchestrator,
                freeAgentMode: freeAgentMode ? true : nil
            )
            Haptics.success()
            dismiss()
            onCreated?(response.id)
        } catch {
            Haptics.error()
            errorMessage = (error as? APIError)?.userMessage ?? error.localizedDescription
            isSubmitting = false
        }
    }
}

// MARK: - Color Picker Row

private struct ColorPickerRow: View {
    @Binding var selectedColor: String

    private let colors = AgentColor.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                ForEach(colors, id: \.rawValue) { agentColor in
                    Circle()
                        .fill(agentColor.color)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .strokeBorder(.white, lineWidth: selectedColor == agentColor.rawValue ? 3 : 0)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(agentColor.color, lineWidth: selectedColor == agentColor.rawValue ? 1 : 0)
                                .frame(width: 38, height: 38)
                        )
                        .onTapGesture {
                            Haptics.selection()
                            selectedColor = agentColor.rawValue
                        }
                        .accessibilityLabel(agentColor.rawValue)
                        .accessibilityAddTraits(selectedColor == agentColor.rawValue ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return CreateDurableAgentSheet(
        projectId: "proj_001",
        orchestrators: MockData.orchestrators
    )
    .environment(store)
}
