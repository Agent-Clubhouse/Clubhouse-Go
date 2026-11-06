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
                    Text(agent.isDispatcher ? CompanionDispatcher.name : agent.name)
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
        .accessibilityLabel(reviewPosition.map { "\(agent.name), \($0)" } ?? accessibilityLabel)
        .accessibilityValue(isExpanded ? "Details expanded" : "Details collapsed")
        .accessibilityHint("Shows or hides conversation details")
        .accessibilityIdentifier(reviewPosition == nil ? "companion-chat-header" : "review-title")
    }
}

/// Value-only geometry at the boundary after the bottom bar and before the top bar.
/// The proxy can express a reservation in its frame or its insets; only this boundary's
/// reported insets are removed. No screen, keyboard or composer-height estimates enter layout.
struct CompanionConversationHeaderRegion {
    let frame: CGRect
    let safeFrame: CGRect

    init(geometry: GeometryProxy) {
        frame = geometry.frame(in: .global)
        let insets = geometry.safeAreaInsets
        safeFrame = CGRect(x: frame.minX + insets.leading, y: frame.minY + insets.top,
                           width: max(0, frame.width - insets.leading - insets.trailing),
                           height: max(0, frame.height - insets.top - insets.bottom))
    }
}

/// Measure the independent banner at its actual width before budgeting the disclosure.
/// No measured value is stored in State or fed back through the disclosure's own reservation.
struct CompanionConversationHeaderBarLayout: Layout {
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
        // No readable residual region: preserve content rather than hiding it or fabricating
        // space. Such a configuration is unsupported by this cap and must fail viewport QA.
        // A scrolling viewport must retain at least 44pt of visible content plus bottom6.
        // This is a disclosure usability floor, never an estimate of composer/banner height.
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
    let region: CompanionConversationHeaderRegion

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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion-chat-details-viewport")
        #if DEBUG
        // Read-only fixture witness of the actual boundary, not a layout input or State update.
        .accessibilityValue(CompanionConversationHeaderFixture.isEnabled
            ? [region.frame.minX, region.frame.minY, region.frame.width, region.frame.height,
               region.safeFrame.minX, region.safeFrame.minY, region.safeFrame.width, region.safeFrame.height]
                .map { String(Double($0)) }.joined(separator: ",") : "")
        #endif
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
                .accessibilityIdentifier("companion-chat-details-name")
            Text(contextName).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("companion-chat-host-tag")
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                CompanionStatusText(status: agent.status).font(.caption.weight(.semibold))
                    .accessibilityIdentifier("companion-chat-details-status")
                if agent.freeAgentMode { CompanionFreeAgentBadge() }
                if let controls = agent.chatControls {
                    CompanionLevelBadge(level: controls.currentLevel)
                }
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
