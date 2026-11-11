import SwiftUI

/// Clubhouse grants stay above the composer, separate from CLI approvals. Long requests scroll without truncating arguments.
struct CompanionConversationGrantRequests: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    let maximumHeight: CGFloat

    var body: some View {
        let requests = store.grantRequests(for: target)
        if !requests.isEmpty {
            ViewThatFits(in: .vertical) {
                cards(requests)
                ScrollView(.vertical) { cards(requests) }
                    .scrollDismissesKeyboard(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("companion-chat-grant-requests-scroll")
            }
            .frame(maxHeight: max(0, maximumHeight))
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("companion-chat-grant-requests")
        }
    }

    private func cards(_ requests: [CompanionGrantRequest]) -> some View {
        VStack(spacing: 12) {
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 8) {
                    Label("Clubhouse permission request", systemImage: "hand.raised")
                        .font(.caption.weight(.semibold))
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
