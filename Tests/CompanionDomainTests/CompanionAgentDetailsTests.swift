import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// Agent details (#157): the desktop's hover card and Details pane, from the snapshot, the chat session and the
// settings route's `details`. Fields a desktop doesn't send are left out.

private func json(_ text: String) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }

private func settings(details: String? = nil, permissions: Bool = true, freeAgentMode: Bool = false, runtime: String = "chat") throws -> CompanionAgentSettings {
    let detailsField = details.map { #","details":\#($0)"# } ?? ""
    return try CompanionAgentSettings(json: json(#"""
    {"agentId":"durable_1","projectId":"p1","state":"sleeping","sleeping":true,
     "settings":{"name":{"value":"brave-otter","editable":"sleeping"},
      "orchestrator":{"value":null,"resolved":"claude-code","editable":"sleeping"},
      "model":{"value":"opus","editable":"sleeping"},
      "runtime":{"value":"default","resolved":"\#(runtime)","editable":"sleeping"},
      "freeAgentMode":{"value":\#(freeAgentMode),"editable":"never"},
      "idleSleep":{"value":30,"applies":\#(runtime == "chat"),"editable":"always"}},
     "options":{"orchestrators":[{"id":"claude-code","displayName":"Claude Code","shortName":"CC","available":true,"permissions":\#(permissions),"chat":true,
       "models":[{"id":"opus","label":"Opus 5.5"}]}],"idleSleep":{"minutes":[15,30,60],"appMinutes":30}}\#(detailsField)}
    """#))
}

private let target = CompanionTarget(hostID: "h", projectID: "p", agentID: "a")
private let providers = [CompanionProvider(id: "claude-code", name: "Claude Code")]

@Suite struct CompanionAgentDetailsDecodingTests {
    @Test func detailsDecodeBranchWorktreeMCPAndChanges() throws {
        let decoded = try settings(details: #"""
        {"branch":"brave-otter/standby","worktreePath":"/work/app/.clubhouse/agents/brave-otter","worktree":".clubhouse/agents/brave-otter",
         "mcpIds":["github","linear"],
         "changes":{"available":true,"base":"main","noBase":false,"files":6,"additions":94,"deletions":51,"ahead":2,"uncommitted":1}}
        """#)
        let workspace = try #require(decoded.workspace)
        #expect(workspace.branch == "brave-otter/standby")
        #expect(workspace.worktreePath == "/work/app/.clubhouse/agents/brave-otter")
        #expect(workspace.worktree == ".clubhouse/agents/brave-otter")
        #expect(workspace.mcpIDs == ["github", "linear"])
        #expect(workspace.changes == .init(base: "main", files: 6, additions: 94, deletions: 51, ahead: 2, uncommitted: 1))
        #expect(workspace.changes?.summary == "6 files +94 −51")
        #expect(workspace.changes?.detail == "2 commits ahead of main · 1 uncommitted")
    }

    @Test func olderDesktopsSendNoDetails() throws {
        #expect(try settings().workspace == nil)
    }

    @Test func missingAndNullDetailFieldsAreLeftOut() throws {
        let workspace = try #require(try settings(details: #"{"branch":null,"worktreePath":null,"worktree":null,"changes":null}"#).workspace)
        #expect(workspace == .init())
        // A desktop that sends only the absolute path still shows a worktree; counts never go negative.
        let partial = try #require(try settings(details: #"{"worktreePath":"/w/a","mcpIds":["x",3],"changes":{"files":-2}}"#).workspace)
        #expect(partial.worktree == "/w/a")
        #expect(partial.mcpIDs == ["x"])
        #expect(partial.changes?.files == 0)
        #expect(partial.changes?.available == true)
        #expect(partial.changes?.ahead == nil)
    }

    @Test func changesSummariesUseTheDesktopsWords() {
        #expect(CompanionAgentChanges(available: false).summary == "Not a git repository")
        #expect(CompanionAgentChanges(noBase: true).summary == "No main branch to compare with")
        #expect(CompanionAgentChanges().summary == "No changes")
        #expect(CompanionAgentChanges(files: 1, additions: 3, deletions: 0).summary == "1 file +3 −0")
        #expect(CompanionAgentChanges(ahead: 1, uncommitted: 0).detail == "1 commit ahead of main")
        #expect(CompanionAgentChanges(available: false, ahead: 1).detail == nil)
    }

    @Test func updateResultsKeepTheDetailsOnScreen() throws {
        let read = try settings(details: #"{"branch":"b","mcpIds":[]}"#)
        let updated = try CompanionAgentSettings(json: json(#"{"settings":{"name":{"value":"calm-otter"}}}"#)).keepingOptions(of: read)
        #expect(updated.workspace?.branch == "b")
    }
}

@Suite @MainActor struct CompanionAgentDetailsProjectionTests {
    private func event(_ type: String, seq: Int64, session: String = "s", data: [String: AnnexJSON]) -> AnnexJSON {
        .object(["sessionId": .string(session), "seq": .integer(seq), "type": .string(type), "data": .object(data)])
    }

    @Test func sessionEventsReportCLIVersionEffortLevelAndMCPServers() {
        var projection = CompanionChatProjector()
        projection.apply(event("session_started", seq: 1, data: ["cliVersion": .string("2.1.3"), "level": .string("ask"), "capabilities": .object([:])]))
        projection.apply(event("session_info", seq: 2, data: [
            "cliVersion": .string("2.1.4"),
            "levelNames": .object(["auto_edit": .string("Accept edits")]),
            "mcpServers": .array([.object(["name": .string("github"), "status": .string("connected")]),
                                  .object(["name": .string("linear"), "status": .string("needs_auth")]),
                                  .object(["name": .string("odd"), "status": .string("new_status")])]),
        ]))
        projection.apply(event("mode_changed", seq: 3, data: ["level": .string("auto_edit")]))
        projection.apply(event("model_changed", seq: 4, data: ["modelId": .string("opus"), "effort": .string("high"), "effortIsDefault": .bool(true)]))
        #expect(projection.session.cliVersion == "2.1.4")
        #expect(projection.session.level == "auto_edit")
        #expect(projection.session.levelNames == ["auto_edit": "Accept edits"])
        #expect(projection.session.effort == "high")
        #expect(projection.session.effortIsDefault)
        #expect(projection.session.mcpServers?.map(\.status) == [.connected, .needsAuth, .unknown])
        // A session_info without servers keeps the earlier list.
        projection.apply(event("session_info", seq: 5, data: ["title": .string("t")]))
        #expect(projection.session.mcpServers?.count == 3)
    }

    @Test func aNewSessionForgetsTheOldFacts() {
        var projection = CompanionChatProjector()
        projection.apply(event("session_started", seq: 1, data: ["cliVersion": .string("1.0"), "capabilities": .object([:])]))
        projection.apply(event("turn_started", seq: 1, session: "next", data: [:]))
        #expect(projection.session == .init())
    }

    @Test func liveChatAgentShowsItsSessionAndSettings() throws {
        var agent = CompanionAgent(id: target, name: "a", subtitle: "", status: .working, model: "claude-opus-5-5", executionMode: "chat")
        agent.orchestrator = "claude-code"
        agent.session = .init(cliVersion: "2.1.4", effort: "high", level: "auto_edit", levelNames: ["auto_edit": "Accept edits"],
                              mcpServers: [.init(name: "linear", status: .needsAuth), .init(name: "clubhouse", status: .connected)])
        let details = CompanionAgentDetails(agent: agent, providers: providers, settings: try settings(details: #"""
        {"branch":"a/standby","worktree":".clubhouse/agents/a","mcpIds":["clubhouse","figma"],"changes":{"files":0}}
        """#))
        #expect(details.cli == "Claude Code 2.1.4")
        #expect(details.runtime == "Chat")
        #expect(details.model == "claude-opus-5-5", "Awake, the session's model")
        #expect(details.effort == "High")
        #expect(details.access == "Accept edits", "The provider's name for the live level")
        #expect(details.autoSleep == "Sleeps after 30 min")
        #expect(details.branch == "a/standby")
        #expect(details.worktree == ".clubhouse/agents/a")
        #expect(details.mcpServers?.map(\.name) == ["clubhouse", "linear", "figma"], "Connected first, then only configured")
        #expect(details.mcpSummary == "1 connected · 1 needs sign-in · 1 configured")
        #expect(details.mcpServers?.first?.displayName == "Clubhouse")
        #expect(details.changes?.summary == "No changes")
        #expect(details.hasWorkspace)
    }

    @Test func sleepingAgentUsesItsSavedSettings() throws {
        let agent = CompanionAgent(id: target, name: "a", subtitle: "", status: .sleeping, model: "opus")
        let details = CompanionAgentDetails(agent: agent, providers: providers, settings: try settings(freeAgentMode: true, runtime: "terminal"))
        #expect(details.model == "Opus 5.5", "Asleep, the model its next wake uses")
        #expect(details.runtime == "Terminal")
        #expect(details.cli == "Claude Code", "No session, so no version")
        #expect(details.effort == nil)
        #expect(details.access == "Free agent")
        #expect(details.freeAgentMode)
        #expect(details.autoSleep == "Doesn't sleep in a terminal")
        #expect(!details.hasWorkspace)
    }

    @Test func snapshotOnlyDetailsDegradeGracefully() {
        // A quick agent, or a desktop without settings: only what the snapshot says.
        var agent = CompanionAgent(id: target, name: "a", subtitle: "", status: .idle, model: nil, isQuick: true)
        agent.orchestrator = "codex-cli"
        agent.branch = "main"
        let details = CompanionAgentDetails(agent: agent, providers: providers)
        #expect(details.runsOn == "codex-cli", "An unlisted CLI shows its id")
        #expect(details.runtime == nil)
        #expect(details.model == nil)
        #expect(details.access == nil, "Unknown without a level or the CLI's permission support")
        #expect(details.autoSleep == nil)
        #expect(details.branch == "main")
        #expect(details.worktree == nil)
        #expect(details.mcpServers == nil)
        #expect(details.mcpSummary == "None")
        #expect(details.changes == nil)
        #expect(!details.hasWorkspace)
        #expect(CompanionAgentDetails(agent: .init(id: target, name: "a", subtitle: "", status: .idle)).cli == nil)
    }

    @Test func accessFollowsTheDesktopsSettingsCard() {
        #expect(CompanionAgentDetails.access(level: "full_access", levelNames: [:], freeAgentMode: false, permissions: nil) == "Full access")
        #expect(CompanionAgentDetails.access(level: nil, levelNames: [:], freeAgentMode: true, permissions: false) == "Set by the CLI")
        #expect(CompanionAgentDetails.access(level: nil, levelNames: [:], freeAgentMode: false, permissions: true) == "Ask before edits")
        #expect(CompanionAgentDetails.access(level: nil, levelNames: [:], freeAgentMode: true, permissions: nil) == "Free agent")
        #expect(CompanionSessionFacts.levelLabel("plan") == "Plan")
    }
}
