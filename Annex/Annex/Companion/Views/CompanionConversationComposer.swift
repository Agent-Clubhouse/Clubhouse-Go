import SwiftUI
import UIKit
import ClubhouseTransport

extension EnvironmentValues {
    @Entry var companionComposerCompactHeight = false
}

/// A retained tab's editing bookmark. Plain values only; never UIKit or SwiftUI handles.
@MainActor final class CompanionComposerMemory {
    nonisolated deinit {}
    var selection: CompanionComposerSelection?
    var selectionDraft: String?
    var slashHighlight = 0
    var slashDismissedAt: Int?
}

/// Input observation and layout stop at this subtree. The transcript never reads the draft or slash word.
struct CompanionConversationComposer: View {
    @Bindable var store: CompanionStore
    let agent: CompanionAgent
    let memory: CompanionComposerMemory
    let focusRequests: Int
    @FocusState private var composerFocused: Bool
    @State private var composerSelection: TextSelection?
    @State private var slashHighlight = 0
    @State private var slashDismissedAt: Int?
    @Binding var confirmCancel: Bool
    let dismissals: Int
    @State private var showRefreshing = false
    @State private var pendingLevel: CompanionPermissionLevel?
    @State private var modelSettings: CompanionAgentSettings?
    @State private var savedModelError: String?
    @State private var loadedModelSettingsKey: [String]?
    @State private var modelSettingsRetry = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionComposerFitsGrantFooter) private var fitsGrantFooter
    @Environment(\.companionComposerCompactHeight) private var compactHeight
    @Environment(\.companionPalette) private var palette
    /// A generous estimate of the composer's line height, so one line can be centred in the send row at every text size.
    @ScaledMetric(relativeTo: .body) private var composerLineHeight: CGFloat = 24

    private var target: CompanionTarget { agent.id }
    private var conversation: CompanionConversation { store.conversation(for: target) }
    private var connection: CompanionConnection { store.host(for: target)?.connection ?? .offline }
    private var isAsleep: Bool { agent.capabilities.contains(.wake) && (agent.status == .sleeping || agent.status == .stopped) }
    private var attachmentLimits: CompanionAttachmentLimits? { store.attachmentLimits(for: target) }
    /// Text, images, or both.
    private var hasMessage: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(store.attachmentDrafts[target] ?? []).isEmpty
    }
    private var sendEnabled: Bool { store.canSend(target) && hasMessage }
    private var draft: Binding<String> {
        Binding(get: { store.drafts[target] ?? "" }, set: { store.drafts[target] = $0 })
    }
    /// Text edits, including undo/redo, always preserve their literal text. Return completion is an input action.
    private var composerText: Binding<String> {
        Binding(get: { draft.wrappedValue }, set: { text in
            // SwiftUI can invoke the setter twice with the same value for one native edit.
            if text != draft.wrappedValue { CompanionChatPerformance.edit(target: target, messageCount: conversation.items.count) }
            #if DEBUG
            if CompanionImagePaste.tracesPreviewTyping {
                print("COMPOSER_BINDING length=\(text.utf16.count) focused=\(composerFocused)")
            }
            #endif
            draft.wrappedValue = text
        })
    }
    var body: some View {
        composerLayout {
            if isAsleep {
                VStack(alignment: .leading, spacing: 8) {
                    Label(agent.hasSession == false ? "\(agent.name) is sleeping. Start a new session, or send a message to start one."
                                                     : "\(agent.name) is sleeping. Wake it, or send a message to resume.", systemImage: "moon.zzz")
                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { CompanionWakeButtons(store: store, target: target) }
                        VStack(alignment: .leading, spacing: 8) { CompanionWakeButtons(store: store, target: target) }
                    }
                }
                .padding(12)
                .background(Color(palette.card), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityElement(children: .contain)
            }
            CompanionAttachmentStrip(store: store, target: target)
            if !slashMatches.isEmpty {
                CompanionSlashMenuView(commands: slashMatches, highlighted: min(slashHighlight, slashMatches.count - 1), pick: pickSlashCommand)
                    .layoutValue(key: CompanionComposerFlexibleHeight.self, value: true)
            }
            HStack(alignment: .bottom, spacing: 4) {
                inputRowLayout {
                    HStack(alignment: .bottom, spacing: 6) {
                        // The theme's secondary label keeps the prompt at 4.5:1 on the composer card; the system placeholder
                        // colour followed a light trait on the dark card (1.13:1).
                        TextField(composerPlaceholder, text: composerText, selection: $composerSelection,
                                  prompt: Text(composerPlaceholder).foregroundStyle(Color(palette.secondaryLabel)), axis: .vertical)
                            // Leave room for attachments and actions above a narrow keyboard. The native field
                            // scrolls to the caret; every line remains in the draft at its normal text size.
                            .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? (composerFocused ? 1 : 3) : 8))
                            // Size to the text view's own line height. Otherwise one line is laid out ~1.7pt shorter
                            // than its content (20.33 vs 22pt at Large), and the text bobs as it scrolls to the caret.
                            // A grant footer instead offers a bounded height so Review and the actions stay visible.
                            .fixedSize(horizontal: false, vertical: !fitsGrantFooter)
                            .padding(.vertical, compactHeight ? 6 : 12).padding(.horizontal, 16)
                            // The draft keeps the full text row as it grows; actions stay in their own row below.
                            .frame(minHeight: composerRowHeight)
                            .focused($composerFocused)
                            .accessibilityLabel(agent.status == .working ? (agent.capabilities.contains(.steer) ? "Steering message" : "Queued message") : "Message")
                            .accessibilityHint("Runs on your desktop. With a hardware keyboard, Return sends, Shift Return inserts a new line, and Command Return also sends.")
                            .accessibilityIdentifier("companion-composer")
                            // Pasted or dropped images join the attachments; text pastes as usual. Added after the
                            // accessibility modifiers so the hook doesn't appear as a second composer element.
                            .background(composerInputHook.accessibilityHidden(true))
                            .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down, action: slashKey)
                    }
                    .frame(maxWidth: .infinity)
                    HStack(alignment: .bottom, spacing: 6) {
                        chatControls.frame(height: actionRowHeight)
                        if let limits = attachmentLimits {
                            CompanionAttachButton(store: store, target: target, limits: limits).frame(height: actionRowHeight)
                        }
                        Spacer(minLength: 0)
                        HStack(alignment: .bottom, spacing: dynamicTypeSize.isAccessibilitySize ? 0 : 6) {
                            if agent.status == .working {
                                // Interrupt remains a separate confirmed action beside Send, never a replacement for it.
                                Button { confirmCancel = true } label: {
                                    Image(systemName: "stop.fill").font(.system(size: 18, weight: .semibold))
                                }
                                .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
                                .tint(Color(palette.warning))
                                .foregroundStyle(Color(CompanionPalette.glyph(on: palette.warning)))
                                .frame(minWidth: 44, maxWidth: dynamicTypeSize.isAccessibilitySize ? 44 : nil, minHeight: 44)
                                .contentShape(.circle)
                                .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel) || store.pendingCommands.contains(target))
                                .accessibilityLabel("Interrupt")
                                .accessibilityHint("Asks before interrupting the current turn. Keeps your draft.")
                                .accessibilityIdentifier("companion-interrupt")
                                .frame(height: actionRowHeight)
                            }
                            Button(action: sendMessage) {
                                Image(systemName: agent.status == .working ? "arrow.turn.up.right" : "arrow.up")
                                    .font(.system(size: 20, weight: .bold))
                            }
                            .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
                            // Keep the regular-size glass circle inside the field, with a full-size interaction target.
                            .frame(minWidth: 44, maxWidth: dynamicTypeSize.isAccessibilitySize ? 44 : nil, minHeight: 44)
                            .contentShape(.circle)
                            .disabled(!sendEnabled)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityLabel(agent.status == .working ? (agent.capabilities.contains(.steer) ? "Send steering message" : "Queue message") : "Send message")
                            .accessibilityHint(conversation.isLoading ? "Refreshing the conversation. You can send in a moment." : sendOutcomeHint)
                            .accessibilityIdentifier("companion-send")
                            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 0 : 6)
                            .frame(height: actionRowHeight)
                        }
                        keyboardDismissButton
                    }
                }
                // Glass behind the draft over the theme card, as in the header. Wrapping the whole draft and action row
                // in glass let it adapt to light in dark mode, taking the field and keyboard with it (text at 2:1).
                .companionCardGlass(RoundedRectangle(cornerRadius: 24))
                // Images dragged in on iPad join the attachments like pasted ones.
                .onDrop(of: CompanionPastedImages.acceptedTypes, isTargeted: nil) { providers in
                    Task { _ = await pasteImages(providers) }
                    return true
                }
            }
            composerCaption
        }
        // Large-text glass controls extend beyond the 44pt row; retain their keyboard clearance.
        .padding(.horizontal, 16).padding(.vertical, compactHeight && !dynamicTypeSize.isAccessibilitySize ? 4 : 10)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion-composer-region")
        .confirmationDialog(pendingLevel.map { "Switch to \($0.label)?" } ?? "", isPresented: Binding(get: { pendingLevel != nil }, set: { if !$0 { pendingLevel = nil } }),
                            titleVisibility: .visible, presenting: pendingLevel) { level in
            Button("Switch to \(level.label)") { Task { await store.setLevel(level, target: target) } }
        } message: { level in
            Text(level == .fullAccess
                 ? "\(agent.name) will edit files and run commands without asking you first."
                 : "\(agent.name) will decide for itself what needs your approval.")
        }
        .onAppear {
            #if DEBUG
            CompanionComposerFocusProbe.record?(.appeared, target, composerFocused)
            #endif
            slashHighlight = memory.slashHighlight
            slashDismissedAt = memory.slashDismissedAt
            // A restore/send/external clear can change text while this subtree is unmounted.
            // Restore a selection only for the exact saved draft; otherwise let the input choose its caret.
            if memory.selectionDraft == draft.wrappedValue, let selection = memory.selection {
                let range = selection.range(in: draft.wrappedValue)
                composerSelection = range.isEmpty ? TextSelection(insertionPoint: range.lowerBound) : TextSelection(range: range)
            } else { composerSelection = nil }
            memory.selectionDraft = nil
        }
        .onDisappear {
            #if DEBUG
            CompanionComposerFocusProbe.record?(.disappeared, target, composerFocused)
            #endif
            memory.selection = CompanionComposerSelection.capture(selectedRange, in: draft.wrappedValue)
            memory.selectionDraft = memory.selection == nil ? nil : draft.wrappedValue
            memory.slashHighlight = slashHighlight
            memory.slashDismissedAt = slashDismissedAt
            composerFocused = false
        }
        #if DEBUG
        .onChange(of: composerFocused) { _, focused in
            CompanionComposerFocusProbe.record?(.focusChanged, target, focused)
        }
        #endif
        .onChange(of: focusRequests) { _, _ in
            #if DEBUG
            CompanionComposerFocusProbe.record?(.focusRequested, target, composerFocused)
            #endif
            composerFocused = true
        }
        .onChange(of: dismissals) { _, _ in
            #if DEBUG
            CompanionComposerFocusProbe.record?(.dismissalRequested, target, composerFocused)
            #endif
            // The parent has already cleared focus. Use the caret independently to keep this word closed.
            if let token = caretSlashToken, let commands = agent.slashCommands,
               !CompanionSlashMenu.matches(commands, text: draft.wrappedValue, token: token).isEmpty {
                slashDismissedAt = token.start
            }
            composerFocused = false
        }
        .onChange(of: caretSlashToken?.start) { _, start in if start != slashDismissedAt { slashDismissedAt = nil } }
        .onChange(of: slashMatches.map(\.name)) { slashHighlight = 0 }
        // Quick refreshes finish before the indicator would appear, so they don't flash.
        .task(id: conversation.isLoading) {
            guard conversation.isLoading else { showRefreshing = false; return }
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            showRefreshing = true
        }
        .layoutValue(key: CompanionComposerFlexibleHeight.self, value: !slashMatches.isEmpty || fitsGrantFooter)
    }

    /// Keep the full-width draft above one action row at every text size and focus state.
    /// Retain the field subtree; typing does not select a different layout or control placement.
    private var inputRowLayout: AnyLayout {
        AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
    }

    private var composerLayout: AnyLayout {
        slashMatches.isEmpty
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: compactHeight ? 8 : 10))
            : AnyLayout(CompanionComposerLayout(spacing: compactHeight ? 8 : 10))
    }

    /// Icon-only actions keep a bounded glyph and a full target; the editor and textual labels scale normally.
    private var actionRowHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 44 : composerRowHeight }

    @ViewBuilder private var keyboardDismissButton: some View {
        if composerFocused && showsKeyboardDismissButton {
            Button(action: dismissKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 20))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Keyboard")
            .accessibilityIdentifier("companion-dismiss-keyboard")
            .frame(height: actionRowHeight)
        }
    }

    /// Keep configuration collapsed while reading as well as editing, independent of the running turn.
    @ViewBuilder private var chatControls: some View {
        if let controls = agent.chatControls, !isAsleep {
            let hasCurrentSettings = loadedModelSettingsKey == modelSettingsKey
            CompanionChatControlsBar(agentName: agent.name, controls: controls, enabled: store.canChangeChatControls(target),
                setLevel: { level in Task { await store.setLevel(level, target: target) } },
                setModel: { model, effort in Task { await store.setModel(model, effort: effort, target: target) } },
                compact: true, requestLevel: { pendingLevel = $0 },
                modelDifference: agent.modelDifference(from: hasCurrentSettings ? modelSettings : nil),
                savedModelError: hasCurrentSettings ? savedModelError : nil,
                retrySavedModel: { modelSettingsRetry += 1 })
                .equatable()
                .task(id: modelSettingsKey) { await loadModelSettings() }
        }
    }

    private var canReadModelSettings: Bool {
        guard store.canEditSettings(target), connection.canOperate, agent.isRunning, agent.isSleepingOnDesktop != true, !isAsleep,
              let controls = agent.chatControls, controls.showsModelMenu, let model = controls.model,
              !model.isEmpty,
              controls.startModel?.isEmpty == false || (model != "default" && controls.models.contains(where: { $0.id == model })) else { return false }
        return true
    }

    private var modelSettingsKey: [String] {
        [target.hostID, target.projectID, target.agentID, conversation.sessionID ?? "", agent.chatControls?.model ?? "",
         agent.chatControls?.startModel ?? "",
         agent.orchestrator ?? "", connection.label, String(canReadModelSettings), String(modelSettingsRetry),
         store.settingsRevisions[target]?.uuidString ?? ""]
    }

    private func loadModelSettings() async {
        modelSettings = nil
        savedModelError = nil
        loadedModelSettingsKey = nil
        guard canReadModelSettings else { return }
        let key = modelSettingsKey
        do {
            let settings = try await store.settings(for: target)
            guard !Task.isCancelled, key == modelSettingsKey else { return }
            modelSettings = settings
            loadedModelSettingsKey = key
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, key == modelSettingsKey else { return }
            savedModelError = error.localizedDescription
            loadedModelSettingsKey = key
        }
    }

    private var composerInputHook: some View {
        let dismissal: (@MainActor () -> Void)?
        if composerFocused { dismissal = { @MainActor in self.dismissKeyboard() } }
        else { dismissal = nil }
        return CompanionComposerPasteHook(handle: pasteImages, dismissKeyboard: dismissal, returnActions: .init(
            canSubmit: { returnSlashCommand != nil || sendEnabled },
            submit: {
                if !completeReturnSlashCommand() { sendMessage() }
            },
            completeSlashCommand: completeReturnSlashCommand
        ))
    }

    private func completeReturnSlashCommand() -> Bool {
        guard let command = returnSlashCommand else { return false }
        pickSlashCommand(command)
        return true
    }

    private func sendMessage() {
        guard sendEnabled else { return }
        Task { await store.sendDraft(to: target) }
    }

    private var showsKeyboardDismissButton: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--companion-preview"),
           ProcessInfo.processInfo.arguments.contains("--companion-preview-assistive-keyboard") { return true }
        #endif
        return voiceOverEnabled || switchControlEnabled
    }

    private func dismissKeyboard() {
        #if DEBUG
        CompanionComposerFocusProbe.record?(.keyboardDismissed, target, composerFocused)
        #endif
        // Keep this word closed on refocus, just like a transcript tap. Input state remains in this subtree.
        if let token = caretSlashToken, let commands = agent.slashCommands,
           !CompanionSlashMenu.matches(commands, text: draft.wrappedValue, token: token).isEmpty {
            slashDismissedAt = token.start
        }
        composerFocused = false
        // Clearing SwiftUI focus alone failed on the retained Dispatcher's empty chat (#264).
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Adds the images among pasted or dropped items, or explains why it can't, and returns which items it used.
    private func pasteImages(_ providers: [NSItemProvider]) async -> [Bool] {
        let limits = attachmentLimits
        let remaining = (limits?.maxCount ?? 0) - (store.attachmentDrafts[target]?.count ?? 0)
        let batch = await CompanionPastedImages.attachments(from: providers, limits: limits, remaining: remaining)
        store.addAttachments(batch.images, to: target)
        if let problem = batch.problem { store.reportAttachmentProblem(problem, target: target) }
        return batch.tookItem
    }

    private var selectedRange: Range<String.Index>? {
        if case .selection(let range)? = composerSelection?.indices { return range }
        return nil
    }

    /// The `/word` at the caret while the composer is focused and the session has commands.
    private var slashToken: CompanionSlashToken? { composerFocused ? caretSlashToken : nil }

    /// The `/word` at the caret, focused or not, so a tap on the menu that ends editing still picks. Without a known
    /// caret (before the first edit), the end of the draft.
    private var caretSlashToken: CompanionSlashToken? {
        guard let commands = agent.slashCommands, !commands.isEmpty else { return nil }
        let text = draft.wrappedValue
        var caret = text.count
        if case .selection(let range)? = composerSelection?.indices {
            guard range.isEmpty, range.lowerBound <= text.endIndex, let index = String.Index(range.lowerBound, within: text) else { return nil }
            caret = text.distance(from: text.startIndex, to: index)
        } else if composerSelection != nil { return nil }
        return CompanionSlashMenu.token(in: text, caret: caret)
    }

    private var slashMatches: [CompanionSlashCommand] {
        guard let token = slashToken, token.start != slashDismissedAt, let commands = agent.slashCommands else { return [] }
        return CompanionSlashMenu.matches(commands, text: draft.wrappedValue, token: token)
    }

    private var returnSlashCommand: CompanionSlashCommand? {
        guard let token = slashToken, !slashMatches.isEmpty else { return nil }
        let command = slashMatches[min(slashHighlight, slashMatches.count - 1)]
        return CompanionSlashMenu.returnPicks(token, highlighted: command) ? command : nil
    }

    /// Replaces the word with `/name ` and leaves the caret after it.
    private func pickSlashCommand(_ command: CompanionSlashCommand) {
        guard let token = caretSlashToken else { return }
        let picked = CompanionSlashMenu.pick(command, text: draft.wrappedValue, token: token)
        draft.wrappedValue = picked.text
        composerSelection = TextSelection(insertionPoint: picked.text.index(picked.text.startIndex, offsetBy: picked.caret))
        composerFocused = true
    }

    /// Closes the menu for the word being typed. Returns whether a menu was open.
    @discardableResult private func dismissSlashMenu() -> Bool {
        guard !slashMatches.isEmpty, let token = slashToken else { return false }
        slashDismissedAt = token.start
        return true
    }

    /// A hardware keyboard drives the menu like the desktop's: arrows move, Tab picks, Esc closes.
    /// Return completion is shared with the native input hook, not inferred from text changes.
    private func slashKey(_ press: KeyPress) -> KeyPress.Result {
        let matches = slashMatches
        guard !matches.isEmpty else { return .ignored }
        let highlighted = min(slashHighlight, matches.count - 1)
        switch press.key {
        case .downArrow: slashHighlight = (highlighted + 1) % matches.count
        case .upArrow: slashHighlight = (highlighted - 1 + matches.count) % matches.count
        // Picked on the next turn: the text view is still handling the key and would put its own text back.
        case .tab: Task { pickSlashCommand(matches[highlighted]) }
        case .escape: dismissSlashMenu()
        default: return .ignored
        }
        return .handled
    }

    /// The send button with its padding, or one line of text with the field's padding if that is taller.
    private var composerRowHeight: CGFloat { max(compactHeight ? 44 : 48, composerLineHeight + (compactHeight ? 12 : 24)) }

    /// Reserve a caption only for information that changes what sending will do.
    @ViewBuilder private var composerCaption: some View {
        if let caption = composerCaptionText {
            Group {
                if isShowingRefresh {
                    Label {
                        Text(caption)
                    } icon: {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: !reduceMotion)
                    }
                    .labelStyle(.titleAndIcon)
                } else {
                    Text(caption)
                }
            }
            .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .accessibilityElement(children: .combine)
        }
    }

    /// Only for a transcript already on screen: a first load has its own indicator in the transcript.
    private var isShowingRefresh: Bool { showRefreshing && conversation.isLoading && !conversation.items.isEmpty }

    private var composerCaptionText: String? {
        if !connection.canOperate { return "Draft saved while you reconnect" }
        // Loading disables Send; say why rather than implying chat is unsupported.
        if isShowingRefresh {
            return "Refreshing… you can send in a moment"
        }
        if conversation.isLoading { return nil }
        if !store.canSend(target) && connection.canOperate && !store.pendingCommands.contains(target) && !conversation.requiresResync {
            return "This desktop does not support chat control for this agent yet."
        }
        return defaultCaption
    }

    private var defaultCaption: String? {
        // Steer is already named in the field and Send's hint; queue-only delivery still needs explaining.
        agent.status == .working && !agent.capabilities.contains(.steer) ? "Your message will wait for the next turn." : nil
    }

    private var sendOutcomeHint: String {
        if agent.status == .working {
            return agent.capabilities.contains(.steer) ? "Your direction will be sent to the running agent." : "Your message will wait for the next turn."
        }
        return "Sends your message to \(agent.displayName)."
    }

    /// The desktop's "Message {name}…". Mid-turn, the desktop's send actions name what happens: Steer or Queue.
    private var composerPlaceholder: String {
        let steers = agent.capabilities.contains(.steer)
        if dynamicTypeSize.isAccessibilitySize {
            return agent.status == .working ? (steers ? "Steer…" : "Queue…") : "Message…"
        }
        if agent.status == .working { return steers ? "Steer \(agent.displayName)…" : "Queue a message for \(agent.displayName)…" }
        return agent.slashCommands == nil ? "Message \(agent.displayName)…" : "Message \(agent.displayName)… / for commands"
    }
}

