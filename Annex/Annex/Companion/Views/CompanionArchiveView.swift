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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Label("Saved conversation · Read only", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.secondary) }
                if let transcript {
                    if transcript.isLoading { ProgressView("Loading messages…").frame(maxWidth: .infinity) }
                    if let error = transcript.error {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try again") { Task { await transcript.loadEarlier() } }
                    } else if transcript.nextBeforeSequence != nil {
                        Button("Load earlier messages", systemImage: "arrow.up.circle") { Task { await transcript.loadEarlier() } }
                            .disabled(transcript.isLoading).frame(maxWidth: .infinity)
                    }
                    ForEach(transcript.items) { item in
                        archiveItem(item).id(item.id)
                    }
                    if transcript.isLoaded && transcript.items.isEmpty {
                        ContentUnavailableView("No messages", systemImage: "bubble.left",
                                               description: Text("This saved session has no visible messages."))
                    }
                }
            }.padding(22).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(.systemGroupedBackground))
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

    @ViewBuilder private func archiveItem(_ item: CompanionTimelineItem) -> some View {
        switch item {
        case .message(let message):
            CompanionMessageView(message: archived(message), canRetry: false, retry: {})
            if message.role == .assistant { CompanionContentLinks(references: CompanionContentReference.files(in: message.text), store: store, target: target) }
        case .tool(let tool):
            CompanionToolCard(tool: tool)
            CompanionContentLinks(references: tool.images + CompanionContentReference.files(in: tool.output ?? ""), store: store, target: target)
        case .approval(let approval):
            VStack(alignment: .leading, spacing: 8) {
                Label(approval.toolName, systemImage: "hand.raised").font(.headline)
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
}
