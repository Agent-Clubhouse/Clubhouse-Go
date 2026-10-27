import Testing
import Foundation
@testable import ClubhouseTransport

// agent.create / agent.update and their read routes (desktop Agent-Clubhouse/Clubhouse#2454).

private actor RouteIO: AnnexIO {
    var requests: [URLRequest] = []
    var responses: [AnnexHTTPResponse]
    init(_ responses: [String]) { self.responses = responses.map { AnnexHTTPResponse(status: 200, data: Data($0.utf8)) } }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AnnexTransportError.malformedResponse }
        return responses.removeFirst()
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}

private func transport(_ io: RouteIO) async throws -> AnnexTransport {
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef",
                                    verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-token"), for: host.hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io)
}

private func capabilities(commands: [String], extra: String = "") -> String {
    let list = commands.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"version":1,"epoch":"epoch1","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[\#(list)],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}\#(extra)}"#
}
private let durableFeatures = #","createOptions":{"version":1,"path":"/api/v1/mobile/projects/{projectId}/create-options"},"agentSettings":{"version":1,"path":"/api/v1/mobile/agents/{agentId}/settings"}"#

private func decoded(_ kind: AnnexCommand.Kind) throws -> AnnexJSON {
    try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "cmd", epoch: "e", kind: kind).encoded())
}
private func keys(_ value: AnnexJSON) -> Set<String> {
    if case .object(let fields) = value { Set(fields.keys) } else { [] }
}
private let envelope: Set<String> = ["version", "commandId", "epoch", "type"]

@Test func createEncodesOnlyTheFieldsGiven() throws {
    let minimal = try decoded(.create(.init(projectID: "p1", name: "brave-otter", color: "indigo")))
    #expect(minimal["type"]?.string == "agent.create")
    #expect(keys(minimal) == envelope.union(["projectId", "name", "color"]))

    let full = try decoded(.create(.init(projectID: "p1", name: "brave-otter", color: "teal", orchestrator: "claude-code", model: "opus",
                                         persona: "qa", useWorktree: false, mcpIDs: ["ado", "github"], branchName: "b", branchFrom: "main", folderName: "f")))
    #expect(keys(full) == envelope.union(["projectId", "name", "color", "orchestrator", "model", "persona", "useWorktree", "mcpIds", "branchName", "branchFrom", "folderName"]))
    #expect(full["useWorktree"] == .bool(false))
    #expect(full["mcpIds"] == .array([.string("ado"), .string("github")]))
    #expect(full["projectId"]?.string == "p1" && full["color"]?.string == "teal")
}

@Test func updateEncodesChangesAndClearsWithNull() throws {
    let value = try decoded(.update(.init(agentID: "a1", emoji: .clear, model: "default", runtime: .terminal, persona: .clear, clubhouseMode: false, idleSleep: .minutes(30))))
    #expect(value["type"]?.string == "agent.update")
    #expect(keys(value) == envelope.union(["agentId", "emoji", "model", "runtime", "persona", "clubhouseMode", "idleSleep"]))
    #expect(value["emoji"] == .null && value["persona"] == .null)
    #expect(value["runtime"]?.string == "terminal" && value["model"]?.string == "default")
    #expect(value["clubhouseMode"] == .bool(false))
    #expect(value["idleSleep"] == .integer(30))
    #expect(try decoded(.update(.init(agentID: "a1", idleSleep: .inherit)))["idleSleep"]?.string == "inherit")
    #expect(try decoded(.update(.init(agentID: "a1", idleSleep: .never)))["idleSleep"]?.string == "never")
    #expect(try decoded(.update(.init(agentID: "a1", emoji: .set("🦦"))))["emoji"]?.string == "🦦")
}

@Test func emptyUpdateIsRefusedBeforeSending() {
    #expect(AnnexAgentUpdate(agentID: "a1").isEmpty)
    #expect(throws: AnnexTransportError.malformedResponse) { try decoded(.update(.init(agentID: "a1"))) }
}

