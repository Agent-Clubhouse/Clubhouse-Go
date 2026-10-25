import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

@MainActor private final class StubService: CompanionService {
    var responses: [String] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { responses.append("\(approvalID):\(optionID)") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
}

private func agent(_ id: String, _ status: CompanionAgentStatus, host: String = "mac", project: String = "p1") -> CompanionAgent {
    .init(id: .init(hostID: host, projectID: project, agentID: id), name: id, subtitle: "", status: status, capabilities: [.chat, .approve])
}

private func approval(_ id: String, deadline: Date?) -> CompanionApproval {
    .init(id: id, toolName: "Edit", summary: "Edit Package.swift", deadline: deadline,
          options: [.init(id: "allow", label: "Allow once", kind: .allowOnce), .init(id: "deny", label: "Deny", kind: .rejectOnce)])
}

@MainActor private func store(_ agents: [CompanionAgent], projects: [String] = ["p1"]) -> CompanionStore {
    let store = CompanionStore(service: StubService())
    store.apply(.hosts([.init(id: "mac", name: "MacBook", endpoint: "10.0.0.2:7787", connection: .connected,
                              projects: projects.map { project in .init(id: project, name: project.uppercased(), agents: agents.filter { $0.id.projectID == project }) })]))
    return store
}

struct CompanionThemeTests {
    // Colors as the desktop sends them in the snapshot `theme` and in `theme:changed`.
    private let latte = ["base": "#eff1f5", "mantle": "#e6e9ef", "crust": "#dce0e8", "text": "#4c4f69", "subtext0": "#6c6f85",
                         "surface0": "#ccd0da", "surface1": "#bcc0cc", "accent": "#1e66f5", "accent2": "#209fb5",
                         "warning": "#7e5700", "error": "#c4122f", "success": "#347d22"]
    private let mocha = ["base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4", "subtext0": "#a6adc8",
                         "surface0": "#313244", "surface1": "#45475a", "accent": "#89b4fa", "accent2": "#74c7ec",
                         "warning": "#f9e2af", "error": "#f38ba8", "success": "#a6e3a1"]

    @Test func hexRoundTrips() throws {
        let color = try #require(CompanionRGB(hex: "#89b4fa"))
        #expect(color.hex == "#89b4fa")
        #expect(CompanionRGB(hex: "nope") == nil)
    }

    @Test func modeFollowsTheBaseColor() throws {
        #expect(try #require(CompanionDesktopTheme.transported(latte)).mode == .light)
        #expect(try #require(CompanionDesktopTheme.transported(mocha)).mode == .dark)
        #expect(CompanionDesktopTheme.transported(["base": "#000000"]) == nil)
    }

    @Test func accentIsFittedForContrastOnLightCards() throws {
        let palette = CompanionPalette(theme: try #require(CompanionDesktopTheme.transported(latte)), dark: false)
        #expect(palette.usesThemeGrounds)
        #expect(palette.tint.contrast(with: palette.card) >= 4.5)
        #expect(palette.secondaryLabel.contrast(with: palette.card) >= 4.5)
    }

    @Test func darkThemeInLightModeKeepsAccentOnSystemGrounds() throws {
        let palette = CompanionPalette(theme: try #require(CompanionDesktopTheme.transported(mocha)), dark: false)
        #expect(!palette.usesThemeGrounds)
        #expect(palette.card == .white)
        #expect(palette.accentWasAdjusted)
        #expect(palette.tint.contrast(with: .white) >= 4.5)
    }

    @Test func washUsesTheGradientOrTheAccentPair() throws {
        let plain = CompanionPalette(theme: try #require(CompanionDesktopTheme.transported(mocha)), dark: true)
        #expect(plain.washStart == CompanionRGB(hex: "#89b4fa") && plain.washEnd == CompanionRGB(hex: "#74c7ec"))
        let gradient = CompanionPalette(theme: try #require(CompanionDesktopTheme.transported(mocha, gradient: ["#ff7edb", "#36f9f6"])), dark: true)
        #expect(gradient.washStart == CompanionRGB(hex: "#ff7edb") && gradient.washEnd == CompanionRGB(hex: "#36f9f6"))
    }

    @MainActor @Test func liveServiceReadsTheSnapshotTheme() throws {
        var payload = mocha.mapValues(AnnexJSON.string)
        payload["gradients"] = .object(["accent": .string("linear-gradient(135deg, #e8a0bf, #94e2d5)")])
        let theme = try #require(CompanionLiveService.theme(from: .object(payload)))
        #expect(theme.accent == CompanionRGB(hex: "#89b4fa"))
        #expect(theme.gradient == [CompanionRGB(hex: "#e8a0bf"), CompanionRGB(hex: "#94e2d5")].compactMap { $0 })
        #expect(CompanionLiveService.theme(from: .string("nope")) == nil)
    }

    @MainActor @Test func hostWithoutColorsUsesTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "companion-theme-\(UUID().uuidString)"))
        let preferences = CompanionPreferences(defaults: defaults)
        var host = CompanionHost(id: "mac", name: "MacBook", endpoint: "", connection: .connected, projects: [])
        #expect(preferences.theme(forHost: "mac", hosts: [host]).id == "clubhouse")
        host.theme = CompanionDesktopTheme.transported(latte)
        #expect(preferences.sharedTheme(hosts: [host]).mode == .light)
    }
}

@MainActor struct CompanionAttentionTests {
    @Test func soonestExpiringApprovalComesFirst() {
        let late = agent("late", .approval), soon = agent("soon", .approval), broken = agent("broken", .failed), idle = agent("idle", .working)
        let store = store([late, broken, soon, idle])
        let now = Date()
        store.apply(.timeline(late.id, items: [.approval(approval("a1", deadline: now.addingTimeInterval(300)))], sequence: 1, reset: true))
        store.apply(.timeline(soon.id, items: [.approval(approval("a2", deadline: now.addingTimeInterval(60)))], sequence: 1, reset: true))
        let items = store.attentionItems(now: now)
        #expect(items.map(\.agent.name) == ["soon", "late", "broken"])
        #expect(items.last?.kind == .failure)
        #expect(store.needsYouCount == 3)
    }

