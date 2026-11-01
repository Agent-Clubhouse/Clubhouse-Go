import SwiftUI

struct CompanionArchiveView: View {
    let store: CompanionStore
    let target: CompanionTarget
    @State private var sessions: [CompanionSessionSummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Browse saved conversations from this desktop. Return to the live conversation to steer the agent.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if isLoading { ProgressView("Loading sessions…") }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }
                    }
                }
                ForEach(sessions) { session in
                    NavigationLink {
                        CompanionArchivedSessionView(store: store, target: target, session: session)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.title).font(.headline).lineLimit(3)
                            if let date = session.lastActiveAt {
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let provider = session.provider { Text(provider).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5)
                    }
                }
                if !isLoading && sessions.isEmpty && error == nil {
                    ContentUnavailableView("No saved sessions", systemImage: "clock.arrow.circlepath",
                                           description: Text("Saved conversations appear here when the desktop has chat history for this agent."))
                }
            }
            .navigationTitle("Conversation archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do { sessions = try await store.sessions(for: target) }
        catch { self.error = error.localizedDescription }
    }
}

private struct CompanionArchivedSessionView: View {
    let store: CompanionStore
    let target: CompanionTarget
    let session: CompanionSessionSummary
    @State private var transcript: CompanionArchiveTranscript?
    @State private var error: String?
    /// How many of the newest entries are laid out; Show earlier messages adds a page before loading another.
    @State private var shownEntries = CompanionTimelineWindow.pageSize

    private var window: CompanionTimelineWindow? {
        transcript.map { CompanionTimelineWindow(CompanionTimelineEntry.entries(for: $0.items.map { .item(archived($0)) }), limit: shownEntries) }
    }

    var body: some View {
        let window = window
        ScrollView {
            // A plain stack of the newest entries, each setting its own spacing, as in the conversation (#188).
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 22) {
                    Label("Saved conversation · Read only", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.secondary) }
                    if let transcript {
                        if transcript.isLoading { ProgressView("Loading messages…").frame(maxWidth: .infinity) }
                        if let error = transcript.error {
                            Text(error).foregroundStyle(.secondary)
                            Button("Try again") { Task { await transcript.loadEarlier() } }
                        } else if window?.hiddenCount ?? 0 > 0 {
                            Button("Show earlier messages", systemImage: "arrow.up.circle") { shownEntries += CompanionTimelineWindow.pageSize }
                                .frame(maxWidth: .infinity)
                        } else if transcript.nextBeforeSequence != nil {
                            Button("Load earlier messages", systemImage: "arrow.up.circle") {
                                shownEntries += CompanionTimelineWindow.pageSize
                                Task { await transcript.loadEarlier() }
                            }
                                .disabled(transcript.isLoading).frame(maxWidth: .infinity)
                        }
                    }
                }
                if let transcript {
                    let hintItemID = CompanionContentReference.hintRowID(in: transcript.items.map { .item($0) },
                                                                         richContentAvailable: store.richContentAvailable(for: target))
                    // A long reply is a row per slice, as in the conversation (#188).
                    ForEach(window?.entries ?? []) { entry in
                        VStack(alignment: .leading, spacing: 22) {
                            archiveEntry(entry)
                            if entry.endsRow && entry.rowID == hintItemID { CompanionContentHint() }
                        }
                        .padding(.top, entry.spacingBefore)
                        .id(entry.id)
                    }
                    if transcript.isLoaded && transcript.items.isEmpty {
                        ContentUnavailableView("No messages", systemImage: "bubble.left",
                                               description: Text("This saved session has no visible messages."))
                            .padding(.top, 22)
                    }
                }
            }.padding(22).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .companionContentPreviews(store: store, target: target)
        .background(Color(.systemGroupedBackground))
        .environment(\.companionSenderResolver, CompanionSenderResolver(agents: store.host(for: target)?.allAgents ?? []))
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard transcript == nil else { return }
            do {
                let loaded = try store.archive(for: target, sessionID: session.id)
                transcript = loaded
                await loaded.loadEarlier()
            } catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private func archiveEntry(_ entry: CompanionTimelineEntry) -> some View {
        switch entry {
        case .row(.item(let item)): archiveItem(item)
        case .row(.tools): EmptyView()
        case .slice(let message, let slice):
            CompanionMessageView(message: message, canRetry: false, retry: {}, slice: slice, expansion: store.transcriptExpansion(for: target, sessionID: session.id))
            if slice.isLast && message.role == .assistant {
                CompanionContentLinks(references: CompanionContentReference.references(in: .message(message)))
            }
        }
    }

    @ViewBuilder private func archiveItem(_ item: CompanionTimelineItem) -> some View {
        switch item {
        case .message(let message):
            CompanionMessageView(message: archived(message), canRetry: false, retry: {}, expansion: store.transcriptExpansion(for: target, sessionID: session.id))
            CompanionContentLinks(references: CompanionContentReference.references(in: item))
        case .tool(let tool):
            CompanionToolCard(tool: tool)
            CompanionContentLinks(references: CompanionContentReference.references(in: item))
        case .approval(let approval):
            VStack(alignment: .leading, spacing: 8) {
                Label(approval.title ?? approval.toolName, systemImage: "hand.raised").font(.headline)
                Text(approval.summary)
                if let detail = approval.detail { CompanionRichText(text: detail) }
                Text("Approval recorded in this session").font(.caption).foregroundStyle(.secondary)
            }
        case .question(let question):
            VStack(alignment: .leading, spacing: 8) {
                Label("Agent question", systemImage: "questionmark.bubble").font(.headline)
                ForEach(question.prompts) { Text($0.text) }
            }
        case .notice(_, let text): Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func archived(_ message: CompanionMessage) -> CompanionMessage {
        var value = message
        value.isStreaming = false
        return value
    }
    private func archived(_ item: CompanionTimelineItem) -> CompanionTimelineItem {
        guard case .message(let message) = item else { return item }
        return .message(archived(message))
    }
}
