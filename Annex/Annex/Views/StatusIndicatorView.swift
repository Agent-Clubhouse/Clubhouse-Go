import SwiftUI

// Extract 2-letter initials from hyphenated agent name
func agentInitials(from name: String?) -> String {
    guard let name, !name.isEmpty else { return "" }
    let parts = name.split(separator: "-")
    if parts.count >= 2 {
        let first = parts[0].prefix(1).uppercased()
        let second = parts[1].prefix(1).uppercased()
        return first + second
    }
    return String(name.prefix(1)).uppercased()
}

// Extract single initial from project name
func projectInitial(from displayName: String?, name: String) -> String {
    let source = displayName ?? name
    guard let first = source.first else { return "" }
    return String(first).uppercased()
}

// Avatar with status ring — matches Clubhouse's AgentListItem
struct AgentAvatarView: View {
    let color: String
    let status: AgentStatus?
    let state: AgentState?
    var name: String? = nil
    var iconData: Data? = nil
    var size: CGFloat = 36

    @State private var ringPhase: CGFloat = 0
    @State private var badgePulse: Bool = false

    private var ringColor: Color {
        switch state {
        case .working: .green
        case .needsPermission: .orange
        case .toolError: .yellow
        default:
            switch status {
            case .starting, .running: .green
            case .sleeping: .gray
            case .error, .failed: .red
            case .completed: .blue
            case .cancelled, .unknown: .gray
            case nil: .gray
            }
        }
    }

    private var showErrorBadge: Bool {
        state == .needsPermission || status == .error
    }

    private var initialsCircle: some View {
        Circle()
            .fill(AgentColor.color(for: color))
            .frame(width: size, height: size)
            .overlay(
                Text(agentInitials(from: name))
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let iconData, let uiImage = UIImage(data: iconData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    initialsCircle
                }
            }
            .overlay(
                Circle()
                    .strokeBorder(ringColor, lineWidth: 2.5)
                    .frame(width: size + 4, height: size + 4)
                    .opacity(state == .working ? (0.6 + 0.4 * sin(Double(ringPhase))) : 1)
                    .animation(.easeInOut(duration: 0.4), value: ringColor)
            )

            if showErrorBadge {
                Circle()
                    .fill(.red)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(
                        Image(systemName: "exclamationmark")
                            .font(.system(size: size * 0.16, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .scaleEffect(state == .needsPermission && badgePulse ? 1.2 : 1.0)
                    .offset(x: size * 0.06, y: -size * 0.06)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showErrorBadge)
        .onAppear {
            if state == .working {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    ringPhase = .pi * 2
                }
            }
            if state == .needsPermission {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    badgePulse = true
                }
            }
        }
        .onChange(of: state) { _, newState in
            ringPhase = 0
            badgePulse = false
            if newState == .working {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    ringPhase = .pi * 2
                }
            }
            if newState == .needsPermission {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    badgePulse = true
                }
            }
        }
    }
}

// Dark rounded square with single initial — matches Clubhouse project icons
struct ProjectIconView: View {
    let name: String
    let displayName: String?
    var iconData: Data? = nil
    var size: CGFloat = 32

    private var initialSquare: some View {
        RoundedRectangle(cornerRadius: size * 0.2)
            .fill(Color(white: 0.22))
            .frame(width: size, height: size)
            .overlay(
                Text(projectInitial(from: displayName, name: name))
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            )
    }

    var body: some View {
        if let iconData, let uiImage = UIImage(data: iconData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            initialSquare
        }
    }
}

// Small status dot
struct StatusDotView: View {
    let status: AgentStatus
    var size: CGFloat = 8

    private var color: Color {
        switch status {
        case .starting: .orange
        case .running: .green
        case .sleeping: .yellow
        case .error, .failed: .red
        case .completed: .blue
        case .cancelled, .unknown: .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.3), value: status)
    }
}

// Chip pill matching Clubhouse's inline badges
struct ChipView: View {
    let text: String
    let bg: Color
    let fg: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
    }
}

// Orchestrator chip colors matching Clubhouse
enum OrchestratorColors {
    static func colors(for id: String?) -> (bg: Color, fg: Color) {
        switch id {
        case "claude-code":
            return (Color(hex: "#fb923c").opacity(0.2), Color(hex: "#fb923c"))
        case "copilot-cli":
            return (Color(hex: "#60a5fa").opacity(0.2), Color(hex: "#60a5fa"))
        case "codex":
            return (Color(hex: "#34d399").opacity(0.2), Color(hex: "#34d399"))
        default:
            return (Color(hex: "#94a3b8").opacity(0.2), Color(hex: "#94a3b8"))
        }
    }
}

// Model chip color — hash-based 7-color palette matching Clubhouse
enum ModelColors {
    private static let palette: [(bg: Color, fg: Color)] = [
        (Color.purple.opacity(0.15), .purple),
        (Color.teal.opacity(0.15), .teal),
        (Color.pink.opacity(0.15), .pink),
        (Color.green.opacity(0.15), .green),
        (Color(hex: "#f59e0b").opacity(0.15), Color(hex: "#f59e0b")),
        (Color.indigo.opacity(0.15), .indigo),
        (Color(hex: "#0ea5e9").opacity(0.15), Color(hex: "#0ea5e9")),
    ]

    static func colors(for model: String?) -> (bg: Color, fg: Color) {
        guard let model else { return palette[0] }
        let hash = abs(model.hashValue)
        return palette[hash % palette.count]
    }
}

#Preview {
    VStack(spacing: 16) {
        HStack(spacing: 12) {
            AgentAvatarView(color: "emerald", status: .running, state: .working, name: "gallant-swift")
            AgentAvatarView(color: "rose", status: .sleeping, state: nil, name: "bold-falcon")
            AgentAvatarView(color: "amber", status: .error, state: .needsPermission, name: "lucky-mantis")
        }
        HStack(spacing: 12) {
            ProjectIconView(name: "my-app", displayName: nil)
            ProjectIconView(name: "SourceKit", displayName: "SourceKit")
        }
        HStack(spacing: 8) {
            ChipView(text: "CC", bg: Color(hex: "#fb923c").opacity(0.2), fg: Color(hex: "#fb923c"))
            ChipView(text: "Opus", bg: .purple.opacity(0.15), fg: .purple)
            ChipView(text: "Free", bg: .red.opacity(0.15), fg: .red)
        }
    }
    .padding()
}
