import SwiftUI

struct SessionListView: View {
    let agentId: String
    @Environment(AppStore.self) private var store
    @State private var sessions: [SessionInfo] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading sessions...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("Failed to Load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await loadSessions() } }
                }
            } else if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "clock")
                } description: {
                    Text("This agent has no recorded sessions yet.")
                }
            } else {
                List(sessions) { session in
                    NavigationLink {
                        SessionDetailView(agentId: agentId, session: session)
                    } label: {
                        SessionRow(session: session)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSessions() }
    }

    private func loadSessions() async {
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
            sessions = try await apiClient.getSessions(agentId: agentId, token: token)
            isLoading = false
        } catch let apiError {
            error = apiError.userMessage
            isLoading = false
        }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusBadge
                Text(sessionTitle)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let startedAt = session.startedAt {
                    Text(relativeTime(startedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 12) {
                if let model = session.model {
                    Label(model.replacingOccurrences(of: "claude-", with: ""), systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let count = session.messageCount, count > 0 {
                    Label("\(count) messages", systemImage: "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let cost = session.costUsd, cost > 0 {
                    Text(String(format: "$%.4f", cost))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let duration = formattedDuration {
                Text(duration)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var sessionTitle: String {
        let prefix = String(session.id.prefix(8))
        return "Session \(prefix)"
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (color, icon) = statusInfo
        Image(systemName: icon)
            .font(.caption2)
            .foregroundStyle(color)
    }

    private var statusInfo: (Color, String) {
        switch session.status {
        case .active: return (.green, "circle.fill")
        case .completed: return (.secondary, "checkmark.circle.fill")
        case .error: return (.red, "exclamationmark.circle.fill")
        case nil: return (.secondary, "circle")
        }
    }

    private var formattedDuration: String? {
        guard let start = session.startedAt, let end = session.endedAt else { return nil }
        let seconds = (end - start) / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }
}
