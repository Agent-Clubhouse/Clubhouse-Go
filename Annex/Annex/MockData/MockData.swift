import Foundation

enum MockData {
    static let orchestrators: [String: OrchestratorEntry] = [
        "claude-code": OrchestratorEntry(displayName: "Claude Code", shortName: "CC", badge: nil),
        "copilot-cli": OrchestratorEntry(displayName: "Copilot CLI", shortName: "CP", badge: nil),
        "codex": OrchestratorEntry(displayName: "Codex", shortName: "CX", badge: nil),
    ]

    static let projects: [Project] = [
        Project(id: "proj_001", name: "my-app", path: "/Users/mason/source/my-app", color: "emerald", icon: nil, displayName: "My App", orchestrator: "claude-code"),
        Project(id: "proj_002", name: "api-server", path: "/Users/mason/source/api-server", color: "cyan", icon: nil, displayName: nil, orchestrator: "copilot-cli"),
        Project(id: "proj_003", name: "design-system", path: "/Users/mason/source/design-system", color: "violet", icon: nil, displayName: "Design System", orchestrator: "claude-code"),
    ]

    static let agents: [String: [DurableAgent]] = [
        "proj_001": [
            DurableAgent(
                id: "durable_1737000000000_abc123",
                name: "faithful-urchin",
                kind: "durable",
                color: "emerald",
                branch: "faithful-urchin/standby",
                model: "claude-opus-4-5",
                orchestrator: "claude-code",
                freeAgentMode: false,
                icon: nil,
                executionMode: "pty",
                status: .running,
                mission: nil,
                detailedStatus: AgentDetailedStatus(
                    state: .working,
                    message: "Editing src/main.ts",
                    toolName: "Edit",
                    timestamp: 1708531200000
                ),
                quickAgents: [
                    QuickAgent(
                        id: "quick_1737000100000_def456",
                        name: "quick-agent-1",
                        kind: "quick",
                        status: .running,
                        mission: "Fix the login bug",
                        prompt: "Fix the login bug in src/auth/login.ts",
                        model: "claude-sonnet-4-5",
                        detailedStatus: AgentDetailedStatus(
                            state: .idle,
                            message: "",
                            toolName: nil,
                            timestamp: 1708531190000
                        ),
                        orchestrator: "claude-code",
                        parentAgentId: "durable_1737000000000_abc123",
                        projectId: "proj_001",
                        freeAgentMode: false
                    ),
                ]
            ),
            DurableAgent(
                id: "durable_1737000000001_xyz789",
                name: "gentle-fox",
                kind: "durable",
                color: "rose",
                branch: "gentle-fox/feature-auth",
                model: "claude-sonnet-4-5",
                orchestrator: "claude-code",
                freeAgentMode: false,
                icon: nil,
                executionMode: nil,
                status: .sleeping,
                mission: "Implement OAuth2 login flow",
                detailedStatus: nil,
                quickAgents: []
            ),
        ],
        "proj_002": [
            DurableAgent(
                id: "durable_1737000000002_srv001",
                name: "bold-eagle",
                kind: "durable",
                color: "cyan",
                branch: "bold-eagle/api-endpoints",
                model: "claude-opus-4-5",
                orchestrator: "copilot-cli",
                freeAgentMode: false,
                icon: nil,
                executionMode: "structured",
                status: .running,
                mission: "Add rate limiting middleware",
                detailedStatus: AgentDetailedStatus(
                    state: .needsPermission,
                    message: "Run bash command: npm test",
                    toolName: "Bash",
                    timestamp: 1708531250000
                ),
                quickAgents: [
                    QuickAgent(
                        id: "quick_1737000200000_srv002",
                        name: "quick-agent-2",
                        kind: "quick",
                        status: .running,
                        mission: "Update API docs",
                        prompt: "Update the API documentation in README.md",
                        model: "claude-haiku-4-5",
                        detailedStatus: AgentDetailedStatus(
                            state: .working,
                            message: "Reading README.md",
                            toolName: "Read",
                            timestamp: 1708531240000
                        ),
                        orchestrator: "copilot-cli",
                        parentAgentId: "durable_1737000000002_srv001",
                        projectId: "proj_002",
                        freeAgentMode: false
                    ),
                ]
            ),
            DurableAgent(
                id: "durable_1737000000003_srv003",
                name: "calm-otter",
                kind: "durable",
                color: "amber",
                branch: "calm-otter/db-migration",
                model: "claude-sonnet-4-5",
                orchestrator: "claude-code",
                freeAgentMode: true,
                icon: nil,
                executionMode: "headless",
                status: .error,
                mission: "Database schema migration",
                detailedStatus: AgentDetailedStatus(
                    state: .toolError,
                    message: "Command failed: psql migration",
                    toolName: "Bash",
                    timestamp: 1708531100000
                ),
                quickAgents: []
            ),
        ],
        "proj_003": [
            DurableAgent(
                id: "durable_1737000000004_ds001",
                name: "swift-crane",
                kind: "durable",
                color: "violet",
                branch: "swift-crane/components",
                model: "claude-opus-4-5",
                orchestrator: "claude-code",
                freeAgentMode: false,
                icon: nil,
                executionMode: "pty",
                status: .running,
                mission: "Build button component library",
                detailedStatus: AgentDetailedStatus(
                    state: .working,
                    message: "Writing src/Button.tsx",
                    toolName: "Write",
                    timestamp: 1708531300000
                ),
                quickAgents: []
            ),
        ],
    ]

