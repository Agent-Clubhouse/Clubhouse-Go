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
    /// UI tests add River's helper requests to Needs you (`--companion-preview-helper-requests`). Off by default, so
    /// Home's layout stays as the other previews expect.
    private let showsHelperRequests: Bool
    /// UI tests add Sequoia, an agent that runs in a terminal, to Website (`--companion-preview-terminal-agent`).
    private let showsTerminalAgent: Bool
    static let terminalAgentTarget = CompanionTarget(hostID: "preview-studio", projectID: "website", agentID: "sequoia")
    /// UI tests add a reply with a wide, many-row table and a long code block (`--companion-preview-long-blocks`).
    private let showsLongBlocks: Bool
    /// UI tests add a reply of about 10,000 words with large blocks in it (`--companion-preview-long-reply`).
    private let showsLongReply: Bool
    /// UI tests turn on the desktop's Dispatcher, pinned above the projects, and its relayed task in River's chat (`--companion-preview-dispatcher`).
    private let showsDispatcher: Bool
    static let dispatcherTarget = CompanionTarget(hostID: "preview-studio", projectID: CompanionDispatcher.defaultProjectID, agentID: "durable_dispatcher")
    init(streamsUpdates: Bool = false, showsHelperRequests: Bool = false, showsTerminalAgent: Bool = false, showsLongBlocks: Bool = false,
         showsLongReply: Bool = false, showsDispatcher: Bool = false) {
        self.showsDispatcher = showsDispatcher
        self.streamsUpdates = streamsUpdates
        self.showsHelperRequests = showsHelperRequests
        self.showsTerminalAgent = showsTerminalAgent
        self.showsLongBlocks = showsLongBlocks
        self.showsLongReply = showsLongReply
    }
    func events() -> AsyncStream<CompanionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.hosts(Self.hosts(now: Date(), helperRequests: self.showsHelperRequests ? Self.helperRequests : [],
                                                 terminalAgent: self.showsTerminalAgent, dispatcher: self.showsDispatcher)))
            if self.streamsUpdates { Task { await self.streamToolUpdates() } }
        }
    }
    /// River orchestrates: it asks to start a helper, and to dispose Cedar, which has work that would be lost.
    /// (Not a sleeping agent: those start folded on Home.)
    static let helperRequests: [CompanionHelperRequest] = [
        .init(id: "hstart_preview", hostID: target.hostID, projectID: "clubhouse", kind: .start, requesterID: target.agentID, requesterName: "River",
              helperName: "docs-pass", requestedAt: Date().addingTimeInterval(-240), expiresAt: Date().addingTimeInterval(86_000),
              summary: "Wants to start the helper docs-pass", task: "Update the reconnect section of the README"),
        .init(id: "hdispose_preview", hostID: target.hostID, projectID: "clubhouse", kind: .dispose, requesterID: target.agentID, requesterName: "River",
              helperID: "cedar", helperName: "Cedar", requestedAt: Date().addingTimeInterval(-120),
              summary: "River asked to dispose this helper. 2 uncommitted files, 1 unpushed commit.",
              dispose: .init(uncommittedFiles: 2, unpushedCommits: 1, unmergedCommits: 1, workAtRisk: true)),
    ]
    /// A running test command whose output grows, while read-only lookups start after it and fold into
    /// "Explored…" around it. The command, with its log link, is never folded; new ones keep starting.
    private func streamToolUpdates() async {
        var step = 0
        while true {
            try? await Task.sleep(for: .milliseconds(400))
            step += 1
            let run = step / 10
            let output = "Step \(step % 10) of 10\nLog: `build/test-log.txt`"
            var updates = [CompanionTool(id: "live-\(run)", name: "swift test", summary: "", output: output, state: step % 10 == 9 ? .completed : .running,
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
    /// Clubhouse has awake, sleeping and finished quick agents; Website is quieter; Old prototype has been idle for weeks.
    static func hosts(now: Date, helperRequests: [CompanionHelperRequest] = [], terminalAgent: Bool = false, dispatcher: Bool = false) -> [CompanionHost] {
        let host = target.hostID
        func agent(_ project: String, _ id: String, _ name: String, _ subtitle: String, _ status: CompanionAgentStatus, model: String? = nil,
                   minutesAgo: Double, color: String? = nil, quick: Bool = false, freeAgent: Bool = false, extra: CompanionCapabilities = [],
                   turnStartedAt: Date? = nil, contextUsage: CompanionContextUsage? = nil, executionMode: String? = nil,
                   branch: String? = nil, orchestrator: String? = nil, session: CompanionSessionFacts? = nil,
                   chatControls: CompanionChatControls? = nil, slashCommands: [CompanionSlashCommand]? = nil, exitCode: Int? = nil) -> CompanionAgent {
            let capabilities: CompanionCapabilities = switch status {
            case .sleeping: [.chat, .wake]
            case .completed: []
            default: [.chat, .steer, .cancel, .approve]
            }
            var agent = CompanionAgent(id: .init(hostID: host, projectID: project, agentID: id), name: name, subtitle: subtitle, status: status, model: model,
                                       capabilities: capabilities.union(extra),
                                       lastActivity: now.addingTimeInterval(-minutesAgo * 60), turnStartedAt: turnStartedAt, contextUsage: contextUsage)
            agent.color = color; agent.isQuick = quick; agent.freeAgentMode = freeAgent
            agent.executionMode = executionMode; agent.branch = branch; agent.orchestrator = orchestrator; agent.session = session
            agent.chatControls = chatControls
            agent.slashCommands = slashCommands
            // Sleeping preview agents have run before, so they offer Wake & Resume and Start New Session.
            if status == .sleeping { agent.hasSession = true }
            // A finished quick agent has exited, so it shows in the project page's "Finished, waiting on you".
            agent.hasExited = quick && (status == .completed || status == .failed); agent.exitCode = exitCode
            return agent
        }
        return [
            .init(id: host, name: "Studio Mac", endpoint: "studio.local · Local network", connection: .connected, projects: [
                .init(id: "website", name: "Website", agents: [
                    agent("website", "maple", "Maple", "Refresh the pricing page", .idle, minutesAgo: 90, color: "teal")
                ] + (terminalAgent ? [agent("website", terminalAgentTarget.agentID, "Sequoia", "Tidy the release checklist", .working, minutesAgo: 2,
                                            color: "orange", executionMode: "pty", orchestrator: "claude-code")] : []),
                      color: "teal", emoji: "🌐"),
                .init(id: "clubhouse", name: "Clubhouse", agents: [
                    agent("clubhouse", "cedar", "Cedar", "Investigate reconnect behavior", .working, model: "Claude", minutesAgo: 4, color: "emerald", freeAgent: true,
                          turnStartedAt: now.addingTimeInterval(-65)),
                    agent("clubhouse", sleepingTarget.agentID, "Juniper", "Release notes", .sleeping, model: "Claude", minutesAgo: 60 * 30, color: "violet",
                          orchestrator: "claude-code"),
                    agent("clubhouse", "lint", "Fix lint warnings", "Fix lint warnings", .completed, minutesAgo: 45, quick: true),
                    agent("clubhouse", "quick-willow", "willow", "Tidy the onboarding copy", .completed, minutesAgo: 12, quick: true, exitCode: 0),
                    // Completed rather than failed, so it folds on Home instead of joining Needs you; its exit code still shows.
                    agent("clubhouse", "quick-aspen", "aspen", "Run the release checklist", .completed, minutesAgo: 180, quick: true, exitCode: 1),
                    agent("clubhouse", target.agentID, "River", "Build the mobile companion", .approval, model: "Opus", minutesAgo: 1, color: "indigo", extra: .images,
                          contextUsage: .init(used: 84_000, size: 200_000), executionMode: "chat", branch: "river/companion", orchestrator: "claude-code",
                          session: riverSession, chatControls: chatControls, slashCommands: slashCommands)
                ], color: "indigo"),
                .init(id: "prototype", name: "Old prototype", agents: [
                    agent("prototype", "birch", "Birch", "Spike the sync engine", .sleeping, minutesAgo: 60 * 24 * 21, color: "amber")
                ], color: "amber", emoji: "🧪")
            ], richContentAvailable: true, canSpawn: true, canCreateDurable: true, canEditSettings: true,
               canAnswerPersistentApprovals: true, canSetFreeAgentMode: true, canOrchestrate: true, providers: [.init(id: "claude-code", name: "Claude Code")], attachments: attachments,
               canAnswerHelperRequests: true, helperRequests: helperRequests,
               terminal: .init(projectShell: true, agentShell: true, agentAttach: true),
               dispatcher: dispatcher ? Self.dispatcher(now: now) : nil),
            .init(id: "preview-laptop", name: "Travel MacBook", endpoint: "travel.tailnet.ts.net · Tailscale", connection: .offline, projects: [
                .init(id: "notes", name: "Field notes", agents: [
                    .init(id: .init(hostID: "preview-laptop", projectID: "notes", agentID: "river"), name: "River", subtitle: "Organize research notes", status: .idle)
                ])
            ])
        ]
    }
    /// The Dispatcher, idle after handing River a task.
    static func dispatcher(now: Date) -> CompanionDispatcher {
        var agent = CompanionAgent(id: dispatcherTarget, name: CompanionDispatcher.name, subtitle: "", status: .idle, model: "Opus",
                                   capabilities: [.chat, .steer, .cancel, .approve], executionMode: "chat", lastActivity: now.addingTimeInterval(-3 * 60))
        agent.isDispatcher = true; agent.freeAgentMode = true; agent.color = "cyan"; agent.orchestrator = "claude-code"
        agent.detail = .init(state: "idle", message: "Sent River the reconnect follow-up")
        return .init(enabled: true, flagOn: true, canToggle: true, agent: agent)
    }
    /// The Dispatcher's chat: your request, and its report back.
    static let dispatcherHistory: [CompanionTimelineItem] = [
        .notice(id: "preview", text: "Preview conversation · no desktop commands are sent"),
        .message(.init(id: "dispatcher-user-1", role: .user, text: "Get the reconnect fix finished and tell me when it's in review.", timestamp: Date().addingTimeInterval(-400))),
        .message(.init(id: "dispatcher-agent-1", role: .assistant, text: "I've asked **River** in Clubhouse to finish the reconnect fix and open a PR. I'll report back when it's ready for review.",
                       timestamp: Date().addingTimeInterval(-380))),
    ]
    /// A burst delivered as one MCP event: raw delivery stays whole, but chat shows each routed message separately.
    static let relayedTask = CompanionTimelineItem.message(.init(id: "relay-1", role: .user,
        text: """
        4 updates, oldest first:

        --- 1 of 4 ---
        [TASK:dsp-42] [FROM:Dispatcher] Finish the reconnect fix and open a PR. Report back when it's in review.

        --- 2 of 4 ---
        [FROM:Reviewer] The reconnect tests pass. The PR is ready for review.

        --- 3 of 4 ---
        [Clubhouse] All helper updates have been delivered.

        --- 4 of 4 ---
        The review notes are attached to the PR.
        """,
        timestamp: Date().addingTimeInterval(-370), source: "mcp", routed: [
            .init(sender: .init(agentID: "durable_dispatcher", name: "Dispatcher"),
                  text: "Finish the reconnect fix and open a PR. Report back when it's in review."),
            .init(sender: .init(name: "Reviewer"), text: "The reconnect tests pass. The PR is ready for review."),
            .init(fromClubhouse: true, text: "All helper updates have been delivered."),
            .init(text: "The review notes are attached to the PR.")
        ]))
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        if target == Self.dispatcherTarget { return .init(items: Self.dispatcherHistory) }
        return .init(items: [
            .notice(id: "preview", text: "Preview conversation · no desktop commands are sent"),
            .message(.init(id: "user-1", role: .user, text: "Make it easy to continue a desktop agent from my phone. Focus on the conversation and the moments that need me.", timestamp: Date().addingTimeInterval(-180), source: "mission")),
            .message(.init(id: "agent-1", role: .assistant, text: "I’ve mapped out the companion experience. Each desktop keeps its own projects and agents, so you can move between them without losing your place.\n\nThe first pass puts **conversation, progress, and approvals** together. I’m checking the reconnect behavior next.", timestamp: Date().addingTimeInterval(-150))),
            // Read-only lookups fold into "Explored 2 files, 1 search"; the test run stays on its own, as on the desktop.
            .tool(.init(id: "tool-1", name: "Read file", summary: "Conversation.swift", output: "Read 246 lines from `Sources/Companion/Conversation.swift`.", state: .completed,
                        kind: .read, location: "Sources/Companion/Conversation.swift")),
            .tool(.init(id: "tool-1-search", name: "Search for reconnect", summary: "reconnect", output: "12 matches in 4 files", state: .completed, kind: .search)),
            .tool(.init(id: "tool-1-read", name: "Read file", summary: "Reconnect.swift", output: "Read 88 lines.", state: .completed,
                        kind: .read, location: "Sources/Companion/Reconnect.swift")),
            .tool(.init(id: "tool-2", name: "swift test --filter ConversationTests", summary: "", output: "8 tests passed. No failures.\nLog: `/Users/river/clubhouse/.build/test.log` (`/tmp/scratch.txt` stays unlinked)", state: .completed,
                        kind: .execute, hasChanges: true)),
            .message(.init(id: "agent-2", role: .assistant, text: "The draft now stays with its agent while the desktop reconnects. A missed event triggers a history refresh before another command can be sent.\n\n```swift\nlet target = ConversationTarget(\n    host: studio,\n    project: clubhouse,\n    agent: river\n)\n```", timestamp: Date().addingTimeInterval(-60))),
            .message(.init(id: "agent-3", role: .assistant, text: Self.statusReply, timestamp: Date().addingTimeInterval(-30))),
        ] + (showsDispatcher ? [Self.relayedTask] : []) + (showsLongBlocks ? [
            .message(.init(id: "agent-4", role: .assistant, text: Self.longTableReply, timestamp: Date().addingTimeInterval(-20))),
            .message(.init(id: "agent-5", role: .assistant, text: Self.longCodeReply, timestamp: Date().addingTimeInterval(-15)))
        ] : []) + (showsLongReply ? [
            .message(.init(id: "agent-6", role: .assistant, text: Self.longReply, timestamp: Date().addingTimeInterval(-10)))
        ] : []) + [
            // Two waiting approvals show "1 of 2"; "Always allow" is a secondary action, confirmed first.
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
        ], contentRoots: .init(paths: ["/Users/river/clubhouse"]))
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
    /// A table wider than the phone with many rows, one of which wraps, ending in a row the UI test scrolls to (#180).
    static let longTableReply: String = {
        let areas = ["Desktop", "Phone", "Relay", "Pairing", "Archive", "Composer", "Approvals", "Previews", "Themes", "Telemetry", "Sync", "Search", "Settings"]
        let rows = areas.enumerated().map { index, area in
            let change = index == 0 ? "Upgraded to Electron 45.1 with dependency security fixes, and moved the updater onto the new signing key"
                : "Reworked \(area.lowercased()) so it keeps its place across reconnects"
            return "| \(area) | \(change) | Passed | \(index % 3 == 0 ? "River" : "Cedar") | Checked on iPhone and iPad in light and dark mode |"
        }
        return """
        Here is the release summary.

        | Area | Change | Result | Owner | Notes |
        |:-----|:-------|:------:|:------|:------|
        \(rows.joined(separator: "\n"))
        | Wrap-up | Final row of the release table | Passed | River | The last row |
        """
    }()
    /// A long code block with one line wider than the phone, ending in a line the UI test scrolls to (#180).
    static let longCodeReply: String = {
        let code = (1...60).map { "    step(\($0), label: \"Release check \($0)\")" }
        return """
        ```typescript
        function releaseChecks(step: (index: number, options: { label: string }) => void) {
        \(code.joined(separator: "\n"))
            step(61, { label: "A deliberately long line that runs well past the edge of the phone screen so it must scroll sideways" })
        }
        // End of the release checks
        ```
        """
    }()
    /// About 10,000 words: a hundred plain paragraphs, one unbroken paragraph of 1,500 words, headings, a long list,
    /// and the large table and code block from `longTableReply` and `longCodeReply`. It starts and ends with a line the UI test finds (#188).
    static let longReply: String = {
        let topics = ["reconnect", "pairing", "drafts", "approvals", "archive", "streaming", "themes", "previews", "telemetry", "search"]
        func paragraph(_ index: Int, sentences: Int) -> String {
            (0..<sentences).map { sentence in
                let topic = topics[(index + sentence) % topics.count]
                return "Section \(index) note \(sentence + 1) checks that \(topic) keeps its place while the phone sleeps, wakes and reconnects to the desktop."
            }.joined(separator: " ")
        }
        var parts = ["Start of the long reply."]
        for index in 1...100 {
            if index % 20 == 1 { parts.append("## Part \(index / 20 + 1)") }
            parts.append(paragraph(index, sentences: 4))
            if index == 30 { parts.append(paragraph(0, sentences: 75)) }
            if index == 50 { parts += [longTableReply, longCodeReply] }
            if index == 70 { parts.append((1...60).map { "\($0). Check \(topics[$0 % topics.count]) on iPhone and iPad, in light and dark mode." }.joined(separator: "\n")) }
        }
        parts.append("End of the long reply.")
        return parts.joined(separator: "\n\n")
    }()
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
    /// River's composer controls, matching its session: every level is live, and model and effort changes apply from the next message.
    /// River's `/` menu: the CLI's own commands (start only), a skill and a custom command.
    static let slashCommands: [CompanionSlashCommand] = [
        .init(name: "compact", description: "Clear conversation history but keep a summary in context", startOnly: true),
        .init(name: "clear", description: "Clear conversation history and free up context", startOnly: true),
        .init(name: "review", description: "Review a pull request", inputHint: "<pr>"),
        .init(name: "commit", description: "Commit the staged changes with a good message"),
        .init(name: "frontend-design", description: "Create distinctive, production-grade frontend interfaces"),
    ]
    static let chatControls = CompanionChatControls(
        model: "opus", effort: "high", effortReported: true, level: .autoEdit,
        models: [.init(id: "opus", label: "Opus", description: "Most capable for complex work", costHint: "1x"),
                 .init(id: "sonnet", label: "Sonnet", description: "Fast for everyday tasks", costHint: "0.6x"),
                 .init(id: "haiku", label: "Haiku", description: "Fastest for quick answers", costHint: "0.2x")],
        efforts: ["low", "medium", "high", "xhigh"],
        levelNames: [.plan: "plan", .ask: "default", .autoEdit: "acceptEdits", .auto: "auto", .fullAccess: "bypassPermissions"],
        liveLevels: CompanionPermissionLevel.allCases, modelSwitch: .perTurn, effortSwitch: .perTurn, effortDefault: true)
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw previewError }
    func reconnect(hostID: String) async {}
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        .init(options: Self.agentOptions,
              mcpCatalog: [.init(id: "github", name: "GitHub", description: "Issues and pull requests"), .init(id: "ado", name: "Azure DevOps", description: nil)],
              mcpDefaults: ["github"], isGitRepo: true, suggestedName: "brave-otter", defaultOrchestrator: "claude-code",
              defaultColor: "indigo", defaultModel: "default", defaultUseWorktree: true, freeAgentModeAllowed: true)
    }
    func create(_ request: CompanionCreateRequest) async throws -> CompanionCreateReceipt { throw previewError }
    func answerHelperRequest(_ request: CompanionHelperRequest, approve: Bool, force: Bool, clientCommandID: String) async throws { throw previewError }
    /// River is awake, so its spawn settings are locked; Juniper sleeps, so everything can change.
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        if target == Self.dispatcherTarget { return Self.dispatcherSettings }
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
                     freeAgentMode: .init(value: false, editable: .sleeping),
                     idleSleep: .init(value: .inherit, editable: .always),
                     options: Self.agentOptions, idleSleepMinutes: [15, 30, 60, 240], appIdleMinutes: 30,
                     workspace: sleeping ? Self.juniperWorkspace : Self.riverWorkspace,
                     orchestration: sleeping ? Self.juniperOrchestration : CompanionOrchestration())
    }
    /// What the desktop lets you change on the Dispatcher: its CLI, model, runtime, Free Agent Mode and auto-sleep.
    static let dispatcherSettings = CompanionAgentSettings(
        state: "running", sleeping: false, name: .init(value: CompanionDispatcher.name, editable: .never), color: .init(value: "cyan", editable: .never),
        emoji: .init(value: nil, editable: .never), orchestrator: .init(value: "claude-code", editable: .always), resolvedOrchestrator: "claude-code",
        model: .init(value: "opus", editable: .always), runtime: .init(value: "chat", editable: .always), resolvedRuntime: "chat",
        persona: .init(value: nil, editable: .never), clubhouseMode: .init(value: nil, editable: .never),
        freeAgentMode: .init(value: true, editable: .always), idleSleep: .init(value: .never, editable: .always),
        options: agentOptions, idleSleepMinutes: [15, 30, 60, 240], appIdleMinutes: 30)
    /// Juniper orchestrates, asking before each helper starts; River doesn't.
    static let juniperOrchestration = CompanionOrchestration(orchestrate: true, control: "ask-before-start", maxHelpers: 3,
                                                             sources: ["orchestrate": .agent, "control": .agent, "maxHelpers": .agent])
    /// What River's chat session reported: the CLI version, effort, permission level and the MCP servers it loaded.
    static let riverSession = CompanionSessionFacts(cliVersion: "2.1.4", effort: "high", level: "auto_edit", mcpServers: [
        .init(name: "clubhouse", status: .connected), .init(name: "github", status: .connected), .init(name: "linear", status: .needsAuth),
    ])
    static let riverWorkspace = CompanionAgentWorkspace(
        branch: "river/companion", worktreePath: "/Users/preview/Clubhouse/.clubhouse/agents/river", worktree: ".clubhouse/agents/river",
        mcpIDs: ["github", "figma"],
        changes: .init(base: "main", files: 6, additions: 94, deletions: 51, ahead: 2, uncommitted: 1))
    /// Juniper works in the project folder, with nothing changed.
    static let juniperWorkspace = CompanionAgentWorkspace(branch: "main", changes: .init(base: "main", ahead: 0, uncommitted: 0))
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
    /// The project root's changes: one of each status, with a long line to scroll sideways.
    func changes(for project: CompanionProjectTarget) async throws -> CompanionChanges {
        try await Task.sleep(for: .milliseconds(200))
        return .init(isRepository: true, branch: "main", files: [
            .init(path: "Sources/Companion/Conversation.swift", code: "M", staged: false),
            .init(path: "Sources/Companion/ProjectPage.swift", code: "??", staged: false),
            .init(path: "Docs/Old notes.md", code: "D", staged: true),
            .init(path: "Sources/Companion/Reconnect.swift", originalPath: "Sources/Companion/Retry.swift", code: "R", staged: true)
        ], ahead: 2)
    }
    func diff(of file: CompanionChangedFile, in project: CompanionProjectTarget) async throws -> CompanionFileDiff {
        try await Task.sleep(for: .milliseconds(200))
        switch file.status {
        case .added: return .make(path: file.path, original: "", modified: "struct ProjectPage {\n    var finished: [Run]\n}\n")
        case .deleted: return .make(path: file.path, original: "# Old notes\n\nNothing to keep.\n", modified: nil)
        case .modified, .renamed:
            let base = (1...12).map { "    // line \($0)" }
            var edited = base
            edited[5] = "    // line 6, edited to explain why a reconnect refreshes the conversation before another command can be sent to the desktop"
            edited.insert("    let target: ConversationTarget", at: 1)
            return .make(path: file.path, original: (["struct Conversation {"] + base + ["}"]).joined(separator: "\n"),
                         modified: (["struct Conversation {"] + edited + ["}"]).joined(separator: "\n"))
        }
    }
    /// A fake shell that echoes, and a terminal-mode agent's screen.
    func terminal(_ scope: CompanionTerminalScope) throws -> any CompanionTerminalChannel { CompanionPreviewTerminalChannel(scope: scope) }
    private var previewError: CompanionServiceError { .unavailable("Preview only. This action does not contact a desktop.") }
}
