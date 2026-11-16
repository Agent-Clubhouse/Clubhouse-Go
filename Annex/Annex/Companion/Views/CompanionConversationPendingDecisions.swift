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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let queue = CompanionPendingDecision.pending(in: store.conversation(for: target).items, at: context.date)
            if let decision = CompanionPendingDecision.selected(in: queue, id: selectedID),
               let index = queue.firstIndex(of: decision) {
                let presentation = store.decisionPresentation(decision, target: target)
                Group {
                    if usesSingleRow {
                        HStack(spacing: 8) {
                            identity(decision, presentation: presentation, index: index, queue: queue)
                            actions(decision, presentation: presentation, index: index, count: queue.count).fixedSize()
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                identity(decision, presentation: presentation, index: index, queue: queue)
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 0)
                                actions(decision, presentation: presentation, index: index, count: queue.count).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: usesTightAccessibilityRows ? 0 : 8) {
                                identity(decision, presentation: presentation, index: index, queue: queue)
                                HStack { Spacer(minLength: 0); actions(decision, presentation: presentation, index: index, count: queue.count) }
                            }
                        }
                    }
                }
                .highPriorityGesture(selectionGesture(queue: queue, index: index))
                .accessibilityAction(named: "Previous request") { select(-1, queue: queue, index: index) }
                .accessibilityAction(named: "Next request") { select(1, queue: queue, index: index) }
                .disabled(review != nil)
                .padding(.horizontal, 12).padding(.vertical, usesTightAccessibilityRows ? 1 : 4)
                .companionCardGlass(RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16).padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("companion-pinned-decision")
                .accessibilityValue(isCompactPresentation ? "Compact request controls" : "Expanded request controls")
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

    private func identity(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, queue: [CompanionPendingDecision]) -> some View {
        let count = queue.count
        let kind: String
        switch decision {
        case .approval(let approval): kind = approval.toolName
        case .question: kind = "Question"
        }
        let subtitle = "\(index + 1) of \(count) waiting · \(kind)"
        return Menu {
            Button("Review request") { openReview(decision, presentation: presentation) }
                .accessibilityLabel("Review \(isApproval(decision) ? "approval" : "question"): \(decision.summary), \(index + 1) of \(count)")
                .accessibilityIdentifier("companion-decision-review-menu")
        } label: {
            VStack(alignment: .leading, spacing: usesSingleRow ? 0 : 2) {
                Text(decision.summary).font((usesSingleRow ? Font.caption : .subheadline).weight(.semibold))
                    .lineLimit(usesSingleRow ? 1 : 2)
                if !usesSingleRow && !hasCompactRoom {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(selectionGesture(queue: queue, index: index)
                .exclusively(before: TapGesture().onEnded { _ in showInChat(decision.id) }))
        } primaryAction: {
            showInChat(decision.id)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityAction { showInChat(decision.id) }
        .accessibilityLabel(decision.summary)
        .accessibilityValue(subtitle)
        .accessibilityHint("Scrolls to the original request and its full context. Sends nothing. Swipe left or right for another request; use Actions for full review.")
        .accessibilityIdentifier("companion-decision-show-in-chat")
        .accessibilityAction(named: "Review request") { openReview(decision, presentation: presentation) }
    }

    @ViewBuilder private func actions(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, count: Int) -> some View {
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
                if isCompactPresentation {
                    // Preserve #522's user-approved keyboard-up contract: decisions live in Review.
                    reviewButton(decision, presentation: presentation, index: index, count: count)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { approvalActions(approval, presentation: presentation) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .trailing, spacing: 8) { approvalActions(approval, presentation: presentation) }
                    }
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

    private func reviewButton(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, count: Int) -> some View {
        Button("Review") { openReview(decision, presentation: presentation) }
            .buttonStyle(DecisionActionStyle(primary: false))
            .accessibilityLabel("Review approval: \(decision.summary)\(count > 1 ? ", \(index + 1) of \(count)" : "")")
            .accessibilityHint("Opens the full request and decisions. Opening sends nothing.")
            .accessibilityIdentifier("companion-review-approval")
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
    private func selectionGesture(queue: [CompanionPendingDecision], index: Int) -> some Gesture {
        DragGesture(minimumDistance: 24).onEnded { gesture in
            guard abs(gesture.translation.width) > max(44, abs(gesture.translation.height)) else { return }
            // Both hit surfaces resolve from the captured index, so one drag cannot skip a request.
            select(gesture.translation.width < 0 ? 1 : -1, queue: queue, index: index)
        }
    }

    private var pendingIDs: [String] {
        CompanionPendingDecision.pending(in: store.conversation(for: target).items).map(\.id)
    }
    private var isCompactPresentation: Bool {
        hasCompactRoom || dynamicTypeSize.isAccessibilitySize
    }
    // Use the existing compact-room policy at every text size. The complete subtitle
    // remains the title's AX value when the keyboard leaves no room for visible metadata.
    private var hasCompactRoom: Bool { compactHeight || maximumHeight < 120 }
    // Keep both full-width AX rows and their text styles when the keyboard limits room.
    // Regular-height only: standard text, roomy AX and compact-height layouts retain their spacing.
    private var usesTightAccessibilityRows: Bool {
        hasCompactRoom && dynamicTypeSize.isAccessibilitySize && verticalSizeClass == .regular
    }
    private var usesSingleRow: Bool {
        verticalSizeClass == .compact || (isCompactPresentation && !dynamicTypeSize.isAccessibilitySize)
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
