import SwiftUI

/// How Review was opened: from Needs you it starts with Needs you only on.
struct CompanionReviewLaunch: Identifiable, Hashable {
    var needsYouOnly: Bool
    var id: Self { self }
}

private struct CompanionOpenReviewKey: EnvironmentKey {
    static let defaultValue: (@MainActor (CompanionReviewLaunch) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens Review over the current tab. Nil where Review isn't offered.
    var companionOpenReview: (@MainActor (CompanionReviewLaunch) -> Void)? {
        get { self[CompanionOpenReviewKey.self] }
        set { self[CompanionOpenReviewKey.self] = newValue }
    }
}

/// The Review button for Home and Needs you.
struct CompanionReviewButton: View {
    var needsYouOnly: Bool
    @Environment(\.companionOpenReview) private var openReview
    var body: some View {
        if let openReview {
            Button("Review", systemImage: "rectangle.stack") { openReview(.init(needsYouOnly: needsYouOnly)) }
                .accessibilityIdentifier("companion-open-review")
                .accessibilityHint("Step through your agents' chats one at a time")
        }
    }
}

/// Steps through agents' chats one at a time, like the desktop's Review. Each page is the agent's full
/// conversation; a horizontal swipe moves to the next or previous agent and never answers anything.
/// Approvals and replies use the chat's own controls.
struct CompanionReviewView: View {
    @Bindable var store: CompanionStore
    /// Opens an agent outside Review, closing it.
    var onOpen: (CompanionTarget) -> Void
    /// Each page wears its desktop's theme, as a chat does.
    var theme: (CompanionTarget) -> CompanionDesktopTheme
    @State private var filters: CompanionReviewFilters
    @State private var selection: CompanionTarget?
    @State private var settingsTarget: CompanionTarget?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionPalette) private var palette

    init(store: CompanionStore, launch: CompanionReviewLaunch, theme: @escaping (CompanionTarget) -> CompanionDesktopTheme,
         onOpen: @escaping (CompanionTarget) -> Void) {
        self.store = store
        self.theme = theme
        self.onOpen = onOpen
        _filters = State(initialValue: .init(needsYouOnly: launch.needsYouOnly))
    }

    var body: some View {
        let all = store.reviewEntries
        let entries = CompanionReviewModel.visible(all, filters: filters)
        let ids = entries.map(\.id)
        let current = entries.first { $0.id == selection }
        NavigationStack {
            Group {
                if entries.isEmpty {
                    CompanionReviewEmptyState(cause: CompanionReviewModel.emptyCause(all, filters: filters), store: store, filters: $filters)
                } else {
                    // One page per agent. A page turns only on a horizontal swipe that the chat's own code and table
                    // scrollers don't take, and a lazy stack loads each chat as it comes near.
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(entries) { entry in
                                CompanionConversationView(store: store, agent: entry.agent, showsActions: entry.id == selection)
                                    .companionTheme(theme(entry.id))
                                    .scrollEdgeEffectHidden(false)
                                    .containerRelativeFrame(.horizontal)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $selection)
                    .scrollIndicators(.hidden)
                    // The pager's own edge effect would wash out each chat's composer; the chat keeps its own.
                    .scrollEdgeEffectHidden(true)
                }
            }
            .companionBackground()
            .safeAreaBar(edge: .top, spacing: 0) { filterBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("review-done")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(current?.agent.name ?? "Review").font(.headline).lineLimit(1)
                        if let position = CompanionReviewModel.position(of: selection, in: ids) {
                            Text(position).font(.caption.monospacedDigit()).foregroundStyle(Color(palette.secondaryLabel))
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(current.map { "\($0.agent.name), \(CompanionReviewModel.position(of: $0.id, in: ids) ?? "")" } ?? "Review")
                    .accessibilityIdentifier("review-title")
                }
            }
        }
        // The chat's "another agent needs you" banner moves within Review when that agent is listed.
        .environment(\.companionOpenAgent) { target in
            if ids.contains(target) { withAnimation { selection = target } } else { onOpen(target) }
        }
        // Review covers the tabs, so it presents a chat's agent settings itself.
        .environment(\.companionAgentSettings, .init(canOpen: { [store] in store.canEditSettings($0) }, open: { settingsTarget = $0 }))
        .sheet(item: $settingsTarget) { target in
            CompanionAgentSettingsSheet(store: store, target: target).companionTheme(theme(target))
        }
        .sensoryFeedback(.selection, trigger: selection)
        .onAppear { selection = CompanionReviewModel.successor(of: selection, previous: [], in: ids) }
        .onChange(of: ids) { previous, current in
            selection = CompanionReviewModel.successor(of: selection, previous: previous, in: current)
        }
    }

