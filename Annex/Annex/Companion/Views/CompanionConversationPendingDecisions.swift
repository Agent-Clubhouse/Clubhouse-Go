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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let queue = CompanionPendingDecision.pending(in: store.conversation(for: target).items, at: context.date)
            if let decision = CompanionPendingDecision.selected(in: queue, id: selectedID),
               let index = queue.firstIndex(of: decision) {
                let presentation = store.decisionPresentation(decision, target: target)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        identity(decision, presentation: presentation, index: index, count: queue.count)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        actions(decision, presentation: presentation).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        identity(decision, presentation: presentation, index: index, count: queue.count)
                        HStack { Spacer(minLength: 0); actions(decision, presentation: presentation) }
                    }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
                    guard abs(gesture.translation.width) > max(44, abs(gesture.translation.height)) else { return }
                    select(gesture.translation.width < 0 ? 1 : -1, queue: queue, index: index)
                })
                .accessibilityAction(named: "Previous request") { select(-1, queue: queue, index: index) }
                .accessibilityAction(named: "Next request") { select(1, queue: queue, index: index) }
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

    private func identity(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, count: Int) -> some View {
        let kind: String
        switch decision {
        case .approval(let approval): kind = approval.toolName
        case .question: kind = "Question"
        }
        let subtitle = "\(index + 1) of \(count) waiting · \(kind)"
        return Button { showInChat(decision.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(decision.summary).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        .contextMenu {
            Button("Review request") { openReview(decision, presentation: presentation) }
                .accessibilityLabel("Review \(isApproval(decision) ? "approval" : "question"): \(decision.summary), \(index + 1) of \(count)")
                .accessibilityIdentifier("companion-review-approval")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(decision.summary)
        .accessibilityValue(subtitle)
        .accessibilityHint("Scrolls to the original request and its full context. Sends nothing. Swipe left or right for another request; use Actions for full review.")
        .accessibilityIdentifier("companion-decision-show-in-chat")
        .accessibilityAction(named: "Review request") { openReview(decision, presentation: presentation) }
    }

    @ViewBuilder private func actions(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation) -> some View {
        if decision.isSubmitting {
            ProgressView("Sending decision…").font(.caption)
        } else {
            switch decision {
            case .question:
                Button("Answer") { openReview(decision, presentation: presentation) }
                    .buttonStyle(DecisionActionStyle(primary: true))
                    .accessibilityHint("Opens the full question. Opening sends nothing.")
                    .accessibilityIdentifier("companion-decision-answer")
            case .approval(let approval):
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { approvalActions(approval, presentation: presentation) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .trailing, spacing: 8) { approvalActions(approval, presentation: presentation) }
                }
            }
        }
    }

    @ViewBuilder private func approvalActions(_ approval: CompanionApproval, presentation: CompanionDecisionPresentation) -> some View {
        let decision = CompanionPendingDecision.approval(approval)
        // Exact one-off kinds only. Broader/custom choices remain in full review,
        // where the existing capability checks and confirmations still own them.
        if let deny = approval.options.first(where: { $0.kind == .rejectOnce }) {
            Button("Deny", role: .destructive) { Task { await store.respond(presentation, option: deny) } }
                .buttonStyle(DecisionActionStyle(primary: false))
                .disabled(!canRespond(.approve))
        }
        if let allow = approval.options.first(where: { $0.kind == .allowOnce }) {
            Button("Allow once") { Task { await store.respond(presentation, option: allow) } }
                .buttonStyle(DecisionActionStyle(primary: true))
                .disabled(!canRespond(.approve) || !store.canApprove(approval, target: target))
        } else {
            Button("Review") { openReview(decision, presentation: presentation) }
                .buttonStyle(DecisionActionStyle(primary: false))
                .accessibilityLabel("Review approval: \(decision.summary)")
                .accessibilityHint("Opens the full request and decisions. Opening sends nothing.")
                .accessibilityIdentifier("companion-review-approval")
        }
    }

    private func openReview(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation) {
        let requestID: String
        switch decision {
        case .approval(let approval): requestID = approval.id
        case .question(let question): requestID = question.id
        }
        review = .init(target: target, approvalID: requestID, presentation: presentation)
    }
    private func select(_ direction: Int, queue: [CompanionPendingDecision], index: Int) {
        selectedID = queue[max(0, min(queue.count - 1, index + direction))].id
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
    private struct DecisionActionStyle: ButtonStyle {
        let primary: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.companionPalette) private var palette
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(Color(isEnabled ? (primary ? palette.onTint : palette.label) : palette.secondaryLabel))
                .background(Color(primary && isEnabled ? palette.tint : palette.fill), in: Capsule())
                .contentShape(Capsule()).opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}
