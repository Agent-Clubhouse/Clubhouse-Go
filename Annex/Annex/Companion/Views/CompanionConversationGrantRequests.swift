import SwiftUI

extension EnvironmentValues {
    @Entry var companionComposerFitsGrantFooter = false
}

/// Footer measurements stay out of the conversation's observation boundary, just like draft edits.
struct CompanionConversationGrantFooter<Composer: View>: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    let maximumHeight: CGFloat
    @ViewBuilder var composer: Composer
    @State private var composerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        // Keep the composer mounted across fit/keyboard changes. When the keyboard leaves less
        // room than this footer, Review stays first and the rest remains reachable by scrolling.
        ScrollView(.vertical) {
            FooterLayout(maximumHeight: maximumHeight) {
                // Concrete slots survive the final request disappearing during footer removal.
                VStack(spacing: 0) {
                    CompanionConversationGrantRequests(store: store, target: target,
                        maximumHeight: max(0, maximumHeight - composerHeight) / 2)
                }
                VStack(spacing: 0) { composer }
                .environment(\.companionComposerFitsGrantFooter, true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .scrollDisabled(footerHeight <= maximumHeight)
        .scrollDismissesKeyboard(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(footerHeight, maximumHeight))
        .accessibilityIdentifier("companion-grant-footer-scroll")
    }

    private struct FooterLayout: Layout {
        let maximumHeight: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let sizes = sizes(width: proposal.width, subviews: subviews) else { return .zero }
            return CGSize(width: proposal.width ?? max(sizes.0.width, sizes.1.width),
                          height: sizes.0.height + sizes.1.height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let sizes = sizes(width: bounds.width, subviews: subviews) else { return }
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(sizes.0))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes.0.height),
                             proposal: ProposedViewSize(sizes.1))
        }

        private func sizes(width: CGFloat?, subviews: Subviews) -> (CGSize, CGSize)? {
            guard subviews.count == 2 else {
                assertionFailure("Grant footer requires its two concrete grant/composer containers")
                return nil
            }
            let grants = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let composer = subviews[1].sizeThatFits(ProposedViewSize(
                width: width, height: max(0, maximumHeight - grants.height)))
            return (grants, composer)
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
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { showsReview = false }
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
