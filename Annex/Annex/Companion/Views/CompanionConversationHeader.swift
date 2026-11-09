import SwiftUI

/// Uses the same versioned custom image/cache and fallback identity as agent rows and details.
struct CompanionConversationIdentityButton: View {
    let agent: CompanionAgent
    @Binding var isExpanded: Bool
    let accessibilityLabel: String
    var reviewPosition: String? = nil

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 6) {
                CompanionAgentAvatar(agent: agent, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agent.displayName)
                        .font(.headline).lineLimit(1).truncationMode(.tail)
                    if let reviewPosition {
                        Text(reviewPosition).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reviewPosition.map { "\(agent.displayName), \($0)" } ?? accessibilityLabel)
        .accessibilityValue(isExpanded ? "Details expanded" : "Details collapsed")
        .accessibilityHint("Shows or hides conversation details")
        .accessibilityIdentifier(reviewPosition == nil ? "companion-chat-header" : "review-title")
    }
}

/// Stacks the details disclosure above the other-agent banner. The banner keeps its natural height; the
/// disclosure takes at most a third of what's left above the composer and scrolls within that.
/// Nothing measured is stored in State or fed back into the disclosure's own reservation.
struct CompanionConversationHeaderBarLayout: Layout {
    /// The height between the top of the screen and the composer, which already reserves its own space.
    let residualHeight: CGFloat
    let showsDetails: Bool

    private func sizes(width: CGFloat, subviews: Subviews) -> (details: CGSize, banner: CGSize)? {
        guard subviews.count == 2 else {
            assertionFailure("Header bar requires its two concrete disclosure/banner containers")
            return nil
        }
        let banner = subviews[1].sizeThatFits(.init(width: width, height: nil))
        guard showsDetails else { return (.init(width: width, height: 0), banner) }
        let ideal = subviews[0].sizeThatFits(.init(width: width, height: nil))
        let remaining = residualHeight - banner.height
        // Too little room to cap usefully: show the details whole rather than hide them. A scrolling
        // viewport keeps at least 44pt of content plus its 6pt bottom padding.
        guard remaining.isFinite, remaining >= 50 else { return (ideal, banner) }
        let budget = min(ideal.height, max(50, remaining / 3))
        let details = subviews[0].sizeThatFits(.init(width: width, height: budget))
        return (details, banner)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        guard let result = sizes(width: width, subviews: subviews) else { return .zero }
        return .init(width: width, height: result.details.height + result.banner.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let result = sizes(width: bounds.width, subviews: subviews) else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: .init(width: bounds.width, height: result.details.height))
        subviews[1].place(at: .init(x: bounds.minX, y: bounds.minY + result.details.height), anchor: .topLeading,
                          proposal: .init(width: bounds.width, height: result.banner.height))
    }
}

/// ViewThatFits exposes one card: its full ideal height when it fits, otherwise a clipped
/// scroll viewport. The proposal includes all horizontal/bottom padding, not just the text.
struct CompanionConversationDetailsViewport: View {
    let agent: CompanionAgent
    let contextName: String

    private var card: some View {
        CompanionConversationDetailsCard(agent: agent, contextName: contextName)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            card
            ScrollView(.vertical) { card }
                .scrollDismissesKeyboard(.never)
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier("companion-chat-details-scroll")
        }
        .clipped()
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}

/// Secondary state is disclosed on demand; actionable warnings keep their independent surfaces.
struct CompanionConversationDetailsCard: View {
    let agent: CompanionAgent
    let contextName: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agent.displayName).font(.headline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("companion-chat-details-name")
            Text(contextName).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("companion-chat-host-tag")
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                CompanionStatusText(status: agent.status).font(.caption.weight(.semibold))
                    .accessibilityIdentifier("companion-chat-details-status")
                // A known live level takes precedence; boolean-only Access can be Auto or Full.
                if let controls = agent.chatControls { CompanionLevelBadge(level: controls.currentLevel) }
                else if let level = agent.session?.level.flatMap(CompanionPermissionLevel.init(rawValue:)) { CompanionLevelBadge(level: level) }
                else if agent.freeAgentMode { CompanionElevatedAccessBadge(label: CompanionFreeAgentMode.title) }
            }
            if let model = agent.model {
                Text(model).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("companion-chat-details-model")
            }
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
