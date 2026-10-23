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

    private var target: CompanionTarget { agent.id }
    private var conversation: CompanionConversation { store.conversation(for: target) }
    private var connection: CompanionConnection { store.host(for: target)?.connection ?? .offline }
    private var draft: Binding<String> {
        Binding(get: { store.drafts[target] ?? "" }, set: { store.drafts[target] = $0 })
    }

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
                .padding().background(Color.orange.opacity(0.1))
                .accessibilityElement(children: .contain)
            }
            timeline
        }
        .background(Color(.systemGroupedBackground))
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
                    if agent.status == .working {
                        Button("Interrupt turn", systemImage: "stop.circle", role: .destructive) { confirmCancel = true }
                            .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel))
                    }
                } label: { Label("Conversation actions", systemImage: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !dynamicTypeSize.isAccessibilitySize { Text(contextName).font(.caption).foregroundStyle(.secondary) }
                CompanionStatusLabel(status: agent.status)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let model = agent.model, !dynamicTypeSize.isAccessibilitySize { Text(model).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
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
        .background(Color.orange.opacity(0.1))
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
                    ForEach(conversation.items) { item in
                        timelineItem(item).id(item.id)
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
                    .buttonStyle(.borderedProminent).clipShape(Capsule()).padding()
                }
            }
            .onChange(of: conversation.items) { _, _ in
                if followLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func timelineItem(_ item: CompanionTimelineItem) -> some View {
        switch item {
        case .message(let message):
            CompanionMessageView(message: message, canRetry: store.canSend(target), retry: {
                Task { await store.retry(messageID: message.id, target: target) }
            }, canRemoveQueued: store.canOperate(target) && agent.capabilities.contains(.removeQueued) && !store.pendingCommands.contains(target),
               removeQueued: agent.capabilities.contains(.removeQueued) ? { Task { await store.removeQueuedMessage(message.id, target: target) } } : nil)
        case .tool(let tool): CompanionToolCard(tool: tool)
        case .approval(let approval):
            CompanionApprovalCard(approval: approval, canRespond: store.canOperate(target) && agent.capabilities.contains(.approve) && !store.pendingCommands.contains(target)) { option in
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if agent.status == .working {
                HStack {
                    if !dynamicTypeSize.isAccessibilitySize { Label("Agent is working", systemImage: "waveform").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Interrupt", systemImage: "stop.fill") { confirmCancel = true }
                        .font(.caption.weight(.semibold))
                        .disabled(!store.canOperate(target) || !agent.capabilities.contains(.cancel) || store.pendingCommands.contains(target))
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(composerPlaceholder, text: draft, axis: .vertical)
                    .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 8))
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                    .focused($composerFocused)
                    .accessibilityLabel(agent.status == .working ? "Steering message" : "Message")
                    .accessibilityHint("Runs on your desktop. Command Return sends the message.")
                    .accessibilityIdentifier("companion-composer")
                Button {
                    Task { await store.sendDraft(to: target) }
                } label: {
                    Image(systemName: agent.status == .working ? "arrow.turn.up.right" : "arrow.up")
                        .font(.headline.weight(.bold)).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .disabled(!store.canSend(target) || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(agent.status == .working ? "Send steering message" : "Send message")
                .accessibilityIdentifier("companion-send")
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
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var composerPlaceholder: String {
        if dynamicTypeSize.isAccessibilitySize {
            return agent.status == .working ? (agent.capabilities.contains(.steer) ? "Steer…" : "Follow up…") : "Message…"
        }
        return agent.status == .working ? (agent.capabilities.contains(.steer) ? "Steer this agent…" : "Queue a follow-up…") : "Message this agent…"
    }
}
