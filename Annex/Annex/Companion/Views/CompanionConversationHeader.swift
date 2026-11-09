import SwiftUI

/// Uses the same versioned custom image/cache and fallback identity as agent rows and details.
struct CompanionConversationIdentityButton: View {
    let agent: CompanionAgent
    @Binding var isExpanded: Bool
    let accessibilityLabel: String
    var reviewPosition: String? = nil
    /// Expanded, but there's no room to show the details (landscape with the keyboard up).
    var detailsLackRoom = false

    @Environment(\.companionPalette) private var palette
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var namePill: some View {
        HStack(spacing: 3) {
            Text(agent.displayName)
                .font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.tail)
            if let reviewPosition {
                Text(reviewPosition).font(.caption2.monospacedDigit()).foregroundStyle(Color(palette.secondaryLabel))
            }
            Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Color(palette.secondaryLabel))
        }
        .foregroundStyle(Color(palette.label))
        .padding(.horizontal, 9).padding(.vertical, 3)
        .companionCardGlass(Capsule(), interactive: true)
    }

    /// Like Messages: the photo centred over a small name pill, floating over the transcript. A short (landscape)
    /// bar has no room for that, so the photo shrinks and sits beside the pill.
    var body: some View {
        let compact = verticalSizeClass == .compact
        Button { isExpanded.toggle() } label: {
            let layout = compact ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: -4))
            layout {
                CompanionAgentAvatar(agent: agent, size: compact ? 30 : 50)
                    // Lifted off whatever scrolls behind it.
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                namePill
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Bar controls cap their size, like the system's; the Large Content Viewer shows the name at accessibility
        // sizes, and the details card shows it in full.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityShowsLargeContentViewer {
            Label(agent.displayName, systemImage: "person.crop.circle")
        }
        .accessibilityLabel(reviewPosition.map { "\(agent.displayName), \($0)" } ?? accessibilityLabel)
        .accessibilityValue(isExpanded ? (detailsLackRoom ? "Details hidden, no room while editing" : "Details expanded") : "Details collapsed")
        .accessibilityHint("Shows or hides conversation details")
        .accessibilityIdentifier(reviewPosition == nil ? "companion-chat-header" : "review-title")
    }
}

extension View {
    /// Glass behind the content, over the theme's opaque card. Bare glass took on the brightness of the transcript
    /// scrolled beneath it (the dark theme's label fell to 1.5:1), and content inside a glass effect is restyled,
    /// which dimmed avatars and status colours. Here the content is untouched, and the palette keeps its label and
    /// secondary label at 4.5:1 or better against the card.
    func companionCardGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        background { CompanionCardGlass(shape: shape, interactive: interactive) }
    }
}

private struct CompanionCardGlass<S: Shape>: View {
    let shape: S
    let interactive: Bool
    @Environment(\.companionPalette) private var palette
    var body: some View {
        shape.fill(Color(palette.card))
            .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}

/// Stacks the details disclosure above the other-agent banner. The banner keeps its natural height; the
/// disclosure takes at most a third of what's left above the composer and scrolls within that.
/// Nothing measured is stored in State or fed back into the disclosure's own reservation.
struct CompanionConversationHeaderBarLayout: Layout {
    /// The details' 50pt minimum (44pt of content plus 6pt padding) and as much again for the transcript.
    static let minimumRoomForDetails: CGFloat = 100
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
        guard remaining.isFinite else { return (ideal, banner) }
        // Normally a third of the room above the composer, but never less than 50pt (44pt of content plus the 6pt
        // bottom padding) while that fits. In a short window, such as landscape with the keyboard up, the details get
        // only what's left and scroll there; they never cover the navigation bar or the composer.
        let budget = min(ideal.height, remaining >= 50 ? max(50, remaining / 3) : max(0, remaining))
        let details = subviews[0].sizeThatFits(.init(width: width, height: budget))
        // The viewport's padding has a minimum; the slot clips to the budget rather than overflow it.
        return (.init(width: details.width, height: min(details.height, budget)), banner)
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
    @Environment(\.companionPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(agent.displayName).font(.headline).foregroundStyle(Color(palette.label))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("companion-chat-details-name")
            Text(contextName).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
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
                Text(model).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    .accessibilityIdentifier("companion-chat-details-model")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .companionCardGlass(RoundedRectangle(cornerRadius: 20))
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