    @Test func approvalWithoutLoadedConversationIsUnreviewed() {
        let waiting = agent("waiting", .approval)
        #expect(store([waiting]).attentionItems().first?.kind == .unreviewed)
    }

    @Test func expiredApprovalIsNotPinned() {
        let waiting = agent("waiting", .approval)
        let store = store([waiting])
        store.apply(.timeline(waiting.id, items: [.approval(approval("old", deadline: Date().addingTimeInterval(-5)))], sequence: 1, reset: true))
        #expect(store.pinnedApproval(for: waiting.id) == nil)
    }

    @Test func needsYouAgentsListFirst() {
        let working = agent("working", .working), asking = agent("asking", .waiting)
        #expect(store([working, asking]).agentsNeedsYouFirst().map(\.name) == ["asking", "working"])
    }
}

struct CompanionTimelineFoldingTests {
    private func tool(_ id: String, _ state: CompanionTool.State) -> CompanionTimelineItem {
        .tool(.init(id: id, name: "Read", summary: "", state: state))
    }

    @Test func foldsRunsOfCompletedTools() {
        let message = CompanionTimelineItem.message(.init(id: "m", role: .assistant, text: "hi"))
        let rows = CompanionTimelineFolding.rows(for: [tool("1", .completed), tool("2", .completed), tool("3", .completed), message])
        #expect(rows.count == 2)
        if case .tools(let tools) = rows[0] { #expect(tools.map(\.id) == ["1", "2", "3"]) } else { Issue.record("expected a folded run") }
    }

    @Test func failedAndRunningToolsStayVisibleAndSingleToolsDontFold() {
        let rows = CompanionTimelineFolding.rows(for: [tool("1", .completed), tool("2", .failed), tool("3", .completed), tool("4", .running)])
        #expect(rows.map(\.id) == ["tool:1", "tool:2", "tool:3", "tool:4"])
    }
}

@MainActor struct CompanionProjectOrderingTests {
    private func entries() -> [CompanionProjectEntry] {
        let host = CompanionHost(id: "mac", name: "MacBook", endpoint: "", connection: .connected,
                                 projects: ["zeta", "Alpha", "mid"].map { .init(id: $0, name: $0, agents: []) })
        return host.projects.map { CompanionProjectEntry(host: host, project: $0) }
    }

    @Test func alphabetical() {
        let ordered = CompanionProjectOrdering.ordered(entries(), sort: .alphabetical, customOrder: [], lastActivity: { _ in nil })
        #expect(ordered.map(\.project.name) == ["Alpha", "mid", "zeta"])
    }

    @Test func recentPutsUnknownActivityLastInDesktopOrder() {
        let now = Date()
        let ordered = CompanionProjectOrdering.ordered(entries(), sort: .recent, customOrder: [], lastActivity: { target in
            target.projectID == "mid" ? now : target.projectID == "Alpha" ? now.addingTimeInterval(-60) : nil
        })
        #expect(ordered.map(\.project.name) == ["mid", "Alpha", "zeta"])
    }

    @Test func customOrderKeepsNewProjectsAtTheEnd() {
        let keys = entries().map(\.orderKey)
        let ordered = CompanionProjectOrdering.ordered(entries(), sort: .custom, customOrder: [keys[2], keys[0]], lastActivity: { _ in nil })
        #expect(ordered.map(\.project.name) == ["mid", "zeta", "Alpha"])
    }

    @Test func savingOrderKeepsHiddenProjects() throws {
        let defaults = try #require(UserDefaults(suiteName: "companion-ordering-\(UUID().uuidString)"))
        let preferences = CompanionPreferences(defaults: defaults)
        preferences.projectOrder = ["a", "offline", "b"]
        preferences.setProjectOrder(["b", "a"])
        #expect(preferences.projectOrder == ["b", "a", "offline"])
        #expect(CompanionPreferences(defaults: defaults).projectOrder == ["b", "a", "offline"])
    }
}

@MainActor struct CompanionDecisionQueueTests {
    private func pending(_ id: String) -> CompanionDecisionQueue.Pending {
        let approval = approval(id, deadline: nil)
        return .init(approval: approval, option: approval.options[0], target: .init(hostID: "mac", projectID: "p1", agentID: "a"), agentName: "a")
    }

    @Test func undoStopsTheDecision() async throws {
        var sent: [String] = []
        let queue = CompanionDecisionQueue(delay: .milliseconds(50)) { sent.append($0.id) }
        queue.schedule(pending("x"))
        #expect(queue.isPending("x"))
        queue.undo("x")
        try await Task.sleep(for: .milliseconds(150))
        #expect(sent.isEmpty)
        #expect(!queue.isPending("x"))
    }

    @Test func decisionIsSentAfterTheWindow() async throws {
        var sent: [String] = []
        let queue = CompanionDecisionQueue(delay: .milliseconds(30)) { sent.append($0.id) }
        queue.schedule(pending("y"))
        queue.schedule(pending("y"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == ["y"])
        #expect(queue.pending.isEmpty)
    }
}
