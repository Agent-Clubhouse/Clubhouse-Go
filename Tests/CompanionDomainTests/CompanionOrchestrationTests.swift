import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// A durable agent's orchestration policy from the phone (`orchestration` v1, desktop #2232).

private func json(_ text: String) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }

private let policyJSON = #"""
{"orchestrate":true,"access":"auto","control":"ask-before-start","maxHelpers":3,
 "sources":{"orchestrate":"agent","access":"persona","control":"agent","maxHelpers":"default"},
 "maxHelpersCap":8,"controls":["hands-off","ask-before-start","ask-everything"],"accessLevels":["same","standard","auto","bypass"]}
"""#

private func settingsJSON(orchestration: String?) -> String {
    let field = orchestration.map { #","orchestration":\#($0)"# } ?? ""
    return #"""
    {"agentId":"durable_1","projectId":"p1","state":"running","sleeping":false,
     "settings":{"name":{"value":"planner","editable":"sleeping"},"freeAgentMode":{"value":false,"editable":"sleeping"},
      "idleSleep":{"value":"inherit","applies":true,"editable":"always"}}\#(field)}
    """#
}

@Suite struct CompanionOrchestrationDecodingTests {
    @Test func policyDecodesEveryField() throws {
        let policy = try #require(CompanionOrchestration(json: try json(policyJSON)))
        #expect(policy.orchestrate && policy.access == "auto" && policy.control == "ask-before-start")
        #expect(policy.maxHelpers == 3 && policy.maxHelpersCap == 8)
        #expect(policy.controls == ["hands-off", "ask-before-start", "ask-everything"])
        #expect(policy.accessLevels == ["same", "standard", "auto", "bypass"])
        #expect(policy.sources == ["orchestrate": .agent, "access": .persona, "control": .agent, "maxHelpers": .default])
        #expect(policy.summary == "ask before starting · up to 3", "The Orchestrate card's one line")
        #expect(policy.maxHelpersRange == 1...8)
    }

    @Test func missingAndUnknownFieldsReadAsTheDesktopsDefaults() throws {
        let empty = try #require(CompanionOrchestration(json: .object([:])))
        #expect(empty == CompanionOrchestration())
        #expect(!empty.orchestrate && empty.access == "same" && empty.control == "hands-off" && empty.maxHelpers == 5 && empty.maxHelpersCap == 20)
        #expect(empty.summary == "off")

        let odd = try #require(CompanionOrchestration(json: try json(#"""
        {"orchestrate":"yes","access":7,"control":"ask-the-moon","maxHelpers":0,"maxHelpersCap":-1,"controls":"all","sources":{"access":"nowhere","control":"agent"},"future":{"x":1}}
        """#)))
        #expect(!odd.orchestrate && odd.access == "same" && odd.maxHelpers == 5 && odd.maxHelpersCap == 20)
        #expect(odd.control == "ask-the-moon" && odd.controlChoices.last == "ask-the-moon", "An unknown control still shows, as itself")
        #expect(odd.controls == CompanionOrchestration.defaultControls)
        #expect(odd.sources == ["control": .agent])

        #expect(CompanionOrchestration(json: nil) == nil)
        #expect(CompanionOrchestration(json: .string("on")) == nil)
        #expect(CompanionOrchestration(json: .null) == nil)
    }

    @Test func aSavedValueAboveTheCapStillShows() {
        let policy = CompanionOrchestration(orchestrate: true, maxHelpers: 12, maxHelpersCap: 4)
        #expect(policy.maxHelpersRange == 1...12)
        #expect(CompanionOrchestration(access: "turbo").accessChoices == CompanionOrchestration.defaultAccessLevels + ["turbo"])
    }

    @Test func settingsCarryThePolicyWhenTheDesktopSendsIt() throws {
        let settings = try CompanionAgentSettings(json: try json(settingsJSON(orchestration: policyJSON)))
        #expect(settings.orchestration?.control == "ask-before-start")
        #expect(try CompanionAgentSettings(json: try json(settingsJSON(orchestration: nil))).orchestration == nil, "Older desktops send none")
        #expect(try CompanionAgentSettings(json: try json(settingsJSON(orchestration: "false"))).orchestration == nil)
    }

    @Test func anUpdateResultWithoutThePolicyKeepsTheOneOnScreen() throws {
        let shown = try CompanionAgentSettings(json: try json(settingsJSON(orchestration: policyJSON)))
        let result = try CompanionAgentSettings(json: try json(settingsJSON(orchestration: nil)))
        #expect(result.keepingOptions(of: shown).orchestration == shown.orchestration)
        let changed = try CompanionAgentSettings(json: try json(settingsJSON(orchestration: #"{"orchestrate":false}"#)))
        #expect(changed.keepingOptions(of: shown).orchestration?.orchestrate == false, "A result with the policy wins")
    }

    @Test func labelsAreTheDesktops() {
        #expect(CompanionOrchestration.accessLabel("same", agentName: "planner") == "Same as planner")
        #expect(["standard", "auto", "bypass"].map { CompanionOrchestration.accessLabel($0, agentName: "x") } == ["Ask first", "Auto", "Full access"])
        #expect(CompanionOrchestration.defaultControls.map(CompanionOrchestration.controlLabel) == ["Hands-off", "Ask before starting", "Ask for everything"])
        #expect(CompanionOrchestration.controlHelp("ask-everything", agentName: "x") == "Starting a helper and every dispose come to you.")
        #expect(CompanionOrchestration.controlHelp("unknown", agentName: "x") == nil)
    }

    @Test func changesConvertToAPatchAndShowBeforeTheDesktopAnswers() {
        let change = CompanionOrchestrationChange(orchestrate: .set(true), access: .clear, maxHelpers: .set(2))
        let update = AnnexAgentUpdate(agentID: "a", change: .init(orchestration: change))
        #expect(update == AnnexAgentUpdate(agentID: "a", orchestration: .init(orchestrate: .set(true), access: .clear, maxHelpers: .set(2))))
        #expect(CompanionSettingsChange(orchestration: .init()).isEmpty, "An empty orchestration change is no change")
        #expect(!CompanionSettingsChange(orchestration: .init(control: .clear)).isEmpty)

        let applied = change.applied(to: CompanionOrchestration(access: "auto", sources: ["access": .agent]))
        #expect(applied.orchestrate && applied.maxHelpers == 2 && applied.access == "auto")
        #expect(applied.sources["orchestrate"] == .agent && applied.sources["maxHelpers"] == .agent)
    }

    @Test func refusalsSayWhatToDo() {
        #expect(CompanionAgentCommandError.message(code: "invalid_orchestration", message: "maxHelpers must be a whole number from 1 to 20")
                == "maxHelpers must be a whole number from 1 to 20")
        #expect(CompanionAgentCommandError.message(code: "invalid_orchestration", message: "invalid_orchestration") == "The desktop couldn't accept these orchestration settings.")
        #expect(CompanionAgentCommandError.message(code: "orchestration_has_helpers", message: nil)?.contains("on the desktop") == true)
    }
}

// MARK: - Live service

private actor OrchestrationTransport: AnnexTransporting {
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    let orchestration: Bool
    private(set) var executed: [AnnexCommand] = []
    var receipt: AnnexJSON = .null
    init(orchestration: Bool) { self.orchestration = orchestration }
    func setReceipt(_ value: AnnexJSON) { receipt = value }
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func connect() { continuation?.yield(.connection(.connected)) }
    func disconnect() {}
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON {
        switch route {
        case .capabilities:
            var caps: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true),
                                             "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(256), "ttlMs": .integer(60000)]),
                                             "commands": .array(["agent.spawn", "agent.start", "agent.create", "agent.update"].map(AnnexJSON.string)),
                                             "createOptions": .object(["version": .integer(1)]), "agentSettings": .object(["version": .integer(1)])]
            if orchestration { caps["orchestration"] = .object(["version": .integer(1)]) }
            return .object(caps)
        case .projects: return .array([.object(["id": .string("p1"), "name": .string("Project")])])
        case .agents:
            var agent: [String: AnnexJSON] = ["id": .string("durable_1"), "name": .string("planner"), "kind": .string("durable"), "status": .string("sleeping")]
            if orchestration { agent["orchestration"] = try json(policyJSON) }
            return .array([.object(agent)])
        case .agentSettings: return try json(settingsJSON(orchestration: orchestration ? policyJSON : nil))
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        executed.append(command)
        return try receipt.decode(AnnexCommandReceipt.self)
    }
}

@Suite @MainActor struct CompanionOrchestrationLiveTests {
    private let hostID = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
    private var project: CompanionProjectTarget { .init(hostID: hostID, projectID: "p1") }
    private var agent: CompanionTarget { .init(hostID: hostID, projectID: "p1", agentID: "durable_1") }

    private func setup(_ transport: OrchestrationTransport) async throws -> (CompanionLiveService, CompanionStore) {
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                                        verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        await service.register(.init(host: host, alias: "Fixture", transport: transport))
        for _ in 0..<200 where store.hosts.first?.connection != .connected { try await Task.sleep(for: .milliseconds(5)) }
        try #require(store.hosts.first?.connection == .connected)
        return (service, store)
    }

    private func completed(_ result: AnnexJSON) -> AnnexJSON {
        .object(["version": .integer(1), "commandId": .string("x"), "epoch": .string("epoch"), "status": .string("completed"), "result": result])
    }

    @Test func aDesktopWithTheCapabilityShowsEachAgentsPolicy() async throws {
        let (_, store) = try await setup(OrchestrationTransport(orchestration: true))
        defer { store.stop() }
        #expect(store.hosts.first?.canOrchestrate == true)
        #expect(store.agent(for: agent)?.orchestration?.maxHelpers == 3, "The catalog carries the policy")
        #expect(try await store.settings(for: agent).orchestration?.access == "auto")
    }

    @Test func aDesktopWithoutTheCapabilityHidesIt() async throws {
        let transport = OrchestrationTransport(orchestration: false)
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        #expect(store.hosts.first?.canOrchestrate == false)
        #expect(store.agent(for: agent)?.orchestration == nil)
        do {
            _ = try await store.updateSettings(.init(orchestration: .init(orchestrate: .set(true))), target: agent)
            Issue.record("Expected the phone to refuse without sending")
        } catch {
            guard case CompanionServiceError.unavailable = error else { Issue.record("Expected unavailable, got \(error)"); return }
        }
        #expect(await transport.executed.isEmpty)

        await transport.setReceipt(try json(#"{"version":1,"commandId":"c1","epoch":"epoch","status":"completed","result":{"agentId":"durable_1","projectId":"p1"}}"#))
        #expect(await store.create(.init(project: project, name: "planner", color: "indigo", orchestrate: true, clientCommandID: "c1")))
        guard case .create(let sent)? = await transport.executed.first?.kind else { Issue.record("Expected agent.create"); return }
        #expect(sent.orchestration == nil, "Older desktops refuse unknown fields, so it's left out")
    }

    @Test func updateSendsThePatchAndShowsTheSavedPolicy() async throws {
        let transport = OrchestrationTransport(orchestration: true)
        await transport.setReceipt(completed(try json(settingsJSON(orchestration: #"{"orchestrate":true,"control":"hands-off","maxHelpers":4,"maxHelpersCap":8}"#))))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        let saved = try await store.updateSettings(.init(orchestration: .init(control: .clear, maxHelpers: .set(4))), target: agent)
        #expect(saved.orchestration?.maxHelpers == 4 && saved.orchestration?.control == "hands-off")
        guard case .update(let sent)? = await transport.executed.first?.kind else { Issue.record("Expected agent.update"); return }
        #expect(sent == AnnexAgentUpdate(agentID: "durable_1", orchestration: .init(control: .clear, maxHelpers: .set(4))))
    }

    @Test func createSendsOrchestrateWhenTurnedOn() async throws {
        let transport = OrchestrationTransport(orchestration: true)
        await transport.setReceipt(try json(#"{"version":1,"commandId":"c1","epoch":"epoch","status":"completed","result":{"agentId":"durable_1","projectId":"p1"}}"#))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        #expect(await store.create(.init(project: project, name: "planner", color: "indigo", orchestrate: true, clientCommandID: "c1")))
        guard case .create(let sent)? = await transport.executed.first?.kind else { Issue.record("Expected agent.create"); return }
        #expect(sent.orchestration == .init(orchestrate: .set(true)))
    }

    @Test func turningOffWithLiveHelpersSaysToUseTheDesktop() async throws {
        let transport = OrchestrationTransport(orchestration: true)
        await transport.setReceipt(try json(#"{"version":1,"epoch":"epoch","status":"rejected","error":{"code":"orchestration_has_helpers","message":"orchestration_has_helpers"}}"#))
        let (_, store) = try await setup(transport)
        defer { store.stop() }
        do {
            _ = try await store.updateSettings(.init(orchestration: .init(orchestrate: .set(false))), target: agent)
            Issue.record("Expected a refusal")
        } catch {
            guard case CompanionServiceError.rejected(let message) = error else { Issue.record("Expected a rejection, got \(error)"); return }
            #expect(message.contains("Turn orchestration off on the desktop"))
        }
    }
}
