import SwiftUI

// MARK: - Swipeable Agent Card View

/// A "Tinder for agents" full-screen card interface for quickly swiping between agents.
struct SwipeableAgentView: View {
    @Environment(AppStore.self) private var store
    @State private var selectedIndex: Int = 0

    let agents: [AppStore.InstanceAgent]

    var body: some View {
        if agents.isEmpty {
            ContentUnavailableView(
                "No Agents",
                systemImage: "person.3",
                description: Text("Agents will appear here once they're running.")
            )
        } else {
            TabView(selection: $selectedIndex) {
                ForEach(Array(agents.enumerated()), id: \.element.agent.id) { index, ia in
                    AgentCardView(agent: ia.agent, instance: ia.instance)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .indexViewStyle(.page(backgroundDisplayMode: .automatic))
            .onChange(of: selectedIndex) { _, _ in
                Haptics.selection()
            }
            .onChange(of: agents.count) { _, newCount in
                if selectedIndex >= newCount {
                    selectedIndex = max(0, newCount - 1)
                }
            }
        }
    }
}

// MARK: - Agent Card

/// A full-screen card showing a single agent's status, activity, and terminal preview.
private struct AgentCardView: View {
    let agent: DurableAgent
    let instance: ServerInstance
    @Environment(AppStore.self) private var store

    private var statusColor: Color {
        agentStatusColor(state: agent.detailedStatus?.state, status: agent.status)
    }

    private var statusLabel: String {
        if let ds = agent.detailedStatus {
            switch ds.state {
            case .working: return ds.message.isEmpty ? "Working" : ds.message
            case .needsPermission: return "Needs permission"
            case .toolError: return ds.message.isEmpty ? "Error" : ds.message
            case .idle: return "Idle"
            }
        }
        return agent.status?.rawValue.capitalized ?? "Unknown"
    }

    private var orchestratorLabel: String? {
        guard let orchId = agent.orchestrator,
              let info = store.orchestrators[orchId] else { return nil }
        return info.shortName
    }

    private var projectName: String? {
        instance.project(for: agent)?.label
    }

    private var recentActivity: [HookEvent] {
        Array(instance.activity(for: agent.id).suffix(3))
    }

    private var terminalPreview: String {
        let buffer = store.ptyBuffer(for: agent.id)
        guard !buffer.isEmpty else { return "" }
        // Strip ANSI escape sequences for clean preview
        let stripped = buffer.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        let lines = stripped.components(separatedBy: .newlines)
        let lastLines = lines.suffix(4).filter { !$0.isEmpty }
        return lastLines.joined(separator: "\n")
    }

    private var hasPendingPermission: Bool {
        agent.detailedStatus?.state == .needsPermission
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cardHeader
                chipRow
                statusSection
                if !recentActivity.isEmpty {
                    activitySection
                }
                if !terminalPreview.isEmpty {
                    terminalSection
                }
                quickActions
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(store.theme.surface0Color.opacity(0.6))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        )
        .overlay(alignment: .topTrailing) {
            if hasPendingPermission {
                permissionBadge
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        VStack(spacing: 12) {
            AgentAvatarView(
                color: agent.color ?? "gray",
                status: agent.status,
                state: agent.detailedStatus?.state,
                name: agent.name,
                iconData: store.agentIconData(agent.id),
                size: 64
            )

            Text(agent.name ?? agent.id)
                .font(.title2.weight(.bold))
                .lineLimit(1)

            if let project = projectName {
                Text(project)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Chip Row

    private var chipRow: some View {
        HStack(spacing: 6) {
            if let label = orchestratorLabel {
                let c = OrchestratorColors.colors(for: agent.orchestrator)
                ChipView(text: label, bg: c.bg, fg: c.fg)
            }
            if let label = modelLabel(from: agent.model) {
                let c = ModelColors.colors(for: agent.model)
                ChipView(text: label, bg: c.bg, fg: c.fg)
            }
            if agent.freeAgentMode == true {
                ChipView(text: "Free", bg: .red.opacity(0.15), fg: .red)
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        HStack(spacing: 8) {
            PulsingStatusDot(color: statusColor, isAnimating: agent.status == .running)
            Text(statusLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let ts = agent.detailedStatus?.timestamp {
                Text(compactRelativeTime(from: ts))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(statusColor.opacity(0.1))
        )
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent Activity", systemImage: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(recentActivity) { event in
                HStack(spacing: 8) {
                    Image(systemName: hookEventIcon(for: event))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hookEventIconColor(for: event, accent: store.theme.accentColor))
                        .frame(width: 16, alignment: .center)

                    Text(hookEventLabel(for: event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(compactRelativeTime(from: event.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(store.theme.surface1Color.opacity(0.5))
        )
    }

    // MARK: - Terminal Preview Section

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Terminal", systemImage: "terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(terminalPreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.7))
        )
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 12) {
            if agent.status == .running {
                NavigationLink(value: "live:\(agent.id)") {
                    CardActionButton(
                        icon: "terminal",
                        label: "Terminal",
                        color: store.theme.accentColor
                    )
                }
                .accessibilityHint("Opens live terminal view")
            }

            NavigationLink(value: agent) {
                CardActionButton(
                    icon: "chart.bar",
                    label: "Details",
                    color: .blue
                )
            }
            .accessibilityHint("Shows agent details and activity")
        }
    }

    // MARK: - Permission Badge

    private var permissionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2.weight(.bold))
            Text("Permission")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.orange))
        .foregroundStyle(.white)
        .padding(20)
        .accessibilityLabel("Agent needs permission approval")
    }
}

// MARK: - Supporting Views

/// A pulsing status dot that animates for running agents.
/// Respects Reduce Motion accessibility setting.
private struct PulsingStatusDot: View {
    let color: Color
    let isAnimating: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldAnimate: Bool {
        isAnimating && !reduceMotion
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .scaleEffect(shouldAnimate && pulse ? 1.3 : 1.0)
            .opacity(shouldAnimate && pulse ? 0.7 : 1.0)
            .animation(
                shouldAnimate
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear {
                if shouldAnimate { pulse = true }
            }
            .onChange(of: isAnimating) { _, animating in
                pulse = animating && !reduceMotion
            }
    }
}

/// A quick action button for agent cards.
private struct CardActionButton: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.1))
        )
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return NavigationStack {
        SwipeableAgentView(
            agents: store.allAgentsAcrossInstances
        )
    }
    .environment(store)
}