/// Free Agent Mode can't be set from a phone (403 `free_agent_mode_not_allowed`), so no command ever carries it.
@Test func freeAgentModeIsNeverSent() throws {
    let commands: [AnnexCommand.Kind] = [
        .create(.init(projectID: "p", name: "n", color: "indigo", orchestrator: "o", model: "m", persona: "p", useWorktree: true, mcpIDs: [], branchName: "b", branchFrom: "f", folderName: "d")),
        .update(.init(agentID: "a", name: "n", color: "rose", emoji: .set("x"), orchestrator: "o", model: "m", runtime: .chat, persona: .set("p"), clubhouseMode: true, idleSleep: .never)),
    ]
    for kind in commands {
        let data = try AnnexCommand(commandID: "c", epoch: "e", kind: kind).encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("freeAgentMode"))
    }
}

@Test func durableFeaturesNeedTheCommandAndVersionOne() throws {
    func caps(_ json: String) throws -> AnnexCapabilities { try JSONDecoder().decode(AnnexCapabilities.self, from: Data(json.utf8)) }
    let current = try caps(capabilities(commands: ["agent.spawn", "agent.create", "agent.update"], extra: durableFeatures))
    #expect(current.supportsAgentCreate && current.supportsAgentSettings)
    #expect(current.createOptions == .init(version: 1, path: "/api/v1/mobile/projects/{projectId}/create-options"))

    let older = try caps(capabilities(commands: ["agent.spawn"]))
    #expect(!older.supportsAgentCreate && !older.supportsAgentSettings)

    let routesOnly = try caps(capabilities(commands: ["agent.spawn"], extra: durableFeatures))
    #expect(!routesOnly.supportsAgentCreate && !routesOnly.supportsAgentSettings)

    let commandsOnly = try caps(capabilities(commands: ["agent.create", "agent.update"]))
    #expect(!commandsOnly.supportsAgentCreate && !commandsOnly.supportsAgentSettings)

    let versionZero = try caps(capabilities(commands: ["agent.create", "agent.update"],
                                            extra: #","createOptions":{"version":0},"agentSettings":{"version":0}"#))
    #expect(!versionZero.supportsAgentCreate && !versionZero.supportsAgentSettings)
}

@Test func createOptionsAndSettingsUseFixedRoutesWithEncodedIDs() async throws {
    let io = RouteIO(["{}", "{}"])
    let transport = try await transport(io)
    _ = try await transport.read(.createOptions(projectID: "proj/1"))
    _ = try await transport.read(.agentSettings(agentID: "durable 1"))
    let urls = await io.requests.compactMap(\.url?.absoluteString)
    #expect(urls == ["https://127.0.0.1:4321/api/v1/mobile/projects/proj%2F1/create-options",
                     "https://127.0.0.1:4321/api/v1/mobile/agents/durable%201/settings"])
    #expect(await io.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token" })
}

@Test func createIsRefusedLocallyWhenTheDesktopDoesNotOfferIt() async throws {
    let io = RouteIO([capabilities(commands: ["agent.spawn"])])
    let transport = try await transport(io)
    _ = try await transport.read(.capabilities)
    await #expect(throws: AnnexTransportError.unsupportedCapability("agent.create")) {
        try await transport.execute(AnnexCommand(epoch: "epoch1", kind: .create(.init(projectID: "p", name: "n", color: "indigo"))))
    }
    #expect(await io.requests.count == 1)
}

@Test func createPostsToTheCommandsRoute() async throws {
    let io = RouteIO([capabilities(commands: ["agent.create"], extra: durableFeatures),
                      #"{"version":1,"commandId":"c1","epoch":"epoch1","status":"completed","result":{"agentId":"durable_1","projectId":"p","name":"n","branch":"n/standby","worktreePath":"/w","state":"creating"}}"#])
    let transport = try await transport(io)
    _ = try await transport.read(.capabilities)
    let receipt = try await transport.execute(AnnexCommand(commandID: "c1", epoch: "epoch1", kind: .create(.init(projectID: "p", name: "n", color: "indigo"))))
    #expect(receipt.result?["state"]?.string == "creating")
    let request = try #require(await io.requests.last)
    #expect(request.httpMethod == "POST" && request.url?.path == "/api/v1/mobile/commands")
}
