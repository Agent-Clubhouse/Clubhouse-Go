import SwiftUI

struct CompanionConversationView: View {
    @Bindable var store: CompanionStore
    let agent: CompanionAgent
    @State private var followLatest = true
    @State private var confirmCancel = false
    @State private var showArchive = false
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.companionPalette) private var palette
    @Environment(\.companionOpenAgent) private var openAgent

    private var target: CompanionTarget { agent.id }
    private var conversation: CompanionConversation { store.conversation(for: target) }
    private var connection: CompanionConnection { store.host(for: target)?.connection ?? .offline }
    private var draft: Binding<String> {
        Binding(get: { store.drafts[target] ?? "" }, set: { store.drafts[target] = $0 })
    }
    private var canRespond: Bool { store.canOperate(target) && agent.capabilities.contains(.approve) && !store.pendingCommands.contains(target) }
    private var isAsleep: Bool { agent.capabilities.contains(.wake) && (agent.status == .sleeping || agent.status == .stopped) }

    var body: some View {
        VStack(spacing: 0) {
            contextHeader
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
            timeline
        }
        .companionBackground()
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh conversation", systemImage: "arrow.clockwise") { Task { await store.load(target, force: true) } }
                    Button("Conversation archive", systemImage: "clock.arrow.circlepath") { showArchive = true }
                    Section("Conversation details") {
                        Text(contextName)
                        if let model = agent.model { Text(model) }
                    }
                    if agent.capabilities.contains(.wake) {
                        Button("Wake agent", systemImage: "sun.max") { Task { await store.wake(target) } }
                            .disabled(!store.canWake(target))
                    }
                    if agent.status == .working {
                        Button("Interrupt turn", systemImage: "stop.circle", role: .destructive) { confirmCancel = true }
                            .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel))
                    }
                } label: { Label("Conversation actions", systemImage: "ellipsis") }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { otherAgentBanner }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if agent.runsInTerminal { terminalNotice } else { composer }
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
        HStack(spacing: 6) {
            CompanionStatusText(status: agent.status).font(.caption.weight(.semibold))
            if !dynamicTypeSize.isAccessibilitySize {
                Text("· \(contextName)").font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1)
                Spacer(minLength: 8)
                if let model = agent.model { Text(model).font(.caption).foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1) }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
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
                Button(conversation.requiresResync ? "Refresh conversation" : "Reconnect") {
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
        if let other = store.allAgents.first(where: { $0.status.needsYou && $0.id != target }) {
            CompanionGlassBanner(systemImage: other.status.symbol,
                                 text: Text("**\(other.name)** \(other.status.label.lowercased())")) {
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
                    if conversation.isLoading { ProgressView("Loading conversation…").frame(maxWidth: .infinity).padding() }
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
                        ContentUnavailableView {
                            Label("A fresh conversation", systemImage: "bubble.left.and.text.bubble.right")
                        } description: {
                            Text("Give this agent a task, ask a question, or pick up where you left off on desktop.")
                        }
                    }
                    let pinnedID = store.pinnedApproval(for: target)?.id
                    ForEach(CompanionTimelineFolding.rows(for: conversation.items)) { row in
                        timelineRow(row, pinnedApprovalID: pinnedID).id(row.id)
                    }
                    Color.clear.frame(height: 1).id("latest")
                        .onAppear { followLatest = true }
                        .onDisappear { followLatest = false }
                }
                .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 14 : 22)
                .padding(.vertical, 24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
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
        }
    }

    @ViewBuilder private func timelineRow(_ row: CompanionTimelineRow, pinnedApprovalID: String?) -> some View {
        switch row {
        case .item(let item): timelineItem(item, pinnedApprovalID: pinnedApprovalID)
        case .tools(let tools): CompanionToolGroupCard(tools: tools, store: store, target: target)
        }
    }

    @ViewBuilder private func timelineItem(_ item: CompanionTimelineItem, pinnedApprovalID: String?) -> some View {
        switch item {
        case .message(let message):
            CompanionMessageView(message: message, canRetry: store.canSend(target), retry: {
                Task { await store.retry(messageID: message.id, target: target) }
            }, canRemoveQueued: store.canOperate(target) && agent.capabilities.contains(.removeQueued) && !store.pendingCommands.contains(target),
               removeQueued: agent.capabilities.contains(.removeQueued) ? { Task { await store.removeQueuedMessage(message.id, target: target) } } : nil)
            if message.role == .assistant {
                CompanionContentLinks(references: CompanionContentReference.files(in: message.text), store: store, target: target)
            }
        case .tool(let tool):
            CompanionToolCard(tool: tool)
            CompanionContentLinks(references: tool.images + CompanionContentReference.files(in: tool.output ?? ""), store: store, target: target)
        case .approval(let approval):
            CompanionApprovalCard(approval: approval, canRespond: canRespond, actionsArePinned: approval.id == pinnedApprovalID) { option in
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
                Text(approval.toolName).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                if let deny = approval.options.first(where: { $0.kind == .rejectOnce }) {
                    Button(deny.label) { Task { await store.respond(approval, option: deny, target: target) } }
                        .buttonStyle(.bordered)
                }
                if let allow = approval.options.first(where: { $0.kind == .allowOnce }) {
                    Button(allow.label) { Task { await store.respond(approval, option: allow, target: target) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .buttonBorderShape(.capsule)
            .disabled(!canRespond)
            .padding(8)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Approval needed: \(approval.toolName)")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            pinnedApprovalBar
            if isAsleep {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz").foregroundStyle(Color(palette.secondaryLabel))
                    Text("\(agent.name) is asleep. Wake it, or send a message to resume.").font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Wake", systemImage: "sun.max") { Task { await store.wake(target) } }
                        .buttonStyle(.glassProminent)
                        .disabled(!store.canWake(target)).accessibilityIdentifier("companion-wake")
                }
                .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if agent.status == .working {
                    Button { confirmCancel = true } label: {
                        Image(systemName: "stop.fill").font(.headline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel) || store.pendingCommands.contains(target))
                    .accessibilityLabel("Interrupt")
                }
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(composerPlaceholder, text: draft, axis: .vertical)
                        .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 8))
                        .padding(.vertical, 12).padding(.leading, 16)
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
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .disabled(!store.canSend(target) || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(agent.status == .working ? "Send steering message" : "Send message")
                    .accessibilityIdentifier("companion-send")
                    .padding(6)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
            if conversation.isLoading {
                ProgressView("Refreshing…").font(.caption)
            } else if !store.canSend(target) && connection.canOperate && !store.pendingCommands.contains(target) && !conversation.requiresResync {
                Text("This desktop does not support chat control for this agent yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !connection.canOperate && !dynamicTypeSize.isAccessibilitySize {
                Text("Draft saved while you reconnect").font(.caption).foregroundStyle(.secondary)
            } else if !dynamicTypeSize.isAccessibilitySize {
                Text(agent.status == .working ? (agent.capabilities.contains(.steer) ? "Your direction will be sent to the running agent." : "Your message will wait for the next turn.") : "Runs on your desktop • ⌘ Return to send")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
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

    private var composerPlaceholder: String {
        if dynamicTypeSize.isAccessibilitySize {
            return agent.status == .working ? (agent.capabilities.contains(.steer) ? "Steer…" : "Follow up…") : "Message…"
        }
        return agent.status == .working ? (agent.capabilities.contains(.steer) ? "Steer this agent…" : "Queue a follow-up…") : "Message this agent…"
    }
}
