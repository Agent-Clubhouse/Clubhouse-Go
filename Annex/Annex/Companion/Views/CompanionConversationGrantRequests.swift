import SwiftUI

extension EnvironmentValues {
    @Entry var companionComposerFitsGrantFooter = false
}

/// Footer measurements stay out of the conversation's observation boundary, just like draft edits.
struct CompanionConversationGrantFooter<Composer: View>: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    let maximumHeight: CGFloat
    var showInChat: (String) -> Void = { _ in }
    @ViewBuilder var composer: Composer
    @State private var idealComposerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        // Keep the composer mounted across fit/keyboard changes. When the keyboard leaves less
        // room than this footer, Review stays first and the rest remains reachable by scrolling.
        ScrollView(.vertical) {
            FooterLayout(maximumHeight: maximumHeight) {
                // Concrete slots survive the final request disappearing during footer removal.
                VStack(spacing: 0) {
                    CompanionConversationGrantRequests(store: store, target: target,
                        maximumHeight: max(0, maximumHeight - idealComposerHeight) / 2)
                    CompanionConversationPendingDecisions(store: store, target: target,
                        maximumHeight: max(0, maximumHeight - idealComposerHeight)
                            / (store.grantRequests(for: target).isEmpty ? 1 : 2),
                        // The tray shares this room with the composer. An expanded text-action row must
                        // not consume the transcript/editor space just because the whole viewport is tall.
                        compactHeight: max(0, maximumHeight - idealComposerHeight) < 360, showInChat: showInChat)
                }
                VStack(spacing: 0) { composer }
                .environment(\.companionComposerFitsGrantFooter, true)
                // Measure the ideal proposal through a separate transparent slot, not the placed
                // editor. A capped editor must never feed its smaller height back into tray fit.
                Color.clear.frame(width: 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { idealComposerHeight = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .scrollDisabled(footerHeight <= maximumHeight)
        .scrollDismissesKeyboard(.never)
        .scrollBounceBehavior(.basedOnSize)
        // A fixed-content container, not a reading surface. Its frame reaches under the keyboard and tab bar,
        // so system edge effects would paint their own band from the footer's top edge (#533).
        .scrollEdgeEffectHidden(true)
        .frame(height: min(footerHeight, maximumHeight))
        .accessibilityIdentifier("companion-grant-footer-scroll")
        #if DEBUG
        // Classify capped vs naturally sized footers without adding another AX element.
        .accessibilityValue(String(format: "%.2f", maximumHeight),
                            isEnabled: ProcessInfo.processInfo.arguments.contains("--ui-testing-fast")
                                && ProcessInfo.processInfo.arguments.contains("--companion-ui-test-fit-metrics"))
        #endif
    }

    private struct FooterLayout: Layout {
        let maximumHeight: CGFloat

        private struct Sizes {
            let requests: CGSize
            let idealComposer: CGSize
            let placedComposer: CGSize
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let sizes = sizes(width: proposal.width, subviews: subviews) else { return .zero }
            return CGSize(width: proposal.width ?? max(sizes.requests.width, sizes.placedComposer.width),
                          height: sizes.requests.height + sizes.placedComposer.height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let sizes = sizes(width: bounds.width, subviews: subviews) else { return }
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(sizes.requests))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes.requests.height),
                             proposal: ProposedViewSize(sizes.placedComposer))
            // This noninteractive geometry carrier reports only the IDEAL height. It adds no
            // content size, creates no second editor and does not mutate state during layout.
            subviews[2].place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: 0, height: sizes.idealComposer.height))
        }

        private func sizes(width: CGFloat?, subviews: Subviews) -> Sizes? {
            guard subviews.count == 3 else {
                assertionFailure("Conversation footer requires requests, composer and its ideal-height carrier")
                return nil
            }
            let idealComposer = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let requests = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let budget = max(0, maximumHeight - requests.height)
            // Review/requests stay first. The editor gets the remainder and scrolls internally,
            // reserving its fixed action row, inset and one native line. Preserve natural growth
            // whenever it fits. Below that floor the composer refuses further compression;
            // the existing whole-footer scroll remains the fallback, with Review at its start.
            let placedComposer = idealComposer.height <= budget ? idealComposer
                : subviews[1].sizeThatFits(ProposedViewSize(width: width, height: budget))
            return Sizes(requests: requests, idealComposer: idealComposer, placedComposer: placedComposer)
        }
    }
}

/// Clubhouse grants stay above the composer; requests that cannot fit open in a full, scrollable review.
struct CompanionConversationGrantRequests: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    let maximumHeight: CGFloat
    @State private var cardsHeight: CGFloat?
    @State private var showsReview = false

    var body: some View {
        let requests = store.grantRequests(for: target)
        Group {
            if !requests.isEmpty {
                Group {
                    if let cardsHeight, cardsHeight <= maximumHeight {
                        cards(requests)
                    } else {
                        compactRow(requests)
                    }
                }
                .background(alignment: .top) {
                    // Measure the full content at the offered width, not a clipped scroll viewport.
                    cards(requests).hidden().accessibilityHidden(true).allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("companion-chat-grant-requests")
            }
        }
        .sheet(isPresented: $showsReview) {
            NavigationStack {
                ScrollView(.vertical) { cards(requests) }
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("companion-grant-review-scroll")
                    .navigationTitle("Review permission")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { showsReview = false }.companionToolbarClose()
                                .accessibilityIdentifier("companion-grant-review-close")
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .onChange(of: requests.isEmpty) { _, empty in
            if empty { showsReview = false }
        }
    }

    private func compactRow(_ requests: [CompanionGrantRequest]) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(requests[0].agentName).font(.caption.weight(.semibold))
                Text(requests.count == 1 ? requests[0].summary : "\(requests.count) Clubhouse permission requests")
                    .font(.caption)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { showsReview = true } label: {
                Text("Review")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Opens the complete Clubhouse permission requests and their decisions. Opening sends nothing.")
            .accessibilityIdentifier("companion-grant-review")
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .companionCardGlass(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func cards(_ requests: [CompanionGrantRequest]) -> some View {
        VStack(spacing: 12) {
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Label("Clubhouse permission request", systemImage: "hand.raised")
                        .font(.caption.weight(.semibold))
                    Text(request.agentName).font(.subheadline.weight(.semibold))
                    Text(request.summary).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    CompanionGrantRequestActions(request: request, store: store, showsOpenChat: false)
                }
                .padding(12)
                .companionCardGlass(RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .contain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}