    /// The desktop's two Review filters. "Remote" is left out: every agent here is on another machine.
    private var filterBar: some View {
        HStack(spacing: 8) {
            CompanionReviewFilterChip(title: "Needs you only", isOn: $filters.needsYouOnly)
                .accessibilityIdentifier("review-filter-needs-you")
            CompanionReviewFilterChip(title: "Sleeping", isOn: $filters.includeSleeping)
                .accessibilityLabel("Include sleeping")
                .accessibilityIdentifier("review-filter-sleeping")
            Spacer(minLength: 0)
        }
        .sensoryFeedback(.selection, trigger: filters)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

/// A filter switch as a capsule: filled with the tint and checked when on.
private struct CompanionReviewFilterChip: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.companionPalette) private var palette
    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: "checkmark")
                .labelStyle(CompanionReviewChipLabelStyle(showsIcon: isOn))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isOn ? Color(palette.onTint) : Color(palette.label))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(isOn ? Color(palette.tint) : Color(palette.fill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct CompanionReviewChipLabelStyle: LabelStyle {
    var showsIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if showsIcon { configuration.icon.font(.caption.weight(.bold)) }
            configuration.title
        }
    }
}

/// Why there are no pages, with the fix (`ReviewEmptyState.tsx`).
struct CompanionReviewEmptyState: View {
    let cause: CompanionReviewEmptyCause
    @Bindable var store: CompanionStore
    @Binding var filters: CompanionReviewFilters
    @Environment(\.companionPalette) private var palette
    private let listLimit = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(cause.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(cause.message).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                content
            }
            .padding(24).frame(maxWidth: 440, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .accessibilityIdentifier("review-empty")
    }

    @ViewBuilder private var content: some View {
        switch cause {
        case .noAgents:
            EmptyView()
        case .nothingRunning(let sleepers):
            list(sleepers) { entry in
                if store.canWake(entry.id) {
                    Button("Wake") { Task { await store.wake(entry.id) } }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                } else { CompanionStatusText(status: entry.agent.status) }
            }
            Button("Show sleeping") { filters.includeSleeping = true }
                .buttonStyle(.borderedProminent).companionProminentLabel().buttonBorderShape(.capsule)
                .accessibilityIdentifier("review-empty-show-sleeping")
        case .nobodyNeedsYou(let others):
            list(others) { entry in CompanionStatusText(status: entry.agent.status) }
            Button("Show everyone") { filters.needsYouOnly = false }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                .accessibilityIdentifier("review-empty-show-everyone")
        }
    }

    private func list<Trailing: View>(_ entries: [CompanionReviewEntry], @ViewBuilder trailing: @escaping (CompanionReviewEntry) -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries.prefix(listLimit)) { entry in
                HStack(spacing: 10) {
                    CompanionAgentAvatar(agent: entry.agent, size: 26)
                    Text(entry.agent.name).lineLimit(1)
                        .foregroundStyle(entry.isSleeping ? Color(palette.secondaryLabel) : Color(palette.label))
                    Spacer(minLength: 8)
                    trailing(entry).font(.footnote)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            if entries.count > listLimit {
                Text("and \(entries.count - listLimit) more").font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
