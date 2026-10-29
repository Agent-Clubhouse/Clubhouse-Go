import SwiftUI

struct CompanionConversationView: View {
    @Bindable var store: CompanionStore
    let agent: CompanionAgent
    /// Review keeps neighbouring chats alive; only the one on screen puts its menu in the navigation bar.
    var showsActions = true
    @State private var followLatest = true
    @State private var confirmCancel = false
    @State private var showArchive = false
    @State private var showRefreshing = false
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionOpenAgent) private var openAgent
    @Environment(\.companionAgentSettings) private var agentSettings
    @Environment(\.companionSendFeedback) private var sendFeedback
    /// A generous estimate of the composer's line height, so one line can be centred in the send row at every text size.
    @ScaledMetric(relativeTo: .body) private var composerLineHeight: CGFloat = 24

    private var target: CompanionTarget { agent.id }
    private var conversation: CompanionConversation { store.conversation(for: target) }
    private var connection: CompanionConnection { store.host(for: target)?.connection ?? .offline }
    private var draft: Binding<String> {
        Binding(get: { store.drafts[target] ?? "" }, set: { store.drafts[target] = $0 })
    }
    private var canRespond: Bool { store.canOperate(target) && agent.capabilities.contains(.approve) && !store.pendingCommands.contains(target) }
    private var attachmentLimits: CompanionAttachmentLimits? { store.attachmentLimits(for: target) }
    /// Text, images, or both.
    private var hasMessage: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(store.attachmentDrafts[target] ?? []).isEmpty
    }
    /// A running terminal agent's own PTY takes the chat's place, when the desktop lets the phone attach to it.
    private var showsAgentTerminal: Bool { agent.runsInTerminal && store.terminalAvailability(.agentPTY(target)).isAvailable }
    private var isAsleep: Bool { agent.capabilities.contains(.wake) && (agent.status == .sleeping || agent.status == .stopped) }

    var body: some View {
        VStack(spacing: 0) {
            contextHeader
            if store.justCreated == target { CompanionCreatedAgentNotice(store: store, agent: agent) { composerFocused = true } }
            if !connection.canOperate || conversation.requiresResync { connectionBanner }
            if let error = store.operationErrors[target] {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { store.dismissError(for: target) }.labelStyle(.iconOnly)
                }
                .padding().background(Color(palette.warning).opacity(0.12))
                .accessibilityElement(children: .contain)
            }
            if showsAgentTerminal { CompanionAgentTerminalPane(store: store, target: target) }
            else { timeline.companionContentPreviews(store: store, target: target) }
        }
        .companionBackground()
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsActions {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Refresh conversation", systemImage: "arrow.clockwise") { Task { await store.load(target, force: true) } }
                        Button("Conversation archive", systemImage: "clock.arrow.circlepath") { showArchive = true }
                        if let agentSettings { CompanionAgentMenuItems(target: target, actions: agentSettings) }
                        CompanionTerminalMenuItem(scope: .agentShell(target))
                        Section("Conversation details") {
                            Text(contextName)
                            if let model = agent.model { Text(model) }
                        }
                        if agent.capabilities.contains(.wake) {
                            ForEach(store.wakeChoices(for: target)) { choice in
                                Button(choice.label, systemImage: choice.systemImage) { Task { await store.wake(target, choice) } }
                                    .disabled(!store.canWake(target))
                            }
                        }
                        if agent.status == .working {
                            Button("Interrupt turn", systemImage: "stop.circle", role: .destructive) { confirmCancel = true }
                                .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel))
                        }
                        if let sendFeedback { Button("Send feedback", systemImage: "exclamationmark.bubble", action: sendFeedback) }
                    } label: { Label("Conversation actions", systemImage: "ellipsis") }
                }
            }
        }
        // Bars, not insets: the transcript gets the system scroll-edge effect under the glass instead of showing through.
        .safeAreaBar(edge: .top, spacing: 0) { otherAgentBanner }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if agent.runsInTerminal { if !showsAgentTerminal { terminalNotice } } else { composer }
        }
        .sheet(isPresented: $showArchive) { CompanionArchiveView(store: store, target: target) }
        .task(id: target) { await store.load(target, force: conversation.requiresResync) }
        .onChange(of: connection) { _, current in
            if current.canOperate && conversation.requiresResync && !conversation.isLoading {
                Task { await store.load(target, force: true) }
            }
        }
        .confirmationDialog("Interrupt this turn?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Interrupt turn", role: .destructive) { Task { await store.cancel(target) } }
        } message: { Text("The current turn will be interrupted. You can then send a new direction in the same conversation.") }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                CompanionStatusText(status: agent.status).font(.caption.weight(.semibold))
                if agent.freeAgentMode { CompanionFreeAgentBadge() }
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("· \(contextName)").font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let controls = agent.chatControls { CompanionLevelBadge(level: controls.currentLevel) }
                    else if let model = agent.model { Text(model).font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1) }
                } else {
                    Spacer(minLength: 0)
                    if let controls = agent.chatControls { CompanionLevelBadge(level: controls.currentLevel) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("companion-chat-header")
            activityLine
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    /// Elapsed time and the running tool, or what the agent waits on, with context fill: the desktop's chat header.
    @ViewBuilder private var activityLine: some View {
        let percent = agent.contextUsage?.percent
        let ticking = agent.status == .working && agent.turnStartedAt != nil
        TimelineView(.periodic(from: .now, by: ticking ? 1 : 60)) { context in
            let activity = CompanionChatActivity.line(status: agent.status, turnStartedAt: agent.turnStartedAt, items: conversation.items, now: context.date)
            if activity != nil || percent != nil {
                HStack(spacing: 6) {
                    if let activity {
                        Text(activity).font(.caption.monospacedDigit()).foregroundStyle(Color(palette.secondaryLabel))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .accessibilityIdentifier("companion-chat-activity")
                    }
                    Spacer(minLength: 8)
                    if let percent { CompanionContextRing(percent: percent) }
                }
            }
        }
    }

    private var contextName: String {
        guard let host = store.host(for: target) else { return "Desktop unavailable" }
        let project = host.projects.first { $0.id == target.projectID }?.name ?? "Project"
        return "\(host.name) / \(project)"
    }

    private var connectionBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: conversation.requiresResync ? "arrow.trianglehead.2.clockwise.rotate.90" : "wifi.exclamationmark")
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.requiresResync ? "Conversation needs a refresh" : connection.label).font(.subheadline.weight(.semibold))
                Text(conversation.requiresResync ? "Some updates were missed. Refresh before sending another command." : connection.detail).font(.caption)
                Button(conversation.requiresResync ? "Refresh conversation" : "Retry") {
                    Task {
                        if conversation.requiresResync { await store.load(target, force: true) }
                        else { await store.reconnect(hostID: target.hostID) }
                    }
                }
                .font(.subheadline.weight(.semibold)).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// While the app is open there are no system banners, so another agent that needs you shows here.
    @ViewBuilder private var otherAgentBanner: some View {
        // Compare by agent, not list entry: a desktop can list one agent under more than one project.
        if let other = store.allAgents.first(where: { $0.status.needsYou && ($0.id.agentID != target.agentID || $0.id.hostID != target.hostID) }) {
            CompanionGlassBanner(systemImage: other.status.symbol,
                                 text: Text("**\(other.name)** \(other.status == .failed ? "hit an error" : "needs you")")) {
                Button("View") { openAgent(other.id) }.buttonStyle(.glass)
                    .accessibilityLabel("View \(other.name)")
            }
            .padding(.bottom, 6)
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // Refreshes of a transcript already on screen show in the composer instead.
                    if conversation.isLoading && conversation.items.isEmpty { ProgressView("Loading conversation…").frame(maxWidth: .infinity).padding() }
                    if let error = conversation.error {
                        ContentUnavailableView {
                            Label("Conversation unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                        } description: { Text(error) } actions: {
                            Button("Try again") { Task { await store.load(target, force: true) } }
                        }
                    }
                    if conversation.hasEarlierMessages {
                        Button("Read earlier messages in archive", systemImage: "clock.arrow.circlepath") { showArchive = true }
                            .font(.caption).frame(maxWidth: .infinity)
                    }
                    if conversation.items.isEmpty && !conversation.isLoading && conversation.error == nil {
                        ContentUnavailableView("No messages yet. Send one to start.", systemImage: "bubble.left.and.text.bubble.right")
                            .accessibilityIdentifier("companion-empty-conversation")
                    }
                    let pinnedID = store.pinnedApproval(for: target)?.id
                    let items = conversation.items
                    let rows = CompanionTimelineFolding.rows(for: conversation.items)
                    let hintRowID = CompanionContentReference.hintRowID(in: rows, richContentAvailable: store.richContentAvailable(for: target))
                    ForEach(rows) { row in
                        timelineRow(row, pinnedApprovalID: pinnedID, items: items).id(row.id)
                        if row.id == hintRowID { CompanionContentHint() }
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 14 : 22)
                .padding(.vertical, 24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            // Away from the latest, keep what you're reading still as rows resize. Anchored to the bottom there, a reply
            // taller than the screen moved the offset with each of the lazy stack's height estimates, which never settled.
            .defaultScrollAnchor(followLatest ? .bottom : .top, for: .sizeChanges)
            // Follow from the scroll position, not the end marker's appear and disappear: under a reply taller than the
            // screen the lazy stack kept realising and dropping the marker as it re-estimated, and each flip re-rendered
            // the conversation, which never settled (#180).
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height + geometry.contentInsets.bottom - 40
            } action: { _, atLatest in
                if followLatest != atLatest { followLatest = atLatest }
            }
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if !followLatest && !conversation.items.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) }
                    } label: { Label("Latest", systemImage: "arrow.down") }
                    .buttonStyle(.glass).padding()
                }
            }
            .onChange(of: conversation.items) { _, _ in
                if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            // Once the history is in, pin to the latest after the layout settles. On iOS 26.5 a chat that loads during a
            // navigation transition can keep the bottom anchor's estimate with no rows laid out, which looks empty.
            .task(id: conversation.isLoaded) {
                guard conversation.isLoaded, followLatest else { return }
                await Task.yield()
                proxy.scrollTo("latest", anchor: .bottom)
            }
        }
    }

    @ViewBuilder private func timelineRow(_ row: CompanionTimelineRow, pinnedApprovalID: String?, items: [CompanionTimelineItem]) -> some View {
        switch row {
        case .item(let item): timelineItem(item, pinnedApprovalID: pinnedApprovalID, items: items)
        case .tools(let tools): CompanionToolGroupCard(tools: tools, store: store, target: target)
        }
    }

    @ViewBuilder private func timelineItem(_ item: CompanionTimelineItem, pinnedApprovalID: String?, items: [CompanionTimelineItem]) -> some View {
        switch item {
        case .message(let message):
            CompanionMessageView(message: message, canRetry: store.canSend(target), retry: {
                Task { await store.retry(messageID: message.id, target: target) }
            }, canRemoveQueued: store.canOperate(target) && agent.capabilities.contains(.removeQueued) && !store.pendingCommands.contains(target),
               removeQueued: agent.capabilities.contains(.removeQueued) ? { Task { await store.removeQueuedMessage(message.id, target: target) } } : nil)
            if message.role == .assistant {
                CompanionContentLinks(references: CompanionContentReference.references(in: item))
            }
        case .tool(let tool):
            CompanionToolCard(tool: tool)
            CompanionContentLinks(references: CompanionContentReference.references(in: item))
        case .approval(let approval):
            CompanionApprovalCard(approval: approval, queuePosition: CompanionChatActivity.queuePosition(of: approval, in: items),
                                  canRespond: canRespond, actionsArePinned: approval.id == pinnedApprovalID,
                                  persistentApprovals: store.canAnswerPersistentApprovals(target)) { option in
                Task { await store.respond(approval, option: option, target: target) }
            }
        case .question(let question):
            CompanionQuestionCard(question: question, canRespond: store.canOperate(target) && agent.capabilities.contains(.answer) && !store.pendingCommands.contains(target)) { answers in
                Task { await store.answer(question, answers: answers, target: target) }
            }
        case .notice(_, let text):
            Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
        }
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

    private var composer: some View {
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
            if let controls = agent.chatControls, !isAsleep {
                CompanionChatControlsBar(agentName: agent.name, controls: controls, enabled: store.canChangeChatControls(target),
                                         setLevel: { level in Task { await store.setLevel(level, target: target) } },
                                         setModel: { model, effort in Task { await store.setModel(model, effort: effort, target: target) } })
                    .equatable()
            }
            HStack(alignment: .bottom, spacing: 8) {
                if agent.status == .working {
                    Button { confirmCancel = true } label: {
                        Image(systemName: "stop.fill").font(.headline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel) || store.pendingCommands.contains(target))
                    .accessibilityLabel("Interrupt")
                    .frame(height: composerRowHeight)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    if let limits = attachmentLimits {
                        CompanionAttachButton(store: store, target: target, limits: limits).padding(.leading, 8).frame(height: composerRowHeight)
                    }
                    TextField(composerPlaceholder, text: draft, axis: .vertical)
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
                    Button {
                        Task { await store.sendDraft(to: target) }
                    } label: {
                        Image(systemName: agent.status == .working ? "arrow.turn.up.right" : "arrow.up")
                            .font(.headline.weight(.bold)).frame(width: 36, height: 36)
                    }
                    .buttonStyle(.companionTintedCircle)
                    .disabled(!store.canSend(target) || !hasMessage)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(agent.status == .working ? "Send steering message" : "Send message")
                    .accessibilityHint(conversation.isLoading ? "Refreshing the conversation. You can send in a moment." : "")
                    .accessibilityIdentifier("companion-send")
                    .padding(.horizontal, 6)
                    .frame(height: composerRowHeight)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
            composerCaption
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        // Quick refreshes finish before the indicator would appear, so they don't flash.
        .task(id: conversation.isLoading) {
            guard conversation.isLoading else { showRefreshing = false; return }
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            showRefreshing = true
        }
    }

    /// The send button with its padding, or one line of text with the field's padding if that is taller.
    private var composerRowHeight: CGFloat { max(36 + 12, composerLineHeight + 24) }

    /// One caption line under the composer. Refresh state shows in the same line, so the composer doesn't move.
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
        // Loading disables Send; say why rather than implying chat is unsupported.
        if isShowingRefresh {
            return dynamicTypeSize.isAccessibilitySize ? nil : "Refreshing… you can send in a moment"
        }
        if conversation.isLoading { return dynamicTypeSize.isAccessibilitySize ? nil : defaultCaption }
        if !store.canSend(target) && connection.canOperate && !store.pendingCommands.contains(target) && !conversation.requiresResync {
            return "This desktop does not support chat control for this agent yet."
        }
        if dynamicTypeSize.isAccessibilitySize { return nil }
        return connection.canOperate ? defaultCaption : "Draft saved while you reconnect"
    }

    private var defaultCaption: String {
        agent.status == .working ? (agent.capabilities.contains(.steer) ? "Your direction will be sent to the running agent." : "Your message will wait for the next turn.") : "Runs on your desktop • ⌘ Return to send"
    }

    /// Messages only reach chat-runtime agents (the desktop answers `not_chat` otherwise).
    private var terminalNotice: some View {
        Label("\(agent.name) runs in a terminal on your desktop. Open it there to work with it.", systemImage: "terminal")
            .font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// The desktop's "Message {name}…". Mid-turn, the desktop's send actions name what happens: Steer or Queue.
    private var composerPlaceholder: String {
        let steers = agent.capabilities.contains(.steer)
        if dynamicTypeSize.isAccessibilitySize {
            return agent.status == .working ? (steers ? "Steer…" : "Queue…") : "Message…"
        }
        return agent.status == .working ? (steers ? "Steer \(agent.name)…" : "Queue a message for \(agent.name)…") : "Message \(agent.name)…"
    }
}

/// Context fill as a small ring with its percentage, like the desktop's usage ring. Hot from 90%.
struct CompanionContextRing: View {
    let percent: Int
    @Environment(\.companionPalette) private var palette
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 11
    var body: some View {
        let hot = percent >= 90
        HStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                Circle().trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(hot ? Color(palette.error) : Color(palette.secondaryLabel), style: .init(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            Text("\(percent)%").font(.caption.monospacedDigit()).foregroundStyle(hot ? Color(palette.error) : Color(palette.secondaryLabel))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(percent)% full")
        .accessibilityIdentifier("companion-context-usage")
    }
}
