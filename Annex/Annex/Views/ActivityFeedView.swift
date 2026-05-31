import SwiftUI

// MARK: - Activity Filter

/// Filter categories for the activity feed. Kept `internal` intentionally for test access.
enum ActivityFilter: String, CaseIterable {
    case all = "All"
    case tools = "Tools"
    case errors = "Errors"
    case permissions = "Permissions"

    func matches(_ event: HookEvent) -> Bool {
        switch self {
        case .all: return true
        case .tools: return event.kind == .preTool || event.kind == .postTool
        case .errors: return event.kind == .toolError || event.kind == .stop
        case .permissions: return event.kind == .permissionRequest
        }
    }
}

// MARK: - Relative Time Formatting

/// Format a Unix-ms timestamp as a relative time string.
/// Kept `internal` intentionally for test access.
func relativeTime(_ unixMs: Int) -> String {
    let date = Date(timeIntervalSince1970: Double(unixMs) / 1000)
    let seconds = Int(Date().timeIntervalSince(date))

    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
    return RelativeTimeFormatting.absoluteFormatter.string(from: date)
}

private enum RelativeTimeFormatting {
    static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .short
        return f
    }()
}

// MARK: - Activity Feed View

struct ActivityFeedView: View {
    let events: [HookEvent]
    var connectionState: ConnectionState = .connected
    @Environment(AppStore.self) private var store
    @State private var selectedPermission: PermissionRequest?

    var body: some View {
        VStack(spacing: 0) {
            // Connection status banner
            if !connectionState.isConnected {
                ActivityConnectionBanner(state: connectionState)
            }

            // Event list (filter chips removed per #94 — playback wasn't working
            // and the categories were generally empty).
            if events.isEmpty {
                ContentUnavailableView {
                    Label("No Events", systemImage: "clock")
                } description: {
                    Text("Activity will appear here as the agent works.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(events) { event in
                                if event.kind == .permissionRequest,
                                   let perm = store.pendingPermissions.values.first(where: {
                                       $0.agentId == event.agentId && $0.toolName == event.toolName
                                   }) {
                                    ActivityEventRow(event: event, accent: store.theme.accentColor, isPending: true)
                                        .id(event.id)
                                        .onTapGesture { selectedPermission = perm }
                                } else {
                                    ActivityEventRow(event: event, accent: store.theme.accentColor)
                                        .id(event.id)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onChange(of: events.count) {
                        if let last = events.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedPermission) { perm in
            PermissionRequestSheet(permission: perm, agentName: nil)
        }
    }
}

// MARK: - Event Row

private struct ActivityEventRow: View {
    let event: HookEvent
    let accent: Color
    var isPending: Bool = false

    private var iconColor: Color {
        switch event.kind {
        case .preTool: accent
        case .postTool: .green
        case .toolError: .red
        case .stop: .secondary
        case .notification: accent
        case .permissionRequest: .orange
        }
    }

    private var backgroundColor: Color {
        switch event.kind {
        case .permissionRequest: .orange.opacity(0.1)
        case .toolError: .red.opacity(0.1)
        case .stop: .secondary.opacity(0.08)
        default: .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: hookEventIcon(event))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, height: 20, alignment: .center)
            }
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(hookEventDescription(event, isPending: isPending))
                    .font(.subheadline)
                Text(relativeTime(event.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
    }
}

// MARK: - Hook Event Formatting (testable)

/// Returns the SF Symbol name for a hook event.
func hookEventIcon(_ event: HookEvent) -> String {
    switch event.kind {
    case .preTool: return toolIcon(event.toolName)
    case .postTool: return "checkmark.circle"
    case .toolError: return "exclamationmark.triangle.fill"
    case .stop: return "stop.circle.fill"
    case .notification: return "bell.fill"
    case .permissionRequest: return "lock.fill"
    }
}

/// Returns a display description for a hook event.
func hookEventDescription(_ event: HookEvent, isPending: Bool = false) -> String {
    switch event.kind {
    case .preTool:
        return event.toolVerb ?? "Using \(event.toolName ?? "tool")"
    case .postTool:
        return "\(event.toolName ?? "Tool") completed"
    case .toolError:
        return event.message ?? "Tool error"
    case .stop:
        return event.message ?? "Agent stopped"
    case .notification:
        return event.message ?? ""
    case .permissionRequest:
        let detail = event.message ?? event.toolName ?? "unknown"
        return isPending ? "Tap to respond: \(detail)" : "Needs permission: \(detail)"
    }
}

/// Returns the semantic color name for a hook event kind.
func hookEventColorName(_ kind: HookEventKind) -> String {
    switch kind {
    case .preTool: return "accent"
    case .postTool: return "green"
    case .toolError: return "red"
    case .stop: return "secondary"
    case .notification: return "accent"
    case .permissionRequest: return "orange"
    }
}

private func toolIcon(_ toolName: String?) -> String {
    switch toolName {
    case "Edit": return "pencil"
    case "Read": return "doc.text"
    case "Write": return "doc.badge.plus"
    case "Bash": return "terminal"
    case "Glob": return "magnifyingglass"
    case "Grep": return "text.magnifyingglass"
    case "WebSearch": return "globe"
    case "WebFetch": return "arrow.down.circle"
    case "Task": return "arrow.triangle.branch"
    default: return "wrench"
    }
}

// MARK: - Connection Banner

private struct ActivityConnectionBanner: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 8) {
            if case .reconnecting(let attempt) = state {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Reconnecting (\(attempt))...")
                    .font(.caption.weight(.medium))
            } else {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                Text(state.label)
                    .font(.caption.weight(.medium))
            }
            Spacer()
            Text("Activity may be stale")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.85))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(state.label). Activity may be stale.")
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return ActivityFeedView(events: MockData.activity["durable_1737000000000_abc123"]!)
        .environment(store)
}
