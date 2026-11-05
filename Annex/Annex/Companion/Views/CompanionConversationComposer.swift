import SwiftUI
import UIKit
import ClubhouseTransport

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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionPalette) private var palette
    /// A generous estimate of the composer's line height, so one line can be centred in the send row at every text size.
    @ScaledMetric(relativeTo: .body) private var composerLineHeight: CGFloat = 24

    private var target: CompanionTarget { agent.id }
    private var conversation: CompanionConversation { store.conversation(for: target) }
    private var connection: CompanionConnection { store.host(for: target)?.connection ?? .offline }
    private var canRespond: Bool { store.canOperate(target) && agent.capabilities.contains(.approve) && !store.pendingCommands.contains(target) }
    private var isAsleep: Bool { agent.capabilities.contains(.wake) && (agent.status == .sleeping || agent.status == .stopped) }
    private var attachmentLimits: CompanionAttachmentLimits? { store.attachmentLimits(for: target) }
    /// Text, images, or both.
    private var hasMessage: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(store.attachmentDrafts[target] ?? []).isEmpty
    }
    private var draft: Binding<String> {
        Binding(get: { store.drafts[target] ?? "" }, set: { store.drafts[target] = $0 })
    }
    /// The draft as the composer edits it. Return while the `/` menu offers a started name picks it, as on the desktop.
    private var composerText: Binding<String> {
        Binding(get: { draft.wrappedValue }, set: { text in
            // SwiftUI can invoke the setter twice with the same value for one native edit.
            if text != draft.wrappedValue { CompanionChatPerformance.edit(target: target, messageCount: conversation.items.count) }
            #if DEBUG
            if CompanionImagePaste.tracesPreviewTyping {
                print("COMPOSER_BINDING length=\(text.utf16.count) focused=\(composerFocused)")
            }
            #endif
            if composerFocused, let commands = agent.slashCommands,
               let picked = CompanionSlashMenu.pickOnReturn(old: draft.wrappedValue, new: text, commands: commands,
                                                             highlighted: slashHighlight, dismissedAt: slashDismissedAt) {
                // On the next turn: a value changed while the text view reports its own edit doesn't reach it.
                draft.wrappedValue = text
                Task {
                    guard draft.wrappedValue == text else { return }
                    draft.wrappedValue = picked.text
                    composerSelection = TextSelection(insertionPoint: picked.text.index(picked.text.startIndex, offsetBy: picked.caret))
                }
                return
            }
            draft.wrappedValue = text
        })
    }
    /// Deny and Allow once for the pending approval stay above the composer until answered.
    @ViewBuilder private var pinnedApprovalBar: some View {
        if let approval = store.pinnedApproval(for: target) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(approval.title ?? approval.toolName).lineLimit(1)
                    if let position = CompanionChatActivity.queuePosition(of: approval, in: conversation.items) {
                        Text(position).foregroundStyle(.tertiary).fixedSize()
                    }
                }
                .font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                if let deny = approval.options.first(where: { $0.kind == .rejectOnce }) {
                    Button(deny.label) { Task { await store.respond(approval, option: deny, target: target) } }
                        .buttonStyle(.bordered)
                }
                if let allow = approval.options.first(where: { $0.kind == .allowOnce }) {
                    Button(allow.label) { Task { await store.respond(approval, option: allow, target: target) } }
                        .buttonStyle(.borderedProminent).companionProminentLabel()
                }
            }
            .buttonBorderShape(.capsule)
            .disabled(!canRespond)
            .padding(8)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Approval needed: \(approval.title ?? approval.toolName)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pinnedApprovalBar
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
            if !usesCompactControls { chatControls(compact: false) }
            if !slashMatches.isEmpty {
                CompanionSlashMenuView(commands: slashMatches, highlighted: min(slashHighlight, slashMatches.count - 1), pick: pickSlashCommand)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if usesCompactControls { chatControls(compact: true).frame(height: composerRowHeight) }
                if agent.status == .working {
                    Button { confirmCancel = true } label: {
                        Image(systemName: "stop.fill").font(.headline)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel) || store.pendingCommands.contains(target))
                    .accessibilityLabel("Interrupt")
                    .frame(height: composerRowHeight)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    if let limits = attachmentLimits {
                        CompanionAttachButton(store: store, target: target, limits: limits).padding(.leading, 8).frame(height: composerRowHeight)
                    }
                    TextField(composerPlaceholder, text: composerText, selection: $composerSelection, axis: .vertical)
                        .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 8))
                        // Size to the text view's own line height. Otherwise one line is laid out ~1.7pt shorter
                        // than its content (20.33 vs 22pt at Large), and the text bobs as it scrolls to the caret.
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 12).padding(.leading, attachmentLimits == nil ? 16 : 2)
                        // One line is centred in the row; longer drafts grow upward with Send on the last line.
                        .frame(minHeight: composerRowHeight)
                        .focused($composerFocused)
                        .accessibilityLabel(agent.status == .working ? "Steering message" : "Message")
                        .accessibilityHint("Runs on your desktop. Command Return sends the message.")
                        .accessibilityIdentifier("companion-composer")
                        // Pasted or dropped images join the attachments; text pastes as usual. Added after the
                        // accessibility modifiers so the hook doesn't appear as a second composer element.
                        .background(composerInputHook.accessibilityHidden(true))
                        .onKeyPress(keys: [.upArrow, .downArrow, .tab, .escape], phases: .down, action: slashKey)
                    Button {
                        Task { await store.sendDraft(to: target) }
                    } label: {
                        Image(systemName: agent.status == .working ? "arrow.turn.up.right" : "arrow.up")
                            .font(.headline.weight(.bold))
                    }
                    .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
                    .disabled(!store.canSend(target) || !hasMessage)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(agent.status == .working ? "Send steering message" : "Send message")
                    .accessibilityHint(conversation.isLoading ? "Refreshing the conversation. You can send in a moment." : "")
                    .accessibilityIdentifier("companion-send")
                    .padding(.horizontal, 6)
                    .frame(height: composerRowHeight)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                // Images dragged in on iPad join the attachments like pasted ones.
                .onDrop(of: CompanionPastedImages.acceptedTypes, isTargeted: nil) { providers in
                    Task { _ = await pasteImages(providers) }
                    return true
                }
                // A real scan/focus target when assistive technology is running, in the existing row:
                // no accessory toolbar, and no extra vertical space above the slash menu.
                if composerFocused && showsKeyboardDismissButton {
                    Button("Dismiss Keyboard", systemImage: "keyboard.chevron.compact.down", action: dismissKeyboard)
                        .labelStyle(.iconOnly)
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("companion-dismiss-keyboard")
                        .frame(height: composerRowHeight)
                }
            }
            composerCaption
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
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
            memory.selection = CompanionComposerSelection.capture(selectedRange, in: draft.wrappedValue)
            memory.selectionDraft = memory.selection == nil ? nil : draft.wrappedValue
            memory.slashHighlight = slashHighlight
            memory.slashDismissedAt = slashDismissedAt
            composerFocused = false
        }
        .onChange(of: focusRequests) { _, _ in composerFocused = true }
        .onChange(of: dismissals) { _, _ in
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
    }

    private var usesCompactControls: Bool { composerFocused || dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder private func chatControls(compact: Bool) -> some View {
        if let controls = agent.chatControls, !isAsleep {
            CompanionChatControlsBar(agentName: agent.name, controls: controls, enabled: store.canChangeChatControls(target),
                setLevel: { level in Task { await store.setLevel(level, target: target) } },
                setModel: { model, effort in Task { await store.setModel(model, effort: effort, target: target) } },
                compact: compact, requestLevel: { pendingLevel = $0 })
                .equatable()
        }
    }

    private var composerInputHook: some View {
        let dismissal: (@MainActor () -> Void)?
        if composerFocused { dismissal = { @MainActor in self.dismissKeyboard() } }
        else { dismissal = nil }
        return CompanionComposerPasteHook(handle: pasteImages, dismissKeyboard: dismissal)
    }

    private var showsKeyboardDismissButton: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--companion-preview"),
           ProcessInfo.processInfo.arguments.contains("--companion-preview-assistive-keyboard") { return true }
        #endif
        return voiceOverEnabled || switchControlEnabled
    }

    private func dismissKeyboard() {
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

    /// A hardware keyboard drives the menu like the desktop's: arrows move, Tab picks, Esc closes. Return reaches the
    /// text view as a newline, which `composerText` turns into a pick. Without a menu these keys work as usual.
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
    private var composerRowHeight: CGFloat { max(48, composerLineHeight + 24) }

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
        agent.status == .working ? (agent.capabilities.contains(.steer) ? "Your direction will be sent to the running agent." : "Your message will wait for the next turn.") : nil
    }

    /// The desktop's "Message {name}…". Mid-turn, the desktop's send actions name what happens: Steer or Queue.
    private var composerPlaceholder: String {
        let steers = agent.capabilities.contains(.steer)
        if dynamicTypeSize.isAccessibilitySize {
            return agent.status == .working ? (steers ? "Steer…" : "Queue…") : "Message…"
        }
        if agent.status == .working { return steers ? "Steer \(agent.name)…" : "Queue a message for \(agent.name)…" }
        return agent.slashCommands == nil ? "Message \(agent.name)…" : "Message \(agent.name)… / for commands"
    }
}
