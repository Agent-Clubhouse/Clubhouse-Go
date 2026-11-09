import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Sample desktop for the welcome screen's "Look around first" demo (and App Review), and the DEBUG preview launch.
/// Never selected by pairing; every command fails with "Preview only".
@MainActor final class CompanionPreviewService: CompanionService {
    // ARC-only teardown; reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
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
    private let showsReadingScenario: Bool
    private let showsEmptyConversation: Bool
    private let showsKeyboardInteractions: Bool
    /// UI tests turn on the desktop's Dispatcher, pinned above the projects, and its relayed task in River's chat (`--companion-preview-dispatcher`).
    private let showsDispatcher: Bool
    private let showsMultipleDispatchers: Bool
    private let showsHelperIdentity: Bool
    private let showsHelperTree: Bool
    private let showsQuestions: Bool
    private let showsContextWindow: Bool
    private var editedHelperPresets: CompanionHelperRouting?
    /// The hosts last sent, so a Dispatcher settings change can send them again.
    private var sentHosts: [CompanionHost] = []
    /// Settings > Dispatcher on its preview Dispatcher (`--companion-preview-dispatcher-settings`). Set before `events()`.
    var showsDispatcherSettings: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--companion-preview-dispatcher-settings")
        #else
        false
        #endif
    }()
    private let showsHelperPresets: Bool
    private let showsAutoQuota: Bool
    static let dispatcherTarget = CompanionTarget(hostID: "preview-studio", projectID: CompanionDispatcher.defaultProjectID, agentID: "durable_dispatcher")
    init(streamsUpdates: Bool = false, showsHelperRequests: Bool = false, showsTerminalAgent: Bool = false, showsLongBlocks: Bool = false,
         showsLongReply: Bool = false, showsDispatcher: Bool = false, showsMultipleDispatchers: Bool = false, showsHelperIdentity: Bool = false, showsHelperTree: Bool = false,
         showsQuestions: Bool = false, showsContextWindow: Bool = false, showsReadingScenario: Bool = false, showsEmptyConversation: Bool = false, showsKeyboardInteractions: Bool = false, showsHelperPresets: Bool = false, showsAutoQuota: Bool = false) {
        self.showsQuestions = showsQuestions
        self.showsAutoQuota = showsAutoQuota
        self.showsHelperPresets = showsHelperPresets || showsAutoQuota
        self.showsContextWindow = showsContextWindow
        self.showsHelperTree = showsHelperTree
        self.showsReadingScenario = showsReadingScenario
        self.showsEmptyConversation = showsEmptyConversation
        self.showsKeyboardInteractions = showsKeyboardInteractions
        self.showsHelperIdentity = showsHelperIdentity
        self.showsDispatcher = showsDispatcher
        self.showsMultipleDispatchers = showsMultipleDispatchers
        self.streamsUpdates = streamsUpdates
        self.showsHelperRequests = showsHelperRequests
        self.showsTerminalAgent = showsTerminalAgent
        self.showsLongBlocks = showsLongBlocks
        self.showsLongReply = showsLongReply
    }
    #if DEBUG
    private static var reportOnlyPolicy: CompanionOrchestration {
        .init(mcpReportOnly: true, autoHelpers: true, autoHelpersEffective: false,
              sources: ["orchestrate": .agent, "crossProjectHelpers": .agent, "connectToDispatcher": .default, "autoHelpers": .agent])
    }
    #endif

    func events() -> AsyncStream<CompanionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            var hosts = Self.hosts(now: Date(), helperRequests: self.showsHelperRequests ? Self.helperRequests : [],
                                   terminalAgent: self.showsTerminalAgent, dispatcher: self.showsDispatcher, helperTree: self.showsHelperTree, contextWindow: self.showsContextWindow, helperPresets: self.showsHelperPresets, autoQuota: self.showsAutoQuota)
            if self.showsAutoQuota { hosts += Self.planLimitsHosts() }
            if self.showsMultipleDispatchers {
                hosts[1].connection = .connected
                hosts[1].dispatcher = Self.dispatcher(now: Date())
                let hostID = hosts[1].id
                hosts[1].dispatcher?.agent?.id.hostID = hostID
            }
            #if DEBUG
            // Synthetic Needs you states; no desktop connection or commands are made by this preview service.
            if ProcessInfo.processInfo.arguments.contains("--companion-preview-needs-you") {
                let scenario = ProcessInfo.processInfo.environment["COMPANION_NEEDS_YOU_SCENARIO"] ?? "one-offline"
                for index in hosts.indices {
                    hosts[index].hasLoadedCatalog = true
                    if scenario == "online-empty" || scenario == "all-unavailable" || scenario == "progress" {
                        for project in hosts[index].projects.indices {
                            for agent in hosts[index].projects[project].agents.indices {
                                hosts[index].projects[project].agents[agent].status = .idle
                            }
                        }
                    }
                }
                switch scenario {
                case "online-empty": hosts[1].connection = .connected
                case "all-unavailable": hosts[0].connection = .offline; hosts[1].connection = .failed("Preview connection lost")
                case "progress": hosts[0].connection = .reconnecting; hosts[1].connection = .synchronizing
                default: break
                }
                if !hosts[1].connection.canOperate {
                    hosts[1].projects[0].agents[0].status = .approval
                    hosts[1].projects[0].agents[0].name = "Cached offline request"
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--companion-preview-provider-control") { hosts[0].canControlProvider = true }
            // Clubhouse grant requests in Needs you (`--companion-preview-grant-requests`); their answers succeed.
            if Self.showsGrantRequests {
                hosts[0].canAnswerGrantRequests = true
                hosts[0].grantRequests = Self.grantRequests
            }
            if ProcessInfo.processInfo.arguments.contains("--companion-preview-report-only"),
               let project = hosts[0].projects.firstIndex(where: { $0.id == Self.sleepingTarget.projectID }),
               let agent = hosts[0].projects[project].agents.firstIndex(where: { $0.id == Self.sleepingTarget }) {
                hosts[0].projects[project].agents[agent].orchestration = Self.reportOnlyPolicy
                hosts[0].projects[project].agents[agent].parentAgentID = Self.target.agentID
            }
            // Exercise the narrowest composer with Interrupt, Attach, Send and the assistive dismiss button.
            if ProcessInfo.processInfo.arguments.contains("--companion-preview"),
               ProcessInfo.processInfo.arguments.contains("--companion-preview-assistive-keyboard"),
               let project = hosts[0].projects.firstIndex(where: { $0.id == Self.target.projectID }),
               let agent = hosts[0].projects[project].agents.firstIndex(where: { $0.id == Self.target }) {
                hosts[0].projects[project].agents[agent].status = .working
            }
            #endif
            if self.showsDispatcherSettings, hosts[0].dispatcher != nil {
                hosts[0].canEditDispatcherSettings = true
                hosts[0].dispatcherSettings = Self.previewDispatcherSettings
            }
            self.sentHosts = hosts
            continuation.yield(.hosts(hosts))
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
            if showsReadingScenario {
                continuation?.yield(.upsert(Self.target, .message(.init(id: "reading-live", role: .assistant,
                    text: String(repeating: "Streaming preview reply. ", count: step + (showsLongReply ? 100 : 0)), isStreaming: true)), sequence: nil))
            }
            for tool in updates {
                guard case .enqueued = continuation?.yield(.upsert(Self.target, .tool(tool), sequence: nil)) else { return }
            }
        }
    }
    /// Clubhouse has awake, sleeping and finished quick agents; Website is quieter; Old prototype has been idle for weeks.
    static func hosts(now: Date, helperRequests: [CompanionHelperRequest] = [], terminalAgent: Bool = false, dispatcher: Bool = false, helperTree: Bool = false,
                      contextWindow: Bool = false, helperPresets: Bool = false, autoQuota: Bool = false) -> [CompanionHost] {
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
            if !quick { agent.isSleepingOnDesktop = status == .sleeping }
            agent.executionMode = executionMode; agent.branch = branch; agent.orchestrator = orchestrator; agent.session = session
            agent.chatControls = chatControls
            agent.slashCommands = slashCommands
            // Sleeping preview agents have run before, so they offer Wake & Resume and Start New Session.
            if status == .sleeping { agent.hasSession = true }
            // A finished quick agent has exited, so it shows in the project page's "Finished, waiting on you".
            agent.hasExited = quick && (status == .completed || status == .failed); agent.exitCode = exitCode
            return agent
        }
        var hosts: [CompanionHost] = [
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
                          contextUsage: .init(used: 84_000, size: contextWindow ? 300_000 : 200_000), executionMode: "chat", branch: "river/companion", orchestrator: "claude-code",
                          session: riverSession, chatControls: contextWindow ? contextPreviewControls : chatControls, slashCommands: slashCommands)
                ], color: "indigo"),
                .init(id: "prototype", name: "Old prototype", agents: [
                    agent("prototype", "birch", "Birch", "Spike the sync engine", .sleeping, minutesAgo: 60 * 24 * 21, color: "amber")
                ], color: "amber", emoji: "🧪")
            ], richContentAvailable: true, canResolveLinks: true, canSpawn: true, canCreateDurable: true, canEditSettings: true, canStopAgents: true,
               canAnswerPersistentApprovals: true, canSetFreeAgentMode: true, canSetContextWindow: contextWindow, canOrchestrate: true, providers: [.init(id: "claude-code", name: "Claude Code")], attachments: attachments,
               canAnswerHelperRequests: true, helperRequests: helperRequests,
               terminal: .init(projectShell: true, agentShell: true, agentAttach: true),
               dispatcher: dispatcher ? Self.dispatcher(now: now) : nil),
            .init(id: "preview-laptop", name: "Travel MacBook", endpoint: "travel.tailnet.ts.net · Tailscale", connection: .offline, projects: [
                .init(id: "notes", name: "Field notes", agents: [
                    .init(id: .init(hostID: "preview-laptop", projectID: "notes", agentID: "river"), name: "River", subtitle: "Organize research notes", status: .idle)
                ])
            ])
        ]
        if helperPresets {
            hosts[0].helperRouting = Self.helperRoutingCapability
            hosts[0].canEditHelperPresets = true
            hosts[0].helperRoutingRevision = Self.helperPresets.revision
            hosts[0].helperRoutingLabels = Self.helperPresets.labels
            hosts[0].providers.append(.init(id: "codex-cli", name: "Codex CLI"))
            hosts[0].providers.append(.init(id: "copilot-cli", name: "Copilot"))
            hosts[0].projects[1].agents[1].orchestrator = "codex-cli"
            hosts[0].projects[1].agents[1].model = "gpt-6.1-sol"
            hosts[0].projects[1].agents[1].parentAgentID = Self.target.agentID
            hosts[0].projects[1].agents[1].routing = .init(mode: "preset", selection: .init(provider: "codex-cli", model: "gpt-6.1-sol", effort: "high", difficulty: "hard"), reason: "preset_on_cli")
            hosts[0].helperRequests = Self.helperRequests
            hosts[0].helperRequests[0].requestedRouting = .init(provider: "codex-cli", model: nil, effort: nil, difficulty: "hard")
        }
        if autoQuota {
            hosts[0].helperRouting = Self.autoQuotaCapability
            hosts[0].helperRoutingLabels = Self.autoQuotaPage(projectID: nil, agentID: nil).labels
            hosts[0].helperRequests[0].requestedRouting = .init(provider: "auto", difficulty: "hard")
            var warned = hosts[0].helperRequests[0]
            warned.id = "hstart_warning"
            warned.helperName = "Quill"
            warned.requestedRouting = .init(provider: "codex-cli", difficulty: "hard")
            warned.startWarning = Self.previewStartWarning
            hosts[0].helperRequests.append(warned)
            for p in hosts[0].projects.indices {
                for a in hosts[0].projects[p].agents.indices {
                    hosts[0].projects[p].agents[a].orchestration?.autoHelpers = nil
                    hosts[0].projects[p].agents[a].orchestration?.autoHelpersEffective = true
                }
            }
        }
        if helperTree {
            for p in hosts[0].projects.indices {
                for i in hosts[0].projects[p].agents.indices {
                    switch hosts[0].projects[p].agents[i].id.agentID {
                    case "cedar": hosts[0].projects[p].agents[i].status = .sleeping
                    case "river": hosts[0].projects[p].agents[i].parentAgentID = "cedar"
                    case "juniper": hosts[0].projects[p].agents[i].parentAgentID = "river"
                    case "maple": hosts[0].projects[p].agents[i].parentAgentID = "cedar"
                    default: break
                    }
                }
            }
            var elm = agent("clubhouse", "elm", "Elm", "Release prep", .sleeping, minutesAgo: 120)
            elm.parentAgentID = nil
            var moss = agent("clubhouse", "moss", "Moss", "Check release notes", .sleeping, minutesAgo: 121)
            moss.parentAgentID = "elm"
            hosts[0].projects[1].agents += [elm, moss]
        }
        if contextWindow, hosts[0].dispatcher?.agent != nil {
            var controls = contextPreviewControls
            controls.level = .fullAccess
            controls.context = .init(effectiveTokens: 258_400)
            hosts[0].dispatcher?.agent?.chatControls = controls
            hosts[0].dispatcher?.agent?.contextUsage = .init(used: 99_000, size: 300_000)
        }
        return hosts
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
    /// Exercise queue joins through the real projector, including dispatch with no delivered user_message.
    static let relayedTask: CompanionTimelineItem = {
        let texts = [
            "[TASK:dsp-42] [FROM:Dispatcher] Finish the reconnect fix and open a PR. Report back when it's in review.",
            "[FROM:Reviewer] The reconnect tests pass. The PR is ready for review.",
            "[Clubhouse] All helper updates have been delivered.",
            "The review notes are attached to the PR."
        ]
        let parts: [CompanionRoutedMessagePart] = [
            .init(sender: .init(agentID: "durable_dispatcher", name: "Dispatcher"),
                  text: "Finish the reconnect fix and open a PR. Report back when it's in review."),
            .init(sender: .init(name: "Reviewer"), text: "The reconnect tests pass. The PR is ready for review."),
            .init(fromClubhouse: true, text: "All helper updates have been delivered."),
            .init(text: "The review notes are attached to the PR.")
        ]
        var projection = CompanionChatProjector()
        func event(_ type: String, _ sequence: Int64, _ data: [String: AnnexJSON]) -> AnnexJSON {
            .object(["sessionId": .string("preview-queue"), "seq": .integer(sequence), "type": .string(type),
                     "ts": .integer(Int64(Date().addingTimeInterval(-370).timeIntervalSince1970 * 1000)), "data": .object(data)])
        }
        for index in texts.indices {
            var routed: [String: AnnexJSON] = ["text": .string(parts[index].text)]
            if let sender = parts[index].sender {
                var identity: [String: AnnexJSON] = ["name": .string(sender.name)]
                identity["agentId"] = sender.agentID.map(AnnexJSON.string)
                routed["sender"] = .object(identity)
            }
            if parts[index].fromClubhouse { routed["fromClubhouse"] = .bool(true) }
            var data: [String: AnnexJSON] = ["messageId": .string(index == 0 ? "relay-1" : "relay-join-\(index)"),
                "content": .array([.object(["type": .string("text"), "text": .string(texts[index])])]),
                "source": .string("mcp"), "delivery": .string("queued"), "routed": .array([.object(routed)])]
            if index > 0 { data["queuedWith"] = .string("relay-1") }
            projection.apply(event("user_message", Int64(index + 1), data))
        }
        projection.apply(event("queue_state", 5, ["queuedMessageIds": .array([]),
            "transition": .object(["messageIds": .array([.string("relay-1")]), "status": .string("delivered")])]))
        return projection.items[0]
    }()
    /// Preview-specific long routed messages and stale sender names exercise folding and identity resolution.
    static let longSenderText = "## Helper report\n\n" + Array(repeating: "The reconnect tests pass, and the saved conversation keeps each sender’s message and reading position.", count: 10).joined(separator: "\n\n")
    static let senderPreview = CompanionTimelineItem.message(.init(id: "sender-preview", role: .user,
        text: "[FROM HELPER:Old Cedar (cedar)] " + longSenderText,
        timestamp: Date().addingTimeInterval(-360), source: "mission", isSteered: true, routed: [
            .init(sender: .init(agentID: "cedar", name: "Old Cedar"), text: longSenderText),
            .init(sender: .init(name: "Maple"), text: String(repeating: "Another long update from the Website project. ", count: 20)),
            .init(sender: .init(name: "Maple"), text: "Short helper update."),
            .init(sender: .init(agentID: "quick-willow", name: "Old willow"), text: "Quick helper update.")
        ]))
    /// Synthetic version of Framebriar 1c74d5b8; no feedback media or private transcript is bundled.
    static let helperMessageHistory: [CompanionTimelineItem] = [
        .notice(id: "subagent-preview", text: "subagent · completed"),
        .tool(.init(id: "helper-read", name: "Read", summary: "Conversation.swift", state: .completed, subagentID: "helper-preview")),
        .message(.init(id: "helper-report", role: .user, text: "[FROM:Reviewer] The transcript fix is ready for review.", source: "mcp", routed: [
            .init(sender: .init(agentID: "cedar", name: "Old Cedar"), text: "The transcript fix is ready for review.")
        ])),
        .tool(.init(id: "helper-check", name: "Test", summary: "Transcript tests", state: .completed, subagentID: "helper-preview")),
        .message(.init(id: "helper-status", role: .user, text: "[Clubhouse] A helper has started its task.", source: "mcp", isSteered: true, routed: [
            .init(fromClubhouse: true, text: "A helper has started its task.")
        ])),
        .message(.init(id: "parent-reply", role: .assistant, text: "I’ll review the helper’s changes next."))
    ]
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        #if DEBUG && canImport(UIKit)
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-messages"), target == Self.target {
            return .init(items: Self.helperMessageHistory)
        }
        if CompanionContentAcceptanceFixture.enabled, target == Self.target {
            return CompanionContentAcceptanceFixture.history
        }
        #endif
        if showsEmptyConversation { return .init(items: []) }
        if showsKeyboardInteractions {
            return .init(items: [
                .message(.init(id: "keyboard-selectable", role: .assistant, text: "Selectable preview message.")),
                .tool(.init(id: "keyboard-tool", name: "Read file", summary: "Preview file", state: .completed)),
                .message(.init(id: "keyboard-file", role: .assistant, text: "Open `Sources/Companion/Conversation.swift`."))
            ])
        }
        if target.projectID == CompanionDispatcher.defaultProjectID {
            return .init(items: Self.dispatcherHistory + (showsLongReply ? [
                .message(.init(id: "dispatcher-long-reply", role: .assistant, text: Self.longReply))
            ] : []))
        }
        if showsQuestions {
            let prompt = CompanionQuestion.Prompt(id: "color", text: "Which color?", options: [.init(id: "red", label: "Red")], allowsMultiple: false, allowsFreeText: false)
            return .init(items: [
                .question(.init(id: "empty", prompts: [])),
                .question(.init(id: "partial", prompts: [prompt], hasUnreadablePrompts: true)),
                .question(.init(id: "complete", prompts: [prompt])),
            ], capabilities: [.chat, .answer])
        }
        if showsReadingScenario {
            return .init(items: (1...180).map { .message(.init(id: "reading-\($0)", role: .assistant,
                text: "Reading marker \($0).\n\nA stable preview paragraph for testing history, keyboard and streaming position.")) } + [
                    .tool(.init(id: "reading-failure", name: "Preview command", summary: "swift test", output: (1...12).map { "Failure output line \($0)" }.joined(separator: "\n") + "\nPreview error: build failed", state: .failed, exitCode: 2)),
                    .message(.init(id: "reading-helper", role: .assistant, text: "Preview helper streamed update.", isStreaming: true, subagentID: "preview-helper"))
                ])
        }
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
        ] + (showsDispatcher ? [Self.relayedTask, Self.senderPreview] : []) + (showsLongBlocks ? [
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
        #if DEBUG && canImport(UIKit)
        if CompanionContentAcceptanceFixture.enabled {
            guard target == Self.target else { throw previewError }
            return try CompanionContentAcceptanceFixture.content(path: path)
        }
        #endif
        try await Task.sleep(for: .milliseconds(300))
        let name = (path as NSString).lastPathComponent
        return .init(kind: "text", name: name, mimeType: "text/plain", text: "// \(name) · sample preview\nstruct Conversation {\n    var target: ConversationTarget\n    var draft = \"\"\n}")
    }
    func resolveLink(_ href: String, target: CompanionTarget) async throws -> CompanionLinkTarget {
        #if DEBUG && canImport(UIKit)
        if CompanionContentAcceptanceFixture.enabled {
            guard target == Self.target else { throw previewError }
            return CompanionContentAcceptanceFixture.resolve(href)
        }
        #endif
        try await Task.sleep(for: .milliseconds(200))
        let name = ((href.components(separatedBy: "#").first ?? href).removingPercentEncoding ?? href) as NSString
        return .file(path: "/Users/river/clubhouse/" + (name as String), name: name.lastPathComponent, kind: "text", size: nil)
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func sleepAgent(_ target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func sleepAndWait(_ target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func changeProvider(_ target: CompanionTarget, preview: AnnexProviderPreview, clientCommandID: String) async throws -> AnnexProviderChangeResult { throw previewError }
    func startNewProvider(_ target: CompanionTarget, provider: String, clientCommandID: String) async throws { throw previewError }
    func providerPreview(_ target: CompanionTarget, provider: String) async throws -> AnnexProviderPreview {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-provider-control") {
            let same = provider == "claude-code"
            return try AnnexJSON.object([
                "agentId": .string(target.agentID), "savedProvider": .string("claude-code"), "activeProvider": .null,
                "provider": .string(provider), "state": .string("sleeping"), "expectedState": .string("preview-only"),
                "available": .bool(true), "availabilityMeaning": .string("local_cli_only"), "instructions": .string("equivalent"),
                "instructionScope": .string("native_primary_only"), "targetRuntime": .string("chat"), "blocked": .null,
                "canSave": .bool(true), "historyRetained": .bool(true), "contextTransferred": .bool(false),
                "nextStart": .string(same ? "resume_requires_validation" : "new_session"),
                "settingsReset": .array(same ? [] : ["model", "effort", "contextWindow", "routing", "resumePointer"].map(AnnexJSON.string)),
            ]).decode(AnnexProviderPreview.self)
        }
        #endif
        throw previewError
    }
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
    /// Illustrative preview content only; these values don't validate a provider's plan or runtime behaviour.
    static let contextPreviewControls: CompanionChatControls = {
        var controls = chatControls
        controls.context = .init(effectiveTokens: 300_000, compactAtTokens: 267_000, reservedTokens: 33_000,
                                 note: "Preview: reported working context; the model's own window isn't changed.")
        return controls
    }()
    static func previewContext(editable: CompanionSettingEditable) -> CompanionContextWindow {
        .init(value: "500000", editable: editable, configurable: true, kind: .workingWindow,
              label: "Working context", description: "How much conversation the CLI keeps before it compacts. This doesn't change the model's own context window.",
              defaultLabel: "Auto", choices: [.init(id: "300000", label: "300K", tokens: 300_000), .init(id: "500000", label: "500K", tokens: 500_000)],
              maxTokens: 1_000_000, costNote: "Preview choices. A larger size sends more history with each message.", applies: [.launch, .resume])
    }
    func setModel(_ model: String, effort: CompanionEffortChoice?, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func setLevel(_ level: CompanionPermissionLevel, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func answer(_ questionID: String, answers: [String: CompanionAnswer], target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
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
    func answerGrantRequest(_ request: CompanionGrantRequest, answer: CompanionGrantRequest.Answer, clientCommandID: String) async throws {
        if Self.showsGrantRequests { return }
        throw previewError
    }
    #if DEBUG
    private static var showsGrantRequests: Bool { ProcessInfo.processInfo.arguments.contains("--companion-preview-grant-requests") }
    #else
    private static let showsGrantRequests = false
    #endif
    /// River's held Remove device call (Allow once or Decline) and Cedar asking for a lasting permission (Allow or Decline).
    static let grantRequests: [CompanionGrantRequest] = [
        .init(id: "grant_preview_call", hostID: target.hostID, projectID: target.projectID, kind: .call, agentID: target.agentID, agentName: "River",
              actionLabels: ["Manage devices"], whereLabel: "the app", toolName: "remove_device",
              summary: "Wants to run remove_device, which needs: Manage devices on the app.",
              detail: "Remove Travel iPad (tablet, in this network). A device in the network goes from every device in it, and comes back only when a person pairs it again.",
              arguments: "{\n  \"id\": \"aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99\"\n}", reason: "You said the iPad was lost.",
              allowEffect: "Allow runs this one call when it tries again. Its permissions stay as they are.",
              requestedAt: Date().addingTimeInterval(-300), expiresAt: Date().addingTimeInterval(86_000), answers: [.allowOnce, .decline]),
        .init(id: "grant_preview_ask", hostID: target.hostID, projectID: target.projectID, kind: .grant, agentID: "cedar", agentName: "Cedar",
              actionLabels: ["Change app settings"], whereLabel: "the app", summary: "Asks for Change app settings on the app.",
              reason: "To set the cheap model for easy tasks.",
              allowEffect: "Allow adds this to its Clubhouse permissions, where you can remove it later.",
              requestedAt: Date().addingTimeInterval(-200), expiresAt: Date().addingTimeInterval(86_000), answers: [.allowLasting, .decline]),
    ]
    static var helperRoutingCapability: AnnexCapabilities.HelperRouting? {
        try? AnnexJSON.object([
            "version": .integer(1), "path": .string("/api/v1/mobile/helper-routing"),
            "modes": .array([.string("explicit"), .string("preset")]), "scopes": .array([.string("app")]), "quota": .bool(false),
            "commands": .array([.string("helperRouting.update")]), "difficulties": .array([.string("easy"), .string("medium"), .string("hard")]),
            "levels": .array(["minimum", "easy", "medium", "hard", "maximum"].map(AnnexJSON.string)),
            "presetProviders": .array(["codex-cli", "copilot-cli"].map(AnnexJSON.string)),
            "autoCandidates": .array(["codex-cli"].map(AnnexJSON.string)),
            "reasons": .array([.string("explicit_request"), .string("preset_on_cli")]),
            "fallbacks": .array([.string("none"), .string("builtin_preset"), .string("model_unverified")]),
            "cellStates": .array([.string("valid"), .string("unverified"), .string("stale")])])
            .decode(AnnexCapabilities.HelperRouting.self)
    }
    /// Presentation samples only. Provider availability is established by the committed contract tests.
    static var helperPresets: CompanionHelperRouting {
        let easy = CompanionHelperRouting.Selection(model: "gpt-6-luna", effort: "low")
        let medium = CompanionHelperRouting.Selection(model: "gpt-6.1-terra", effort: "medium")
        let hard = CompanionHelperRouting.Selection(model: "gpt-6.1-sol", effort: "high")
        return .init(revision: "preview-1", labels: [
            "cell": ["valid": "Offered", "stale": "No longer offered", "unverified": "Couldn’t be checked"],
            "reason": ["preset_on_cli": "From the helper settings for this difficulty"],
            "fallback": ["builtin_preset": "The saved choice is no longer offered, so the default was used", "model_unverified": "The model list may be out of date, so this couldn’t be checked"],
            "generic": ["unknownCode": "Clubhouse gave a reason this version can’t show"]], providers: [
                "codex-cli": .init(autoEligible: true, choicesSource: "live", models: [
                    .init(id: hard.model, label: "Sol", efforts: ["low", "medium", "high"]),
                    .init(id: medium.model, label: "Terra", efforts: ["low", "medium", "high"]),
                    .init(id: easy.model, label: "Luna", efforts: ["low", "medium", "high"])], cells: [
                        "minimum": .init(effective: easy, builtin: easy, source: "builtin", state: "valid", editable: true, follows: "easy"),
                        "maximum": .init(effective: hard, builtin: hard, source: "builtin", state: "valid", editable: true, follows: "hard"),
                        "easy": .init(effective: easy, builtin: easy, source: "builtin", state: "valid", editable: true),
                        "medium": .init(effective: medium, custom: medium, builtin: medium, source: "custom", state: "unverified", fallback: "model_unverified", editable: true),
                        "hard": .init(effective: hard, custom: .init(model: "gone", effort: "high"), builtin: hard, source: "builtin", state: "stale", staleReason: "model_unavailable", fallback: "builtin_preset", editable: true)]),
                "copilot-cli": .init(autoEligible: true, autoCandidate: false, choicesSource: "live", models: [
                    .init(id: "claude-haiku-4.5", label: "Claude Haiku 4.5", efforts: [])],
                    cells: Dictionary(uniqueKeysWithValues: ["minimum", "easy", "medium", "hard", "maximum"].map { level in
                        let selection = CompanionHelperRouting.Selection(model: "claude-haiku-4.5")
                        return (level, .init(effective: selection, builtin: selection, source: "builtin", state: "valid", editable: true,
                                             follows: level == "minimum" ? "easy" : level == "maximum" ? "hard" : nil))
                    }))])
    }
    func helperRouting(hostID: String, projectID: String?, agentID: String?) async throws -> CompanionHelperRouting {
        guard showsHelperPresets else { throw previewError }
        if showsAutoQuota && hostID == "preview-work" { return Self.planLimitsPage }
        return showsAutoQuota ? Self.autoQuotaPage(projectID: projectID, agentID: agentID) : editedHelperPresets ?? Self.helperPresets
    }
    func updateHelperRouting(_ update: AnnexHelperRoutingUpdate, hostID: String, clientCommandID: String) async throws -> CompanionHelperRouting {
        guard !showsAutoQuota, showsHelperPresets,
              ProcessInfo.processInfo.arguments.contains("--companion-preview-helper-preset-edits") else { throw previewError }
        var page = editedHelperPresets ?? Self.helperPresets
        if let reset = update.reset {
            for id in page.providers.keys where reset.provider == nil || reset.provider == id {
                for level in page.providers[id]?.cells.keys.sorted() ?? [] where reset.difficulty == nil || reset.difficulty == level {
                    page.providers[id]?.cells[level] = Self.helperPresets.providers[id]?.cells[level]
                }
            }
        }
        for edit in update.cells ?? [] {
            guard var cell = page.providers[edit.provider]?.cells[edit.difficulty] else { continue }
            cell.custom = .init(model: edit.model, effort: edit.effort)
            cell.effective = cell.custom; cell.follows = nil; cell.source = "custom"; cell.state = "valid"
            cell.staleReason = nil; cell.fallback = nil
            page.providers[edit.provider]?.cells[edit.difficulty] = cell
        }
        page.revision += ".edit"
        editedHelperPresets = page
        return page
    }
    func settings(for target: CompanionTarget) async throws -> CompanionAgentSettings {
        if target == Self.dispatcherTarget {
            var settings = Self.dispatcherSettings
            if showsContextWindow { settings.contextWindow = Self.previewContext(editable: .always) }
            return settings
        }
        let sleeping = target == Self.sleepingTarget
        let routed = showsHelperPresets && sleeping
        var options = Self.agentOptions
        var includesAvailableProvider = routed
        #if DEBUG
        includesAvailableProvider = includesAvailableProvider || ProcessInfo.processInfo.arguments.contains("--companion-preview-provider-options")
        #endif
        if includesAvailableProvider {
            options.orchestrators.append(.init(id: "codex-cli", displayName: "Codex CLI", shortName: "CX", available: true, permissions: true, chat: true,
                                               models: Self.helperPresets.providers["codex-cli"]?.models.map { .init(id: $0.id, label: $0.label) } ?? []))
        }
        let name = sleeping ? "Juniper" : "River"
        var policy = sleeping ? Self.juniperOrchestration : CompanionOrchestration(sources: ["crossProjectHelpers": .default, "connectToDispatcher": .default])
        // The Auto provider sample keeps Juniper's own Auto switch on while it doesn't orchestrate, as `autoQuotaPage` says.
        if sleeping && showsAutoQuota { policy.orchestrate = false }
        var result = CompanionAgentSettings(state: sleeping ? "sleeping" : "running", sleeping: sleeping,
                     name: .init(value: name, editable: .sleeping), color: .init(value: sleeping ? "violet" : "indigo", editable: .sleeping),
                     emoji: .init(value: nil, editable: .sleeping),
                     orchestrator: .init(value: nil, editable: .sleeping), resolvedOrchestrator: routed ? "codex-cli" : "claude-code", changeStartsNewSession: sleeping,
                     model: .init(value: routed ? "gpt-6.1-sol" : "opus", editable: .sleeping),
                     contextWindow: showsContextWindow ? Self.previewContext(editable: .sleeping) : nil,
                     runtime: .init(value: "default", editable: .sleeping), resolvedRuntime: "chat",
                     freeAgentMode: .init(value: false, editable: .sleeping),
                     idleSleep: .init(value: .inherit, editable: .always),
                     options: options, idleSleepMinutes: [15, 30, 60, 240], appIdleMinutes: 30,
                     workspace: sleeping ? Self.juniperWorkspace : Self.riverWorkspace,
                     orchestration: policy, parentAgentID: (showsHelperIdentity || showsHelperPresets) && sleeping ? Self.target.agentID : nil,
                     routing: showsHelperPresets && sleeping ? .init(mode: "preset", selection: .init(provider: "codex-cli", model: "gpt-6.1-sol", effort: "high", difficulty: "hard"), reason: "preset_on_cli", summary: "gpt-6.1-sol, high effort. From the helper settings for this difficulty.", displayReason: "From the helper settings for this difficulty") : nil)
        if showsAutoQuota {
            result.routing = sleeping ? Self.autoQuotaSavedDecision : nil
            result.orchestration?.autoHelpers = sleeping ? true : nil
            result.orchestration?.autoHelpersEffective = !sleeping
        }
        #if DEBUG
        if sleeping, ProcessInfo.processInfo.arguments.contains("--companion-preview-report-only") {
            result.orchestration = Self.reportOnlyPolicy
            result.parentAgentID = Self.target.agentID
        }
        #endif
        return result
    }
    /// What the desktop lets you change on the Dispatcher: its CLI, model, runtime, Free Agent Mode and auto-sleep.
    static let dispatcherSettings = CompanionAgentSettings(
        state: "running", sleeping: false, name: .init(value: CompanionDispatcher.name, editable: .never), color: .init(value: "cyan", editable: .never),
        emoji: .init(value: nil, editable: .never), orchestrator: .init(value: "claude-code", editable: .always), resolvedOrchestrator: "claude-code",
        model: .init(value: "opus", editable: .always), runtime: .init(value: "chat", editable: .always), resolvedRuntime: "chat",
        freeAgentMode: .init(value: true, editable: .always), idleSleep: .init(value: .never, editable: .always),
        options: agentOptions, idleSleepMinutes: [15, 30, 60, 240], appIdleMinutes: 30)
    /// Juniper orchestrates, asking before each helper starts; River doesn't.
    static let juniperOrchestration = CompanionOrchestration(orchestrate: true, control: "ask-before-start", maxHelpers: 3,
                                                             sources: ["orchestrate": .agent, "control": .agent, "maxHelpers": .agent, "crossProjectHelpers": .default, "connectToDispatcher": .default])
    /// What River's chat session reported: the CLI version, effort, permission level and the MCP servers it loaded.
    static let riverSession = CompanionSessionFacts(cliVersion: "2.1.4", effort: "high", level: "auto_edit", mcpServers: [
        .init(name: "clubhouse", status: .connected), .init(name: "github", status: .connected), .init(name: "linear", status: .needsAuth),
        .init(name: "offline", status: .failed, error: "Connection refused (sanitized by desktop)"),
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
            .init(id: "codex", displayName: "Codex", shortName: "CX", available: false, unavailableReason: "Not installed on this desktop", permissions: false, chat: false,
                  models: [.init(id: "default", label: "Default")]),
        ],
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

// MARK: Settings > Dispatcher (#338), with `--companion-preview-dispatcher-settings`

extension CompanionPreviewService {
    /// Standard Behavior, models left to it, the Concise personality and some usage today. Its chat is running.
    static var previewDispatcherSettings: CompanionDispatcherSettings {
        .init(agentID: dispatcherTarget.agentID,
              behavior: .init(value: "standard", choices: [
                .init(id: "light", label: "Light", description: "Fast models, and it doesn’t check in on its own. Keeps usage low."),
                .init(id: "standard", label: "Standard", description: "Balanced models. Checks in on your agents occasionally."),
                .init(id: "thorough", label: "Thorough", description: "The strongest models for the work. Checks in frequently.")]),
              models: .init(note: "A new model or effort applies at once where the CLI allows, otherwise at its next start.", roles: [
                .init(id: "chat", label: "Talking with you", help: "Its replies to you in its chat."),
                .init(id: "work", label: "Working in the background", help: "The work you hand it, its check-ins and memory upkeep.")]),
              identity: .init(name: CompanionDispatcher.name, color: "cyan"),
              personality: .init(preset: "concise", text: previewPersonalities[1].text ?? "", presets: previewPersonalities),
              usage: .init(day: "2026-11-09",
                           conversations: .init(turns: 4, input: 182_000, cachedInput: 120_000, cacheWrite: 9000, output: 6400, costUSD: 0.42, costIsEstimate: true),
                           background: .init(turns: 2, turnsWithoutUsage: 1, input: 21_000, output: 900, costUSD: 0.03, costIsEstimate: true)),
              notHonored: ["model", "contextWindow", "runtime", "freeAgentMode", "access"],
              clearChat: .init(expectedState: "preview-clear-1", applies: "now"),
              forgetEverything: .init(expectedState: "preview-forget-1"))
    }
    static let previewPersonalities: [CompanionDispatcherSettings.PersonalityPreset] = [
        .init(id: "friendly", label: "Friendly", description: "Warm and upbeat", text: "Be warm and upbeat, like a teammate who enjoys the work."),
        .init(id: "concise", label: "Concise", description: "Short and direct", text: "Be short and direct. Lead with the answer."),
        .init(id: "detailed", label: "Detailed", description: "Context and reasons", text: "Give context and reasons."),
        .init(id: "custom", label: "Custom", description: "Write your own", text: nil),
    ]

    private var previewDispatcher: CompanionDispatcherSettings? {
        get { sentHosts.first?.dispatcherSettings }
        set {
            guard !sentHosts.isEmpty else { return }
            sentHosts[0].dispatcherSettings = newValue
            continuation?.yield(.hosts(sentHosts))
        }
    }
    func dispatcherSettings(hostID: String) async throws -> CompanionDispatcherSettings {
        guard let settings = previewDispatcher else { throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop) }
        return settings
    }
    func updateDispatcher(_ update: AnnexDispatcherUpdate, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        guard var settings = previewDispatcher else { throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop) }
        if let behavior = update.behavior { settings.behavior.value = behavior }
        if let name = update.name { settings.identity.name = name }
        if let color = update.color { settings.identity.color = color }
        switch update.emoji { case .set(let emoji)?: settings.identity.emoji = emoji; case .clear?: settings.identity.emoji = nil; case nil: break }
        if let personality = update.personality {
            if let preset = personality.preset {
                settings.personality?.preset = preset
                if let text = Self.previewPersonalities.first(where: { $0.id == preset })?.text { settings.personality?.text = text }
            }
            if let text = personality.text, personality.preset == nil {
                settings.personality?.text = text
                settings.personality?.preset = Self.previewPersonalities.first { $0.text == text }?.id ?? "custom"
            }
        }
        previewDispatcher = settings
        return settings
    }
    func setDispatcherModels(_ models: AnnexDispatcherModels, hostID: String, clientCommandID: String) async throws -> CompanionDispatcherSettings {
        guard var settings = previewDispatcher else { throw CompanionServiceError.unavailable(CompanionDispatcherSettings.updateDesktop) }
        switch models {
        case .byHand(let on):
            settings.models.byHand = on
            settings.behavior.setsModels = !on
            for index in settings.models.roles.indices where settings.models.roles[index].pick == nil {
                settings.models.roles[index].pick = .init(provider: "claude-code", model: "opus")
            }
        case .pick(let role, let provider, let model, let effort, _):
            guard let index = settings.models.roles.firstIndex(where: { $0.id == role }) else { throw CompanionServiceError.rejected("role must be chat or work.") }
            var pick = settings.models.roles[index].pick ?? .init()
            if let provider { pick.provider = provider; pick.model = "default" }
            if let model { pick.model = model }
            switch effort { case .set(let value)?: pick.effort = value; case .cliDefault?: pick.effort = nil; case nil: break }
            settings.models.roles[index].pick = pick
        }
        previewDispatcher = settings
        return settings
    }
    /// Nothing leaves the phone; a reset spends its confirmation, as the desktop's does.
    func resetDispatcher(_ prompt: CompanionDispatcherResetPrompt, clientCommandID: String) async throws -> CompanionDispatcherResetOutcome {
        guard var settings = previewDispatcher, prompt.expectedState == prompt.reset.confirmation(in: settings).expectedState else {
            throw CompanionServiceError.rejected("This changed since you were asked. Check again and confirm.")
        }
        switch prompt.reset {
        case .clearChat: settings.clearChat.expectedState = prompt.expectedState + "+"
        case .forgetEverything: settings.forgetEverything.expectedState = prompt.expectedState + "+"
        }
        previewDispatcher = settings
        return prompt.reset == .clearChat ? .chatCleared(now: settings.clearChat.applies == "now") : .forgot(removed: 3, heldNews: 0)
    }
}
