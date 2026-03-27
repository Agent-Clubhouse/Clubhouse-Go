import SwiftUI

// MARK: - Recent Activity Section (extracted from DashboardView)

struct RecentActivitySection: View {
    @Environment(AppStore.self) private var store

    private var recentEvents: [AgentHookEvent] {
        store.connectedInstances.flatMap { inst in
            inst.allActivityEvents.map { AgentHookEvent(event: $0, instance: inst) }
        }
        .sorted { $0.event.timestamp > $1.event.timestamp }
        .prefix(8)
        .map { $0 }
    }

    var body: some View {
        if !recentEvents.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent Activity")
                        .font(.headline)
                    Spacer()
                }

                VStack(spacing: 0) {
                    ForEach(Array(recentEvents.enumerated()), id: \.element.event.id) { index, item in
                        DashboardActivityRow(
                            event: item.event,
                            agentName: store.durableAgent(byId: item.event.agentId)?.name,
                            agentColor: store.durableAgent(byId: item.event.agentId)?.color,
                            accent: store.theme.accentColor
                        )

                        if index < recentEvents.count - 1 {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(store.theme.surface0Color.opacity(0.4))
                )
            }
        }
    }
}

/// Pairs a HookEvent with its source instance for cross-instance aggregation.
struct AgentHookEvent {
    let event: HookEvent
    let instance: ServerInstance
}

struct DashboardActivityRow: View {
    let event: HookEvent
    let agentName: String?
    let agentColor: String?
    let accent: Color

    private var icon: String {
        switch event.kind {
        case .preTool: toolIcon(for: event.toolName)
        case .postTool: "checkmark.circle"
        case .toolError: "exclamationmark.triangle.fill"
        case .stop: "stop.circle.fill"
        case .notification: "bell.fill"
        case .permissionRequest: "lock.fill"
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

    private var label: String {
        switch event.kind {
        case .preTool:
            return event.toolVerb ?? "Using \(event.toolName ?? "tool")"
        case .postTool:
            return "\(event.toolName ?? "Tool") done"
        case .toolError:
            return event.message ?? "Error"
        case .stop:
            return event.message ?? "Stopped"
        case .notification:
            return event.message ?? ""
        case .permissionRequest:
            return "Needs permission: \(event.toolName ?? "tool")"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let name = agentName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Text(compactRelativeTime(from: event.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
