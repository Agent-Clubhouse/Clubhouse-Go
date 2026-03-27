import SwiftUI

// MARK: - Shared Tool Icon Mapping

/// Maps a tool name to an SF Symbol for activity displays.
func toolIcon(for toolName: String?) -> String {
    switch toolName {
    case "Edit": "pencil"
    case "Read": "doc.text"
    case "Write": "doc.badge.plus"
    case "Bash": "terminal"
    case "Glob": "magnifyingglass"
    case "Grep": "text.magnifyingglass"
    case "WebSearch": "globe"
    case "WebFetch": "arrow.down.circle"
    case "Task": "arrow.triangle.branch"
    default: "wrench"
    }
}

// MARK: - Shared Compact Time Formatting

/// Formats a unix-millisecond timestamp as a compact relative string (now, 5m, 2h, 3d).
func compactRelativeTime(from unixMs: Int) -> String {
    let seconds = max(0, (Int(Date().timeIntervalSince1970 * 1000) - unixMs) / 1000)
    if seconds < 60 { return "now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d"
}

// MARK: - Shared Model Label

/// Extracts a short display label from a model ID string.
func modelLabel(from model: String?) -> String? {
    guard let model else { return nil }
    if model.contains("opus") { return "Opus" }
    if model.contains("sonnet") { return "Sonnet" }
    if model.contains("haiku") { return "Haiku" }
    return model
}

// MARK: - Shared Agent Status Color

/// Returns the display color for an agent based on its detailed state and status.
func agentStatusColor(state: AgentState?, status: AgentStatus?) -> Color {
    switch state {
    case .working: return .green
    case .needsPermission: return .orange
    case .toolError: return .yellow
    default:
        switch status {
        case .starting, .running: return .green
        case .sleeping: return .gray
        case .error, .failed: return .red
        case .completed: return .blue
        case .cancelled: return .gray
        case nil: return .gray
        }
    }
}

// MARK: - Shared Hook Event Display

/// Returns the SF Symbol icon name for a hook event.
func hookEventIcon(for event: HookEvent) -> String {
    switch event.kind {
    case .preTool: toolIcon(for: event.toolName)
    case .postTool: "checkmark.circle"
    case .toolError: "exclamationmark.triangle.fill"
    case .stop: "stop.circle.fill"
    case .notification: "bell.fill"
    case .permissionRequest: "lock.fill"
    }
}

/// Returns the display color for a hook event icon.
func hookEventIconColor(for event: HookEvent, accent: Color) -> Color {
    switch event.kind {
    case .preTool: accent
    case .postTool: .green
    case .toolError: .red
    case .stop: .secondary
    case .notification: accent
    case .permissionRequest: .orange
    }
}

/// Returns a short description label for a hook event.
func hookEventLabel(for event: HookEvent) -> String {
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
        return "Needs permission"
    }
}

// MARK: - Shimmer Loading Effect

/// A shimmer/skeleton loading placeholder that pulses.
struct ShimmerView: View {
    var width: CGFloat? = nil
    var height: CGFloat = 16
    var cornerRadius: CGFloat = 6

    @State private var phase: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.secondary.opacity(phase ? 0.15 : 0.08))
            .frame(width: width, height: height)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

/// A skeleton placeholder for a stat card.
struct StatCardSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            ShimmerView(width: 28, height: 28, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                ShimmerView(width: 36, height: 20, cornerRadius: 4)
                ShimmerView(width: 56, height: 10, cornerRadius: 3)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

/// A skeleton placeholder for an agent card row.
struct AgentCardSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 4, height: 44)
            ShimmerView(width: 36, height: 36, cornerRadius: 18)
            VStack(alignment: .leading, spacing: 6) {
                ShimmerView(width: 120, height: 14, cornerRadius: 4)
                ShimmerView(width: 180, height: 10, cornerRadius: 3)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

/// A skeleton placeholder for a project card row.
struct ProjectCardSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 4, height: 48)
            ShimmerView(width: 32, height: 32, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 6) {
                ShimmerView(width: 100, height: 14, cornerRadius: 4)
                ShimmerView(width: 140, height: 10, cornerRadius: 3)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Error State with Retry

/// A reusable error state view with retry button.
struct ErrorRetryView: View {
    let title: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(action: onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
