import SwiftUI

/// One bounded card in the existing requests slot, never a stack of pending transcript cards.
struct CompanionConversationPendingDecisions: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    let maximumHeight: CGFloat
    let showInChat: (String) -> Void
    @State private var selectedID: String?
    @State private var review: CompanionComposerApprovalReviewSelection?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let queue = CompanionPendingDecision.pending(in: store.conversation(for: target).items, at: context.date)
            if let decision = CompanionPendingDecision.selected(in: queue, id: selectedID),
               let index = queue.firstIndex(of: decision) {
                let presentation = store.decisionPresentation(decision, target: target)
                let compact = maximumHeight < 120 || dynamicTypeSize.isAccessibilitySize
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(decision.summary).font(.caption.weight(.semibold)).lineLimit(1)
                                .accessibilityIdentifier("companion-pinned-decision-summary")
                            if queue.count > 1 {
                                Text("\(index + 1) of \(queue.count)").font(.caption2.monospacedDigit())
                                    .accessibilityLabel("Request \(index + 1) of \(queue.count)")
                                    .accessibilityIdentifier("companion-pinned-decision-position")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if queue.count > 1 {
                            Button("Previous request", systemImage: "chevron.left") { selectedID = queue[index - 1].id }
                                .disabled(index == 0)
                                .accessibilityIdentifier("companion-pinned-decision-previous")
                            Button("Next request", systemImage: "chevron.right") { selectedID = queue[index + 1].id }
                                .disabled(index + 1 == queue.count)
                                .accessibilityIdentifier("companion-pinned-decision-next")
                        }
                        Button("Show in chat", systemImage: "text.bubble") { showInChat(decision.id) }
                            .accessibilityHint("Scrolls to the original request and its full context. Sends nothing.")
                            .accessibilityIdentifier("companion-decision-show-in-chat")
                        Button("Review request", systemImage: "hand.raised.fill") {
                            let requestID: String
                            switch decision {
                            case .approval(let approval): requestID = approval.id
                            case .question(let question): requestID = question.id
                            }
                            review = .init(target: target, approvalID: requestID, presentation: presentation)
                        }
                            .accessibilityLabel("Review \(isApproval(decision) ? "approval" : "question"): \(decision.summary)\(queue.count > 1 ? ", \(index + 1) of \(queue.count)" : "")")
                            .accessibilityHint("Opens the full request and decisions. Opening sends nothing.")
                            .accessibilityIdentifier("companion-review-approval")
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .buttonStyle(DecisionButtonStyle())
                    if decision.isSubmitting {
                        ProgressView("Sending decision…").font(.caption)
                    } else if !compact, case .approval(let approval) = decision {
                        CompanionApprovalActions(approval: approval, canRespond: canRespond(.approve),
                            canAllow: store.canApprove(approval, target: target),
                            persistentApprovals: store.canAnswerPersistentApprovals(target), compact: true) { option in
                            Task { await store.respond(presentation, option: option) }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .disabled(review != nil)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .companionCardGlass(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16).padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("companion-pinned-decision")
            }
        }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            CompanionComposerApprovalReviewSheet(store: store, target: target, selection: $review)
        }
        .onChange(of: store.host(for: target)?.controlEpoch) { _, _ in resetPresentation() }
        .onChange(of: store.conversation(for: target).sessionID) { _, _ in resetPresentation() }
        .onChange(of: pendingIDs, initial: true) { old, new in
            if let added = new.first(where: { !old.contains($0) }),
               let decision = CompanionPendingDecision.pending(in: store.conversation(for: target).items).first(where: { $0.id == added }) {
                AccessibilityNotification.Announcement("\(isApproval(decision) ? "Approval" : "Question") needed: \(decision.summary). Review above the message box.").post()
            }
        }
    }

    private var pendingIDs: [String] {
        CompanionPendingDecision.pending(in: store.conversation(for: target).items).map(\.id)
    }
    private func resetPresentation() { selectedID = nil; review = nil }
    private func isApproval(_ decision: CompanionPendingDecision) -> Bool {
        if case .approval = decision { return true }
        return false
    }
    private func canRespond(_ capability: CompanionCapabilities) -> Bool {
        store.canOperate(target) && store.agent(for: target)?.capabilities.contains(capability) == true
            && !store.pendingCommands.contains(target)
    }
    private struct DecisionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}

