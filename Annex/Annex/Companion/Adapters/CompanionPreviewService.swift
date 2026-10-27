import Foundation

/// Sample desktop for the welcome screen's "Look around first" demo (and App Review), and the DEBUG preview launch.
/// Never selected by pairing; every command fails with "Preview only".
@MainActor final class CompanionPreviewService: CompanionService {
    private var continuation: AsyncStream<CompanionEvent>.Continuation?
    /// UI tests stream tool updates into River's conversation (`--companion-preview-stream`).
    private let streamsUpdates: Bool
    static let target = CompanionTarget(hostID: "preview-studio", projectID: "clubhouse", agentID: "river")
    /// A sleeping durable agent, whose settings can all change.
    static let sleepingTarget = CompanionTarget(hostID: "preview-studio", projectID: "clubhouse", agentID: "juniper")
    init(streamsUpdates: Bool = false) { self.streamsUpdates = streamsUpdates }
    func events() -> AsyncStream<CompanionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.hosts([
                .init(id: Self.target.hostID, name: "Studio Mac", endpoint: "studio.local · Local network", connection: .connected, projects: [
                    .init(id: "clubhouse", name: "Clubhouse", agents: [
                        .init(id: Self.target, name: "River", subtitle: "Build the mobile companion", status: .approval, model: "Codex", capabilities: [.chat, .steer, .cancel, .approve, .images],
                              contextUsage: .init(used: 84_000, size: 200_000)),
                        .init(id: .init(hostID: Self.target.hostID, projectID: "clubhouse", agentID: "cedar"), name: "Cedar", subtitle: "Investigate reconnect behavior", status: .working, model: "Claude", capabilities: [.chat, .steer, .cancel, .approve],
                              turnStartedAt: Date().addingTimeInterval(-65)),
                        .init(id: Self.sleepingTarget, name: "Juniper", subtitle: "Release notes", status: .sleeping, model: "Claude", capabilities: [.chat, .wake])
                    ])
                ], richContentAvailable: true, canSpawn: true, canCreateDurable: true, canEditSettings: true, attachments: Self.attachments),
                .init(id: "preview-laptop", name: "Travel MacBook", endpoint: "travel.tailnet.ts.net · Tailscale", connection: .offline, projects: [
                    .init(id: "notes", name: "Field notes", agents: [
                        .init(id: .init(hostID: "preview-laptop", projectID: "notes", agentID: "river"), name: "River", subtitle: "Organize research notes", status: .idle)
                    ])
                ])
            ]))
            if self.streamsUpdates { Task { await self.streamToolUpdates() } }
        }
    }
    /// A running test command whose output grows, while read-only lookups start after it and fold into
    /// "Explored…" around it. The command, with its log link, is never folded; new ones keep starting.
    private func streamToolUpdates() async {
        var step = 0
        while true {
            try? await Task.sleep(for: .milliseconds(400))
            step += 1
            let run = step / 10
            let output = "Step \(step % 10) of 10\nLog: `build/test-log.txt`"
            var updates = [CompanionTool(id: "live-\(run)", name: "Run focused tests", summary: "$ swift test", output: output, state: step % 10 == 9 ? .completed : .running,
                                         kind: .execute, hasChanges: true)]
            for (index, at) in [2, 5].enumerated() where step % 10 >= at {
                updates.append(.init(id: "live-\(run)-read-\(index)", name: "Read file", summary: "Fixture\(index).swift", output: nil, state: step % 10 == at ? .running : .completed,
                                     kind: .read, location: "Tests/Fixture\(index).swift"))
            }
            for tool in updates {
                guard case .enqueued = continuation?.yield(.upsert(Self.target, .tool(tool), sequence: nil)) else { return }
            }
        }
    }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        .init(items: [
            .notice(id: "preview", text: "Preview conversation · no desktop commands are sent"),
            .message(.init(id: "user-1", role: .user, text: "Make it easy to continue a desktop agent from my phone. Focus on the conversation and the moments that need me.", timestamp: Date().addingTimeInterval(-180), source: "mission")),
            .message(.init(id: "agent-1", role: .assistant, text: "I’ve mapped out the companion experience. Each desktop keeps its own projects and agents, so you can move between them without losing your place.\n\nThe first pass puts **conversation, progress, and approvals** together. I’m checking the reconnect behavior next.", timestamp: Date().addingTimeInterval(-150))),
            // Read-only lookups fold into "Explored 2 files, 1 search"; the test run stays on its own, as on the desktop.
            .tool(.init(id: "tool-1", name: "Read file", summary: "Conversation.swift", output: "Read 246 lines from `Sources/Companion/Conversation.swift`.", state: .completed,
                        kind: .read, location: "Sources/Companion/Conversation.swift")),
            .tool(.init(id: "tool-1-search", name: "Search for reconnect", summary: "reconnect", output: "12 matches in 4 files", state: .completed, kind: .search)),
            .tool(.init(id: "tool-1-read", name: "Read file", summary: "Reconnect.swift", output: "Read 88 lines.", state: .completed,
                        kind: .read, location: "Sources/Companion/Reconnect.swift")),
            .tool(.init(id: "tool-2", name: "Run focused tests", summary: "$ swift test --filter ConversationTests", output: "8 tests passed. No failures.", state: .completed,
                        kind: .execute, hasChanges: true)),
            .message(.init(id: "agent-2", role: .assistant, text: "The draft now stays with its agent while the desktop reconnects. A missed event triggers a history refresh before another command can be sent.\n\n```swift\nlet target = ConversationTarget(\n    host: studio,\n    project: clubhouse,\n    agent: river\n)\n```", timestamp: Date().addingTimeInterval(-60))),
            .message(.init(id: "agent-3", role: .assistant, text: Self.statusReply, timestamp: Date().addingTimeInterval(-30))),
            // Two waiting approvals show "1 of 2"; "Always allow" is the desktop's to choose.
            .approval(.init(id: "approval-1", toolName: "Bash", summary: "Build the iOS application to verify the updated conversation layout.", title: "Run xcodebuild",
                            detail: "xcodebuild -scheme ClubhouseGo -sdk iphonesimulator build", deadline: Date().addingTimeInterval(600), options: [
                .init(id: "allow-once", label: "Allow once", kind: .allowOnce),
                .init(id: "allow-always", label: "Always allow", kind: .allowAlways, scope: "xcodebuild:*"),
                .init(id: "reject-once", label: "Deny", kind: .rejectOnce)
            ])),
            .approval(.init(id: "approval-2", toolName: "Write", summary: "Docs/Companion.md", title: "Edit Docs/Companion.md", deadline: Date().addingTimeInterval(600), options: [
                .init(id: "allow-once-2", label: "Allow once", kind: .allowOnce),
                .init(id: "reject-once-2", label: "Deny", kind: .rejectOnce)
            ]))
        ])
    }
    /// Exercises block Markdown: a heading, a GFM table with aligned columns, and a task list.
    static let statusReply = """
    ## Reconnect status

    | Check | Result | Time |
    |:------|:------:|-----:|
    | Resume after sleep | Passed | 1.2 s |
    | Missed events | Refreshed | 0.4 s |

    - [x] Keep drafts per agent
    - [ ] Retry when the network changes

    > Commands wait until the history refresh finishes.
    """
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        throw CompanionServiceError.unavailable("Preview only. Pair a desktop to send messages.")
    }
    /// The desktop's advertised limits, so the attach button shows. Uploads are kept on the phone; the send then fails as above.
    static let attachments = CompanionAttachmentLimits(imageTypes: ["image/png", "image/jpeg", "image/gif", "image/webp"], maxImageBytes: 3_932_160, maxCount: 10)
    func upload(_ image: CompanionImageAttachment, target: CompanionTarget) async throws -> String {
        try await Task.sleep(for: .milliseconds(200))
        return "preview-\(image.id)"
    }
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        guard case .file(let path) = reference else { throw previewError }
        try await Task.sleep(for: .milliseconds(300))
        let name = (path as NSString).lastPathComponent
        return .init(kind: "text", name: name, mimeType: "text/plain", text: "// \(name) · sample preview\nstruct Conversation {\n    var target: ConversationTarget\n    var draft = \"\"\n}")
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw previewError }
    func reconnect(hostID: String) async {}
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        .init(options: Self.agentOptions,
              mcpCatalog: [.init(id: "github", name: "GitHub", description: "Issues and pull requests"), .init(id: "ado", name: "Azure DevOps", description: nil)],
              mcpDefaults: ["github"], isGitRepo: true, suggestedName: "brave-otter", defaultOrchestrator: "claude-code",
              defaultColor: "indigo", defaultModel: "default", defaultUseWorktree: true)
    }
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt { throw previewError }
    /// River is awake, so its spawn settings are locked; Juniper sleeps, so everything but Free Agent Mode can change.
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        let sleeping = target == Self.sleepingTarget
        let name = sleeping ? "Juniper" : "River"
        return .init(state: sleeping ? "sleeping" : "running", sleeping: sleeping,
                     name: .init(value: name, editable: .sleeping), color: .init(value: sleeping ? "violet" : "indigo", editable: .sleeping),
                     emoji: .init(value: nil, editable: .sleeping),
                     orchestrator: .init(value: nil, editable: .sleeping), resolvedOrchestrator: "claude-code",
                     model: .init(value: "opus", editable: .sleeping),
                     runtime: .init(value: "default", editable: .sleeping), resolvedRuntime: "chat",
                     persona: .init(value: nil, editable: .sleeping),
                     clubhouseMode: .init(value: nil, editable: .never),
                     freeAgentMode: .init(value: false, editable: .never),
                     idleSleep: .init(value: .inherit, editable: .always),
                     options: Self.agentOptions, idleSleepMinutes: [15, 30, 60, 240], appIdleMinutes: 30)
    }
    func updateSettings(_ change: CompanionSettingsChange, target: CompanionTarget, clientCommandID: String) async throws -> CompanionAgentSettings {
        throw previewError
    }
    private static let agentOptions = CompanionAgentOptions(
        orchestrators: [
            .init(id: "claude-code", displayName: "Claude Code", shortName: "CC", available: true, permissions: true, chat: true,
                  models: [.init(id: "default", label: "Default"), .init(id: "opus", label: "Opus"), .init(id: "sonnet", label: "Sonnet")]),
            .init(id: "codex", displayName: "Codex", shortName: "CX", available: false, unavailableReason: nil, permissions: false, chat: false,
                  models: [.init(id: "default", label: "Default")]),
        ],
        personas: [.init(id: "qa", name: "QA", source: "builtin"), .init(id: "reviewer", name: "Reviewer", source: "project")],
        colors: [("indigo", "Indigo", "#6366f1"), ("emerald", "Emerald", "#10b981"), ("amber", "Amber", "#f59e0b"), ("rose", "Rose", "#f43f5e"),
                 ("cyan", "Cyan", "#06b6d4"), ("violet", "Violet", "#8b5cf6"), ("orange", "Orange", "#f97316"), ("teal", "Teal", "#14b8a6")]
            .map { CompanionColorOption(id: $0.0, label: $0.1, hex: $0.2) })
    private var previewError: CompanionServiceError { .unavailable("Preview only. This action does not contact a desktop.") }
}
