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
    @Environment(AppStore.self) private var store
    @State private var selectedPermission: PermissionRequest?
    @State private var filter: ActivityFilter = .all

    private var filteredEvents: [HookEvent] {
        events.filter { filter.matches($0) }
    }

    /// Pre-compute filter counts once per render instead of per-chip.
    private var filterCounts: [ActivityFilter: Int] {
        var counts: [ActivityFilter: Int] = [:]
        for f in ActivityFilter.allCases where f != .all {
            counts[f] = events.filter { f.matches($0) }.count
        }
        return counts
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ActivityFilter.allCases, id: \.self) { option in
                        let count = option == .all ? nil : filterCounts[option]
                        FilterChip(
                            title: option.rawValue,
                            count: count,
                            isSelected: filter == option
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) { filter = option }
                        }
                        .accessibilityLabel(chipAccessibilityLabel(option, count: count))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            // Event list
            if filteredEvents.isEmpty {
                ContentUnavailableView {
                    Label("No Events", systemImage: filter == .all ? "clock" : "line.3.horizontal.decrease.circle")
                } description: {
                    Text(filter == .all ? "Activity will appear here as the agent works." : "No \(filter.rawValue.lowercased()) events yet.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredEvents) { event in
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
                    .onChange(of: filteredEvents.count) {
                        if let last = filteredEvents.last {
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

    private func chipAccessibilityLabel(_ filter: ActivityFilter, count: Int?) -> String {
        if let count, count > 0 {
            return "\(filter.rawValue), \(count) event\(count == 1 ? "" : "s")"
        }
        return filter.rawValue
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isSelected ? .white.opacity(0.25) : .secondary.opacity(0.15))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Event Row

private struct ActivityEventRow: View {
    let event: HookEvent
    let accent: Color
    var isPending: Bool = false

    private var icon: String {
        switch event.kind {
        case .preTool:
            return toolIcon(event.toolName)
        case .postTool:
            return "checkmark.circle"
        case .toolError:
            return "exclamationmark.triangle.fill"
        case .stop:
            return "stop.circle.fill"
        case .notification:
            return "bell.fill"
        case .permissionRequest:
            return "lock.fill"
        }
    }

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

    private var description: String {
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
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, height: 20, alignment: .center)
            }
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(description)
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

// MARK: - Helpers

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

#Preview {
    let store = AppStore()
    store.loadMockData()
    return ActivityFeedView(events: MockData.activity["durable_1737000000000_abc123"]!)
        .environment(store)
}
