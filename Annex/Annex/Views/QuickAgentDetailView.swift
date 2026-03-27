import SwiftUI

struct QuickAgentDetailView: View {
    let agent: QuickAgent
    @Environment(AppStore.self) private var store
    @State private var isCancelling = false
    @State private var cancelError: String?
    @State private var showDeleteConfirmation = false
    @State private var deleteError: String?

    private var statusLabel: String {
        switch agent.status {
        case .starting: return "Starting"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .sleeping: return "Sleeping"
        case .error: return "Error"
        case nil: return "Unknown"
        }
    }

    private var statusColor: Color {
        switch agent.status {
        case .running, .starting: return .green
        case .completed: return .blue
        case .failed, .error: return .red
        case .cancelled: return .orange
        case .sleeping: return .secondary
        case nil: return .secondary
        }
    }

    var body: some View {
        List {
            // Status section
            Section("Status") {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .font(.subheadline)
                }

                if let model = agent.model {
                    let label = model.contains("opus") ? "Opus"
                        : model.contains("sonnet") ? "Sonnet"
                        : model.contains("haiku") ? "Haiku" : model
                    HStack {
                        Text("Model")
                            .foregroundStyle(.secondary)
                        Spacer()
                        let c = ModelColors.colors(for: model)
                        ChipView(text: label, bg: c.bg, fg: c.fg)
                    }
                }

                if agent.freeAgentMode == true {
                    HStack {
                        Text("Mode")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ChipView(text: "Free", bg: .red.opacity(0.15), fg: .red)
                    }
                }
            }

            // Prompt
            if let prompt = agent.prompt ?? agent.mission {
                Section("Prompt") {
                    Text(prompt)
                        .font(.subheadline)
                }
            }

            // Completion summary
            if let summary = agent.summary {
                Section("Summary") {
                    Text(summary)
                        .font(.subheadline)
                }
            }

            // Completion details
            if agent.status == .completed || agent.status == .failed {
                Section("Details") {
                    if let duration = agent.durationMs {
                        HStack {
                            Text("Duration")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatDuration(duration))
                        }
                    }

                    if let cost = agent.costUsd {
                        HStack {
                            Text("Cost")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "$%.2f", cost))
                        }
                    }

                    if let tools = agent.toolsUsed, !tools.isEmpty {
                        HStack(alignment: .top) {
                            Text("Tools")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(tools.joined(separator: ", "))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                if let files = agent.filesModified, !files.isEmpty {
                    Section("Files Modified") {
                        ForEach(files, id: \.self) { file in
                            Text(file)
                                .font(.caption)
                                .fontDesign(.monospaced)
                        }
                    }
                }
            }

            // Cancel button for running agents
            if agent.status == .running || agent.status == .starting {
                Section {
                    Button(role: .destructive) {
                        Task { await cancelAgent() }
                    } label: {
                        HStack {
                            Spacer()
                            if isCancelling {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Cancel Agent")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isCancelling)
                }
            }

            if let cancelError {
                Section {
                    Text(cancelError)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(store.theme.baseColor)
        .navigationTitle(agent.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if agent.status == .completed || agent.status == .failed || agent.status == .cancelled {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    Button(role: .destructive) {
                        store.removeQuickAgent(agentId: agent.id)
                    } label: {
                        Label("Remove from List", systemImage: "eye.slash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete Quick Agent?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await store.deleteAgent(agentId: agent.id)
                    } catch {
                        deleteError = (error as? APIError)?.userMessage ?? error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This will permanently remove this quick agent and its data.")
        }
        .alert("Delete Failed", isPresented: .init(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func cancelAgent() async {
        isCancelling = true
        cancelError = nil
        do {
            try await store.cancelQuickAgent(agentId: agent.id)
        } catch {
            cancelError = (error as? APIError)?.userMessage ?? error.localizedDescription
        }
        isCancelling = false
    }

    private func formatDuration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes)m \(remainder)s"
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    let agent = QuickAgent(
        id: "quick_001",
        name: "quick-agent-1",
        kind: "quick",
        status: .completed,
        mission: "Fix the login bug",
        prompt: "Fix the login bug in src/auth/login.ts",
        model: "claude-sonnet-4-5",
        detailedStatus: nil,
        orchestrator: "claude-code",
        parentAgentId: nil,
        projectId: "proj_001",
        freeAgentMode: false,
        summary: "Fixed the login bug by correcting the token validation logic in src/auth/login.ts.",
        filesModified: ["src/auth/login.ts", "src/auth/__tests__/login.test.ts"],
        durationMs: 45200,
        costUsd: 0.12,
        toolsUsed: ["Read", "Edit", "Bash"]
    )
    return NavigationStack {
        QuickAgentDetailView(agent: agent)
    }
    .environment(store)
}
