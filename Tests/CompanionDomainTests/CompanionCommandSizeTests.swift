import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Catalog/events are scripted; commands go through the production byte preflight and network-error handling.
private actor SizeCheckedCommandTransport: AnnexTransporting {
    let catalog: ScriptedAnnexTransport
    let commands: AnnexTransport
    init(catalog: ScriptedAnnexTransport, commands: AnnexTransport) { self.catalog = catalog; self.commands = commands }
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> { await catalog.events() }
    func connect() async throws { try await catalog.connect() }
    func disconnect() async { await catalog.disconnect() }
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON { try await catalog.read(route) }
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt { try await commands.execute(command) }
}

private actor CommandSizeIO: AnnexIO {
    let capabilities: Data
    private(set) var posts = 0
    init(capabilities: Data) { self.capabilities = capabilities }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        if request.httpMethod == "POST" {
            posts += 1
            throw URLError(.networkConnectionLost)
        }
        return AnnexHTTPResponse(status: 200, data: capabilities)
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}

@Suite @MainActor struct CompanionCommandSizeTests {
    @Test(arguments: [true, false])
    func questionSurvivesLocalRefusalButNetworkFailureIsUncertain(oversized: Bool) async throws {
        let catalog = ScriptedAnnexTransport()
        await catalog.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["capabilities": .object(["chat": .bool(true), "questions": .bool(true)])]))
        let host = try LiveServiceHarness.trustedHost()
        let io = CommandSizeIO(capabilities: try JSONEncoder().encode(await catalog.read(.capabilities)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "test-only"), for: host.hostID)
        let commands = AnnexTransport(host: host, credentials: credentials, io: io)
        _ = try await commands.read(.capabilities)
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        defer { store.stop(); service.remove(hostID: host.hostID) }
        await service.register(.init(host: host, alias: "Fixture", transport: SizeCheckedCommandTransport(catalog: catalog, commands: commands)))
        let target = CompanionTarget(hostID: host.hostID, projectID: "project", agentID: "agent")
        for _ in 0..<1000 {
            if store.canOperate(target) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.canOperate(target))
        _ = try await service.history(for: target)
        for _ in 0..<1000 {
            if store.agent(for: target)?.capabilities.contains(.answer) == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.agent(for: target)?.capabilities.contains(.answer) == true)
        let question = CompanionQuestion(id: "q", prompts: [
            .init(id: String(repeating: "Long question 🦊", count: 30), text: "Which option?",
                  options: [.init(id: "blue", label: "Blue")], allowsMultiple: false, allowsFreeText: false),
            .init(id: "details", text: "Anything else?", options: [], allowsMultiple: false, allowsFreeText: true),
        ])
        store.apply(.upsert(target, .question(question), sequence: 1))
        let answers: [String: CompanionAnswer] = [question.prompts[0].id: .text("blue"),
            "details": .text(oversized ? String(repeating: "é🦊\"\\\n", count: 100_000) : "A small answer")]
        await store.answer(question, answers: answers, target: target)
        let item = try #require(store.conversation(for: target).items.first { $0.id == "question:q" })
        guard case .question(let current) = item else { Issue.record("Question was lost"); return }
        var expected = question
        expected.resolution = oversized ? .pending : .uncertain
        #expect(current == expected, "The entire question and its stable identity survive; the card keeps its local selections")
        #expect(store.conversation(for: target).requiresResync == !oversized)
        #expect(store.operationErrors[target] == (oversized ? "This command is too large to send. Nothing was sent."
            : "The desktop may have received this command, but its reply was lost."))
        #expect(!store.pendingCommands.contains(target))
        for _ in 0..<10 { await Task.yield() }
        #expect(await io.posts == (oversized ? 0 : 1), "Neither outcome automatically redispatches")
    }
}
