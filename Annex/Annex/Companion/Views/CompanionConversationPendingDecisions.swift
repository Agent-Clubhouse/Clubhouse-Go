import SwiftUI

/// One bounded card in the existing requests slot, never a stack of pending transcript cards.
struct CompanionConversationPendingDecisions: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    let maximumHeight: CGFloat
    let compactHeight: Bool
    let showInChat: (String) -> Void
    @State private var expiryBoundary = Date.distantPast
    @State private var selectedID: String?
    @State private var review: CompanionComposerApprovalReviewSelection?
    /// The full rows' height at the offered width, measured while the Review-only fallback could apply.
    @State private var naturalRowsHeight: CGFloat = 0
    @State private var keyboardVisible = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Native Menu identity/content must not be rebuilt by a per-second expiry tick.
        let queue = CompanionPendingDecision.pending(in: store.conversation(for: target).items, at: max(.now, expiryBoundary))
        let nextDeadline = queue.compactMap { decision -> Date? in
            guard case .approval(let approval) = decision, approval.resolution == .pending else { return nil }
            return approval.deadline
        }.min()
        // Keep the task and sheet host mounted when the final pending request leaves the queue.
        return VStack(spacing: 0) {
            if let decision = CompanionPendingDecision.selected(in: queue, id: selectedID),
               let index = queue.firstIndex(of: decision) {
                let presentation = store.decisionPresentation(decision, target: target)
                Group {
                    if usesReviewOnlyRow {
                        reviewOnlyRow(decision, presentation: presentation, index: index, queue: queue)
                    } else {
                        rows(decision, presentation: presentation, index: index, queue: queue)
                    }
                }
                .background(alignment: .top) {
                    // Measure the full rows even while collapsed, so the fallback follows the actual room.
                    if measuresNaturalRows {
                        rows(decision, presentation: presentation, index: index, queue: queue)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden().accessibilityHidden(true).allowsHitTesting(false)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalRowsHeight = $0 }
                    }
                }
                .highPriorityGesture(selectionGesture(queue: queue, index: index))
                .accessibilityAction(named: "Previous request") { select(-1, queue: queue, index: index) }
                .accessibilityAction(named: "Next request") { select(1, queue: queue, index: index) }
                .disabled(review != nil)
                .padding(.horizontal, 12).padding(.vertical, usesTightAccessibilityRows ? 1 : 4)
                .companionCardGlass(RoundedRectangle(cornerRadius: 20))
                // When AX rows are tight the footer can outgrow the room above the keyboard and scroll from its top,
                // pushing the composer's own bottom margin under the keyboard. The composer's padding already
                // separates the card, so return this outer inset to the composer (0pt clearance on iPhone 17, iOS 26.5).
                .padding(.horizontal, 16).padding(.vertical, usesTightAccessibilityRows ? 0 : 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("companion-pinned-decision")
                .accessibilityValue(usesReviewOnlyRow ? "Review-only request controls"
                    : isCompactPresentation ? "Compact request controls" : "Expanded request controls")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if !keyboardVisible { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardVisible { keyboardVisible = false }
        }
        .task(id: nextDeadline) {
            guard let nextDeadline else { return }
            let delay = nextDeadline.timeIntervalSinceNow
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            // One update at the next actual expiry; no per-second polling or retained task handle.
            expiryBoundary = max(.now, nextDeadline)
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

    @ViewBuilder private func rows(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, queue: [CompanionPendingDecision]) -> some View {
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

    /// #543: when even the tight AX rows cannot fit above the keyboard (iPhone SE), keep every composer action
    /// visible by showing one 44pt Review control. Its label carries the full request; position and tool are its value.
    @ViewBuilder private func reviewOnlyRow(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, queue: [CompanionPendingDecision]) -> some View {
        let count = queue.count
        let position = count > 1 ? ", \(index + 1) of \(count)" : ""
        let subtitle = "\(index + 1) of \(count) waiting · \(decisionTool(decision))"
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if decision.isSubmitting {
                ProgressView().frame(minWidth: 44, minHeight: 44).accessibilityLabel("Sending decision…")
            } else if isApproval(decision) {
                Button { openReview(decision, presentation: presentation) } label: {
                    Image(systemName: "checklist").font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(DecisionActionStyle(primary: false))
                .accessibilityLabel("Review approval: \(decision.summary)\(position)")
                .accessibilityValue(subtitle)
                .accessibilityHint("Opens the full request and decisions. Opening sends nothing.")
                .accessibilityInputLabels(["Review"])
                .accessibilityIdentifier("companion-review-approval")
            } else {
                Button { openReview(decision, presentation: presentation) } label: {
                    Image(systemName: "questionmark.bubble").font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(DecisionActionStyle(primary: true))
                .accessibilityLabel("Answer question: \(decision.summary)\(position)")
                .accessibilityValue(subtitle)
                .accessibilityHint("Opens the full question. Opening sends nothing.")
                .accessibilityInputLabels(["Answer"])
                .accessibilityIdentifier("companion-decision-answer")
            }
        }
    }

    private func decisionTool(_ decision: CompanionPendingDecision) -> String {
        if case .approval(let approval) = decision { return approval.toolName }
        return "Question"
    }

    private func identity(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation, index: Int, queue: [CompanionPendingDecision]) -> some View {
        let count = queue.count
        let kind: String
        switch decision {
        case .approval(let approval): kind = approval.toolName
        case .question: kind = "Question"
        }
        let subtitle = "\(index + 1) of \(count) waiting · \(kind)"
        return CompanionPendingDecisionTitle(key: .init(storeIdentity: ObjectIdentifier(store), presentation: presentation,
            queue: queue, index: index, title: decision.summary, subtitle: subtitle,
            reviewLabel: "Review \(isApproval(decision) ? "approval" : "question"): \(decision.summary), \(index + 1) of \(count)",
            hint: "Scrolls to the original request and its full context. Sends nothing. Swipe left or right for another request; use Actions for full review.",
            reviewActionLabel: "Review request", singleRow: usesSingleRow, showsSubtitle: !usesSingleRow && !hasCompactRoom,
            compact: isCompactPresentation, dynamicTypeSize: dynamicTypeSize, colorScheme: colorScheme),
            showInChat: {
                guard Self.currentSelection(presentation, in: store, selectedID: selectedID) == decision else { return }
                showInChat(decision.id)
            }, openReview: { openReview(decision, presentation: presentation) },
            selectionGesture: selectionGesture(queue: queue, index: index))
            .equatable()
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
            Button("Deny", role: .destructive) { Task { await respond(decision, presentation: presentation, option: deny) } }
                .buttonStyle(DecisionActionStyle(primary: false))
                .disabled(!canRespond(.approve))
        }
        if let allow = approval.options.first(where: { $0.kind == .allowOnce }) {
            Button("Allow once") { Task { await respond(decision, presentation: presentation, option: allow) } }
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

    /// Resolve at activation, not menu-open: expiry, replacement and selection can change while it is open.
    static func currentSelection(_ presentation: CompanionDecisionPresentation, in store: CompanionStore,
                                 selectedID: String?) -> CompanionPendingDecision? {
        guard let current = store.currentDecision(for: presentation),
              CompanionPendingDecision.selected(in: CompanionPendingDecision.pending(in: store.conversation(for: presentation.target).items),
                                                id: selectedID) == current else { return nil }
        return current
    }
    private func respond(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation,
                         option: CompanionApprovalOption) async {
        guard Self.currentSelection(presentation, in: store, selectedID: selectedID) == decision,
              canRespond(.approve), case .approval(let approval) = decision,
              !option.allows || store.canApprove(approval, target: target) else { return }
        // Store keeps the existing option/capability/submitting/confirmation and expiry guards.
        await store.respond(presentation, option: option)
    }
    private func openReview(_ decision: CompanionPendingDecision, presentation: CompanionDecisionPresentation) {
        guard Self.currentSelection(presentation, in: store, selectedID: selectedID) == decision else { return }
        let requestID: String
        switch decision {
        case .approval(let approval): requestID = approval.id
        case .question(let question): requestID = question.id
        }
        review = .init(target: target, approvalID: requestID, presentation: presentation)
    }
    private func select(_ direction: Int, queue: [CompanionPendingDecision], index: Int) {
        let currentQueue = CompanionPendingDecision.pending(in: store.conversation(for: target).items)
        guard currentQueue == queue,
              CompanionPendingDecision.selected(in: currentQueue, id: selectedID)?.id == queue[index].id else { return }
        selectedID = currentQueue[max(0, min(currentQueue.count - 1, index + direction))].id
    }
    private func selectionGesture(queue: [CompanionPendingDecision], index: Int) -> AnyGesture<DragGesture.Value> {
        AnyGesture(DragGesture(minimumDistance: 24).onEnded { gesture in
            guard abs(gesture.translation.width) > max(44, abs(gesture.translation.height)) else { return }
            // Both hit surfaces resolve from the captured index, so one drag cannot skip a request.
            select(gesture.translation.width < 0 ? 1 : -1, queue: queue, index: index)
        })
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
    /// Only tight AX rows with the keyboard up can need the fallback; elsewhere nothing is measured.
    private var measuresNaturalRows: Bool { usesTightAccessibilityRows && keyboardVisible }
    /// The full rows (plus the tight 1pt insets) exceed the room the footer offers this tray.
    private var usesReviewOnlyRow: Bool { measuresNaturalRows && naturalRowsHeight + 2 > maximumHeight }
    private var usesSingleRow: Bool {
        verticalSizeClass == .compact || (isCompactPresentation && !dynamicTypeSize.isAccessibilitySize)
    }
    private func resetPresentation() { selectedID = nil; review = nil }
    #if DEBUG
    /// Seed only the initial value for a mounted sheet-lifecycle test; no callback or owner is retained.
    func withInitialReviewForTesting(_ selection: CompanionComposerApprovalReviewSelection) -> Self {
        var tray = self
        tray._review = State(initialValue: selection)
        return tray
    }
    #endif
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

/// Like ChatControlsBar, transcript-only updates must not rebuild an open native menu.
/// Every rendered/AX input and presentation identity participates; callbacks revalidate live state.
private struct CompanionPendingDecisionTitle: View, Equatable {
    struct Key: Equatable {
        let storeIdentity: ObjectIdentifier
        let presentation: CompanionDecisionPresentation
        let queue: [CompanionPendingDecision]
        let index: Int
        let title: String
        let subtitle: String
        let reviewLabel: String
        let hint: String
        let reviewActionLabel: String
        let singleRow: Bool
        let showsSubtitle: Bool
        let compact: Bool
        let dynamicTypeSize: DynamicTypeSize
        let colorScheme: ColorScheme
    }
    let key: Key
    let showInChat: @MainActor () -> Void
    let openReview: @MainActor () -> Void
    let selectionGesture: AnyGesture<DragGesture.Value>

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

    var body: some View {
        Menu {
            Button(key.reviewActionLabel, action: openReview)
                .accessibilityLabel(key.reviewLabel)
                .accessibilityIdentifier("companion-decision-review-menu")
        } label: {
            VStack(alignment: .leading, spacing: key.singleRow ? 0 : 2) {
                Text(key.title).font((key.singleRow ? Font.caption : .subheadline).weight(.semibold))
                    .lineLimit(key.singleRow ? 1 : 2)
                if key.showsSubtitle {
                    Text(key.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(selectionGesture.exclusively(before: TapGesture().onEnded { _ in showInChat() }))
        } primaryAction: {
            showInChat()
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityAction { showInChat() }
        .accessibilityLabel(key.title)
        .accessibilityValue(key.subtitle)
        .accessibilityHint(key.hint)
        .accessibilityIdentifier("companion-decision-show-in-chat")
        .accessibilityAction(named: key.reviewActionLabel) { openReview() }
    }
}