struct CompanionComposerFlexibleHeight: LayoutValueKey {
    static let defaultValue = false
}

/// Measure fixed controls first, then offer the menu only the remaining keyboard-safe height.
/// The outer activity/composer stack uses the same allocation without remounting the native editor.
struct CompanionComposerLayout: Layout {
    let spacing: CGFloat
    var maximumHeight: CGFloat = .infinity

    private func sizes(proposal: ProposedViewSize, subviews: Subviews) -> [CGSize] {
        var sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        if let flexible = subviews.firstIndex(where: { $0[CompanionComposerFlexibleHeight.self] }) {
            let gaps = CGFloat(max(0, sizes.filter { $0.height > 0 }.count - 1)) * spacing
            let fixedHeight = sizes.indices.filter { $0 != flexible }.reduce(gaps) { $0 + sizes[$1].height }
            let budget = max(0, min(maximumHeight, proposal.height ?? .infinity) - fixedHeight)
            sizes[flexible] = subviews[flexible].sizeThatFits(ProposedViewSize(width: proposal.width, height: budget))
        }
        return sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(proposal: proposal, subviews: subviews)
        let gaps = CGFloat(max(0, sizes.filter { $0.height > 0 }.count - 1)) * spacing
        return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0,
                      height: sizes.reduce(gaps) { $0 + $1.height })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        var y = bounds.minY
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
            if sizes[index].height > 0 { y += sizes[index].height + spacing }
        }
    }
}

