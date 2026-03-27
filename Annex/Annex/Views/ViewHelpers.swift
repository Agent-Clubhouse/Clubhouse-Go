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
