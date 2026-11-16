import SwiftUI

/// One bounded card in the existing requests slot, never a stack of pending transcript cards.
struct CompanionConversationPendingDecisions: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    let maximumHeight: CGFloat
    let compactHeight: Bool
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
                let compact = compactHeight || maximumHeight < 120 || dynamicTypeSize.isAccessibilitySize
                VStack(alignment: .leading, spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            summaryAndPager(decision, queue: queue, index: index)
                                .fixedSize(horizontal: true, vertical: false)
                            decisionActions(decision, presentation: presentation, index: index, count: queue.count, compact: compact)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            summaryAndPager(decision, queue: queue, index: index)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    decisionActions(decision, presentation: presentation, index: index, count: queue.count, compact: compact)
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    decisionActions(decision, presentation: presentation, index: index, count: queue.count, compact: compact)
                                }
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
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
            if let added = old == new ? new.first : new.first(where: { !old.contains($0) }),
               let decision = CompanionPendingDecision.pending(in: store.conversation(for: target).items).first(where: { $0.id == added }) {
                AccessibilityNotification.Announcement("\(isApproval(decision) ? "Approval" : "Question") needed: \(decision.summary). Review above the message box.").post()
            }
        }
    }

    private func summaryAndPager(_ decision: CompanionPendingDecision, queue: [CompanionPendingDecision], index: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(decision.summary).font(.caption.weight(.semibold)).lineLimit(1)
                    .accessibilityIdentifier("companion-pinned-decision-summary")
                if queue.count > 1 {
                    Text("\(index + 1) of \(queue.count)").font(.caption2.monospacedDigit())
                        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                        .fixedSize()
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
        }
    }

    @ViewBuilder private func decisionActions(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, count: Int, compact: Bool) -> some View {
        Button(compact ? "Chat" : "Show in chat") { showInChat(decision.id) }
            .accessibilityLabel("Show in chat")
            .font(.subheadline).fixedSize(horizontal: true, vertical: false)
            .accessibilityHint("Scrolls to the original request and its full context. Sends nothing.")
            .accessibilityIdentifier("companion-decision-show-in-chat")
        Button(compact ? "Review" : "Review request") {
            let requestID: String
            switch decision {
            case .approval(let approval): requestID = approval.id
            case .question(let question): requestID = question.id
            }
            review = .init(target: target, approvalID: requestID, presentation: presentation)
        }
            .font(.subheadline).fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Review \(isApproval(decision) ? "approval" : "question"): \(decision.summary)\(count > 1 ? ", \(index + 1) of \(count)" : "")")
            .accessibilityHint("Opens the full request and decisions. Opening sends nothing.")
            .accessibilityIdentifier("companion-review-approval")
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

