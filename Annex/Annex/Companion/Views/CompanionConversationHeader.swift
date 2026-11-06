import SwiftUI

/// Uses the same versioned custom image/cache and fallback identity as agent rows and details.
struct CompanionConversationIdentityButton: View {
    let agent: CompanionAgent
    @Binding var isExpanded: Bool
    let accessibilityLabel: String

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 6) {
                CompanionAgentAvatar(agent: agent, size: 28)
                Text(agent.isDispatcher ? CompanionDispatcher.name : agent.name)
                    .font(.headline).lineLimit(1).truncationMode(.tail)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isExpanded ? "Details expanded" : "Details collapsed")
        .accessibilityHint("Shows or hides conversation details")
        .accessibilityIdentifier("companion-chat-header")
    }
}

/// Secondary state is disclosed on demand; actionable warnings keep their independent surfaces.
struct CompanionConversationDetailsCard: View {
    let agent: CompanionAgent
    let contextName: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agent.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(contextName).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("companion-chat-host-tag")
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                CompanionStatusText(status: agent.status).font(.caption.weight(.semibold))
                if agent.freeAgentMode { CompanionFreeAgentBadge() }
                if let controls = agent.chatControls { CompanionLevelBadge(level: controls.currentLevel) }
            }
            if let model = agent.model { Text(model).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion-chat-details")
    }
}

/// Context retains its existing editor. Plan readings are desktop-scoped and load only on explicit navigation.
struct CompanionConversationUsageSheet: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    @Environment(\.dismiss) private var dismiss

    private var agent: CompanionAgent? { store.agent(for: target) }

    var body: some View {
        NavigationStack {
            CompanionAgentSettingsForm(store: store, target: target, focusContext: true)
                .safeAreaBar(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent?.contextUsage == nil ? "Context usage unknown" : "Latest reported context usage")
                        if store.host(for: target)?.connection.canOperate != true {
                            Text("Desktop unavailable. Reported values may be out of date.")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("companion-context-reading-note")
                }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    NavigationLink { CompanionPlanLimitsView(store: store) } label: {
                        Label("Plan limits by desktop", systemImage: "chart.bar")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glass)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .accessibilityIdentifier("companion-context-plan-limits")
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