struct CompanionComposerApprovalReviewSelection: Equatable {
    let target: CompanionTarget
    let approvalID: String
    var presentation: CompanionDecisionPresentation? = nil
}

/// Review presentation and actions always resolve the selected request against the current conversation.
/// Kept separate so synthetic event tests exercise the same methods used by the actual sheet buttons.
struct CompanionComposerApprovalReviewSheet: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    @Binding var selection: CompanionComposerApprovalReviewSelection?
    @Environment(\.companionPalette) private var palette

    var currentApproval: CompanionApproval? {
        guard let selection, selection.target == target else { return nil }
        if let presentation = selection.presentation,
           store.host(for: target)?.controlEpoch != presentation.epoch
            || store.conversation(for: target).sessionID != presentation.sessionID { return nil }
        return store.conversation(for: target).items.lazy.compactMap { item -> CompanionApproval? in
            if case .approval(let approval) = item, approval.id == selection.approvalID { return approval }
            return nil
        }.first
    }

    var currentDecision: CompanionPendingDecision? {
        guard let selection, selection.target == target else { return nil }
        if let presentation = selection.presentation {
            guard store.host(for: target)?.controlEpoch == presentation.epoch,
                  store.conversation(for: target).sessionID == presentation.sessionID else { return nil }
            return store.conversation(for: target).items.compactMap { item -> CompanionPendingDecision? in
                switch item {
                case .approval(let approval): .approval(approval)
                case .question(let question): .question(question)
                default: nil
                }
            }.first { $0.id == presentation.decision.id }
        }
        return currentApproval.map(CompanionPendingDecision.approval)
    }

    func queuePosition(at date: Date) -> String? {
        guard let approval = currentApproval else { return nil }
        return CompanionChatActivity.queuePosition(of: approval, in: store.conversation(for: target).items, at: date)
    }

    var canRespond: Bool {
        store.canOperate(target) && store.agent(for: target)?.capabilities.contains(.approve) == true
            && !store.pendingCommands.contains(target)
    }

    func close() { selection = nil }

    /// Called inside the UI callback's Task. Do not resolve before enqueueing or remap an old option by ID.
    func respond(to originalRequestID: String, option originalOption: CompanionApprovalOption) async {
        guard selection?.target == target, selection?.approvalID == originalRequestID, let approval = currentApproval else { return }
        await store.respond(approval, option: originalOption, target: target)
    }

    func respond(_ presentation: CompanionDecisionPresentation, option: CompanionApprovalOption) async {
        guard selection?.target == target, selection?.presentation?.decision.id == presentation.decision.id else { return }
        await store.respond(presentation, option: option)
    }

    func answer(_ presentation: CompanionDecisionPresentation, answers: [String: CompanionAnswer]) async {
        guard selection?.target == target, selection?.presentation?.decision.id == presentation.decision.id else { return }
        await store.answer(presentation, answers: answers)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        CompanionDecisionNoticesView(store: store, notices: store.decisionNotices(for: target))
                        if let decision = currentDecision {
                            let presentation = store.decisionPresentation(decision, target: target)
                            switch decision {
                            case .approval(let approval):
                            CompanionApprovalCard(approval: approval, queuePosition: queuePosition(at: context.date),
                                canRespond: canRespond, persistentApprovals: store.canAnswerPersistentApprovals(target),
                                respond: { option in Task {
                                    if selection?.presentation != nil { await respond(presentation, option: option) }
                                    else { await respond(to: approval.id, option: option) }
                                } })
                            case .question(let question):
                                CompanionQuestionCard(question: question,
                                    canRespond: store.canOperate(target) && store.agent(for: target)?.capabilities.contains(.answer) == true
                                        && !store.pendingCommands.contains(target)) { answers in
                                    Task { await answer(presentation, answers: answers) }
                                }
                                .id(question.id)
                            }
                        } else {
                            Text("This approval is no longer available.")
                                .accessibilityIdentifier("companion-approval-review-unavailable")
                        }
                        if let error = store.operationErrors[target] {
                            Label(error, systemImage: "exclamationmark.circle")
                                .foregroundStyle(Color(palette.warning))
                        }
                    }
                    .padding()
                }
            }
            .accessibilityIdentifier("companion-approval-review-scroll")
            // The card's Allow and full-event review use the same store.canApprove gate as the transcript.
            .companionContentPreviews(store: store, target: target)
            .navigationTitle(isQuestion ? "Review question" : "Review approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close", action: close)
                        .accessibilityIdentifier("companion-approval-review-close")
                }
            }
        }
        .presentationDetents([.large])
    }
    private var isQuestion: Bool {
        if case .question = selection?.presentation?.decision { return true }
        return false
    }
}
