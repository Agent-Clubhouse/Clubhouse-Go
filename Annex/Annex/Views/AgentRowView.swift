import SwiftUI

struct AgentRowView: View {
    let agent: DurableAgent
    @Environment(AppStore.self) private var store

    private var preview: String {
        if agent.status == .running, let msg = agent.detailedStatus?.message, !msg.isEmpty {
            return msg
        }
        if let mission = agent.mission {
            return mission
        }
        return agent.status == .sleeping ? "Sleeping" : ""
    }

    private var modelLabel: String? {
        guard let model = agent.model else { return nil }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    private var orchestratorLabel: String? {
        guard let orchId = agent.orchestrator,
              let info = store.orchestrators[orchId] else { return nil }
        return info.shortName
    }

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatarView(
                color: agent.color ?? "gray",
                status: agent.status,
                state: agent.detailedStatus?.state,
                name: agent.name,
                iconData: store.agentIconData(agent.id)
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(agent.name ?? agent.id)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)

                    if let label = orchestratorLabel {
                        let c = OrchestratorColors.colors(for: agent.orchestrator)
                        ChipView(text: label, bg: c.bg, fg: c.fg)
                    }
                    if let label = modelLabel {
                        let c = ModelColors.colors(for: agent.model)
                        ChipView(text: label, bg: c.bg, fg: c.fg)
                    }
                    if agent.freeAgentMode == true {
                        ChipView(text: "Free", bg: .red.opacity(0.15), fg: .red)
                    }
                }

                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let ts = agent.detailedStatus?.timestamp {
                Text(compactRelativeTime(from: ts))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct QuickAgentRowView: View {
    let agent: QuickAgent

    private var preview: String {
        agent.prompt ?? agent.mission ?? ""
    }

    private var iconName: String {
        switch agent.status {
        case .starting: return "bolt.circle"
        case .running: return "bolt.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed, .error: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .sleeping, nil: return "bolt"
        }
    }

    private var iconColor: Color {
        switch agent.status {
        case .starting, .running: return .orange
        case .completed: return .green
        case .failed, .error: return .red
        case .cancelled: return .secondary
        case .sleeping, nil: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(agent.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let model = agent.model {
                        let label = model.contains("opus") ? "Opus"
                            : model.contains("sonnet") ? "Sonnet"
                            : model.contains("haiku") ? "Haiku" : model
                        let c = ModelColors.colors(for: model)
                        ChipView(text: label, bg: c.bg, fg: c.fg)
                    }
                }
                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let summary = agent.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let status = agent.status {
                StatusDotView(status: status)
            }
        }
        .padding(.vertical, 4)
    }
}

// relativeTime is provided by compactRelativeTime in ViewHelpers.swift

#Preview {
    let store = AppStore()
    store.loadMockData()
    return List {
        AgentRowView(agent: MockData.agents["proj_001"]![0])
        AgentRowView(agent: MockData.agents["proj_001"]![1])
        AgentRowView(agent: MockData.agents["proj_002"]![0])
        AgentRowView(agent: MockData.agents["proj_002"]![1])
    }
    .environment(store)
}