    static func hookEvents(for agentId: String) -> [HookEvent] {
        let base = 1708531000000
        switch agentId {
        case "durable_1737000000000_abc123":
            return [
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Read", toolVerb: "Reading package.json", message: nil, timestamp: base),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: base + 5000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Glob", toolVerb: "Searching for *.ts files", message: nil, timestamp: base + 12000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Glob", toolVerb: nil, message: nil, timestamp: base + 14000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Read", toolVerb: "Reading src/App.tsx", message: nil, timestamp: base + 20000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: base + 22000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Edit", toolVerb: "Editing src/main.ts", message: nil, timestamp: base + 30000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Edit", toolVerb: nil, message: nil, timestamp: base + 35000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Bash", toolVerb: "Running npm test", message: nil, timestamp: base + 40000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Bash", toolVerb: nil, message: nil, timestamp: base + 55000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Edit", toolVerb: "Editing src/utils.ts", message: nil, timestamp: base + 60000),
                HookEvent(id: UUID(), agentId: agentId, kind: .notification, toolName: nil, toolVerb: nil, message: "Refactoring complete, running final checks", timestamp: base + 70000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Edit", toolVerb: "Editing src/main.ts", message: nil, timestamp: base + 200000),
            ]
        case "durable_1737000000002_srv001":
            return [
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Read", toolVerb: "Reading server.ts", message: nil, timestamp: base),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: base + 3000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Write", toolVerb: "Writing middleware/rateLimit.ts", message: nil, timestamp: base + 10000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Write", toolVerb: nil, message: nil, timestamp: base + 15000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Edit", toolVerb: "Editing server.ts", message: nil, timestamp: base + 20000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Edit", toolVerb: nil, message: nil, timestamp: base + 25000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Bash", toolVerb: "Running npm test", message: nil, timestamp: base + 30000),
                HookEvent(id: UUID(), agentId: agentId, kind: .toolError, toolName: "Bash", toolVerb: nil, message: "Test failed: rateLimit middleware not exported", timestamp: base + 45000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Edit", toolVerb: "Editing middleware/rateLimit.ts", message: nil, timestamp: base + 50000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Edit", toolVerb: nil, message: nil, timestamp: base + 55000),
                HookEvent(id: UUID(), agentId: agentId, kind: .permissionRequest, toolName: "Bash", toolVerb: nil, message: "Run bash command: npm test", timestamp: base + 250000),
            ]
        case "durable_1737000000003_srv003":
            return [
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Read", toolVerb: "Reading schema.sql", message: nil, timestamp: base),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: base + 4000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Write", toolVerb: "Writing migrations/002_add_users.sql", message: nil, timestamp: base + 10000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Write", toolVerb: nil, message: nil, timestamp: base + 12000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Bash", toolVerb: "Running psql migration", message: nil, timestamp: base + 20000),
                HookEvent(id: UUID(), agentId: agentId, kind: .toolError, toolName: "Bash", toolVerb: nil, message: "Command failed: psql migration — relation \"users\" already exists", timestamp: base + 30000),
                HookEvent(id: UUID(), agentId: agentId, kind: .stop, toolName: nil, toolVerb: nil, message: "Agent stopped due to error", timestamp: base + 100000),
            ]
        case "durable_1737000000004_ds001":
            return [
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Glob", toolVerb: "Searching for *.tsx files", message: nil, timestamp: base),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Glob", toolVerb: nil, message: nil, timestamp: base + 2000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Read", toolVerb: "Reading src/theme.ts", message: nil, timestamp: base + 5000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Read", toolVerb: nil, message: nil, timestamp: base + 7000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Write", toolVerb: "Writing src/Button.tsx", message: nil, timestamp: base + 15000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Write", toolVerb: nil, message: nil, timestamp: base + 20000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Write", toolVerb: "Writing src/Button.test.tsx", message: nil, timestamp: base + 25000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Write", toolVerb: nil, message: nil, timestamp: base + 30000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Bash", toolVerb: "Running npm test", message: nil, timestamp: base + 35000),
                HookEvent(id: UUID(), agentId: agentId, kind: .postTool, toolName: "Bash", toolVerb: nil, message: nil, timestamp: base + 50000),
                HookEvent(id: UUID(), agentId: agentId, kind: .notification, toolName: nil, toolVerb: nil, message: "All tests passing, starting next component", timestamp: base + 55000),
                HookEvent(id: UUID(), agentId: agentId, kind: .preTool, toolName: "Write", toolVerb: "Writing src/Button.tsx", message: nil, timestamp: base + 300000),
            ]
        default:
            return []
        }
    }

    static let activity: [String: [HookEvent]] = {
        var result: [String: [HookEvent]] = [:]
        let allAgentIds = [
            "durable_1737000000000_abc123",
            "durable_1737000000001_xyz789",
            "durable_1737000000002_srv001",
            "durable_1737000000003_srv003",
            "durable_1737000000004_ds001",
        ]
        for id in allAgentIds {
            result[id] = hookEvents(for: id)
        }
        return result
    }()
}
