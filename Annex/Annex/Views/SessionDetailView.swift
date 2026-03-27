import SwiftUI

struct SessionDetailView: View {
    let agentId: String
    let session: SessionInfo
    @Environment(AppStore.self) private var store
    @State private var entries: [TranscriptEntry] = []
    @State private var summary: SessionSummary?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var loadMoreFailed = false
    @State private var hasMore = false
    @State private var error: String?

    private static let pageSize = 50

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading transcript...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Failed to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadInitial() } }
                }
            } else if entries.isEmpty && summary == nil {
                ContentUnavailableView {
                    Label("Empty Transcript", systemImage: "text.bubble")
                } description: {
                    Text("No transcript entries for this session.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Summary card
                        if let summary {
                            SummaryCard(summary: summary)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                        }

                        // Transcript entries
                        ForEach(entries) { entry in
                            TranscriptEntryView(entry: entry)
                                .padding(.horizontal)
                        }

                        // Load more
                        if hasMore {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                if isLoadingMore {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                } else {
                                    Text(loadMoreFailed ? "Failed to load — tap to retry" : "Load More")
                                        .font(.subheadline)
                                        .foregroundStyle(loadMoreFailed ? .red : .accentColor)
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                }
                            }
                            .disabled(isLoadingMore)
                        }
                    }
                }
            }
        }
        .navigationTitle("Session \(String(session.id.prefix(8)))")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadInitial() }
    }

    private func loadInitial() async {
        isLoading = true
        error = nil
        guard let inst = store.instance(for: agentId),
              let apiClient = inst.apiClient,
              let token = inst.token else {
            error = "Not connected"
            isLoading = false
            return
        }
        do {
            async let transcriptTask = apiClient.getTranscript(
                agentId: agentId, sessionId: session.id,
                offset: 0, limit: Self.pageSize, token: token
            )
            async let summaryTask: SessionSummary? = {
                try? await apiClient.getSessionSummary(
                    agentId: agentId, sessionId: session.id, token: token
                )
            }()

            let transcript = try await transcriptTask
            entries = transcript.entries
            hasMore = transcript.hasMore ?? false
            summary = await summaryTask
            isLoading = false
        } catch {
            self.error = (error as? APIError)?.userMessage ?? error.localizedDescription
            isLoading = false
        }
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreFailed = false
        guard let inst = store.instance(for: agentId),
              let apiClient = inst.apiClient,
              let token = inst.token else {
            loadMoreFailed = true
            isLoadingMore = false
            return
        }
        do {
            let transcript = try await apiClient.getTranscript(
                agentId: agentId, sessionId: session.id,
                offset: entries.count, limit: Self.pageSize, token: token
            )
            entries.append(contentsOf: transcript.entries)
            hasMore = transcript.hasMore ?? false
        } catch {
            loadMoreFailed = true
        }
        isLoadingMore = false
    }
}

// MARK: - Summary Card

private struct SummaryCard: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = summary.summary, !text.isEmpty {
                Text(text)
                    .font(.subheadline)
            }

            HStack(spacing: 16) {
                if let model = summary.model {
                    Label(model, systemImage: "cpu")
                }
                if let duration = summary.duration {
                    Label(formatDuration(duration), systemImage: "clock")
                }
                if let cost = summary.costUsd, cost > 0 {
                    Label(String(format: "$%.4f", cost), systemImage: "dollarsign.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let tokens = tokenSummary {
                Text(tokens)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let files = summary.filesChanged, !files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files changed")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(files.prefix(10), id: \.self) { file in
                        Text(file)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if files.count > 10 {
                        Text("+ \(files.count - 10) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }

    private var tokenSummary: String? {
        guard let input = summary.inputTokens, let output = summary.outputTokens else { return nil }
        return "\(input.formatted()) input / \(output.formatted()) output tokens"
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }
}

// MARK: - Transcript Entry View

private struct TranscriptEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            roleIcon
                .frame(width: 24)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(roleLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(roleColor)
                    if let toolName = entry.toolName {
                        Text(toolName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let ts = entry.timestamp {
                        Text(relativeTime(ts))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let content = entry.content, !content.isEmpty {
                    Text(content)
                        .font(contentFont)
                        .foregroundStyle(contentColor)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(entryBackground)
    }

    @ViewBuilder
    private var roleIcon: some View {
        switch entry.role {
        case "user":
            Image(systemName: "person.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityLabel("User message")
        case "assistant":
            Image(systemName: "brain")
                .foregroundStyle(.purple)
                .accessibilityLabel("Assistant response")
        case "tool_use":
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.orange)
                .accessibilityLabel("Tool call")
        case "tool_result":
            Image(systemName: "doc.text")
                .foregroundStyle(.green)
                .accessibilityLabel("Tool result")
        default:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Message")
        }
    }

    private var roleLabel: String {
        switch entry.role {
        case "user": return "User"
        case "assistant": return "Assistant"
        case "tool_use": return "Tool Call"
        case "tool_result": return "Tool Result"
        default: return entry.role.capitalized
        }
    }

    private var roleColor: Color {
        switch entry.role {
        case "user": return .blue
        case "assistant": return .purple
        case "tool_use": return .orange
        case "tool_result": return .green
        default: return .secondary
        }
    }

    private var contentFont: Font {
        switch entry.role {
        case "tool_use", "tool_result":
            return .caption.monospaced()
        default:
            return .subheadline
        }
    }

    private var contentColor: Color {
        switch entry.role {
        case "tool_result": return .secondary
        default: return .primary
        }
    }

    private var entryBackground: some ShapeStyle {
        switch entry.role {
        case "assistant": return AnyShapeStyle(.purple.opacity(0.04))
        case "tool_use": return AnyShapeStyle(.orange.opacity(0.04))
        default: return AnyShapeStyle(.clear)
        }
    }
}
