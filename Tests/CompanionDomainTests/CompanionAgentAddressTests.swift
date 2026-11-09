import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Machine-qualified agent addresses (#339, desktop `docs/annex-network-phone.md` §Agent addresses): `wrong_machine`
/// refusals, command identity across machines, and senders relayed from another machine of the network.
@Suite @MainActor struct CompanionAgentAddressTests {
    private typealias Harness = LiveServiceHarness
    static let otherID = "bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb:bb"
    static let unknownID = "cc:cc:cc:cc:cc:cc:cc:cc:cc:cc:cc:cc:cc:cc:cc:cc"

    /// A second desktop, "Studio Mac", with an agent of the same id in its own project.
    private func addStudio(to harness: Harness) async throws -> ScriptedAnnexTransport {
        let studio = ScriptedAnnexTransport()
        await studio.setProjects(.array([.object(["id": .string("studio-project"), "name": .string("Studio")])]))
        await studio.setAgents(.array([.object(["id": .string("agent"), "name": .string("Builder"), "status": .string("idle")])]))
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.2", port: 8443), verifiedHostID: Self.otherID,
                                        verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "02", count: 32)))
        await harness.service.register(.init(host: host, alias: "Studio Mac", transport: studio))
        try await harness.waitUntil {
            harness.store.hosts.first { $0.id == Self.otherID }?.allAgents.contains { $0.id.agentID == "agent" } == true
        }
        return studio
    }

    private func wrongMachine(_ machine: String, epoch: String = "epoch", commandID: String) throws -> AnnexCommandReceipt {
        try AnnexJSON.object([
            "version": .integer(1), "epoch": .string(epoch), "commandId": .string(commandID), "status": .string("rejected"),
            "error": .object(["code": .string("wrong_machine"), "message": .string("That agent is on another machine. Send this to that machine.")]),
            "machine": .string(machine),
        ]).decode(AnnexCommandReceipt.self)
    }

    private func refusal(_ body: () async throws -> Void) async -> CompanionWrongMachine? {
        do { try await body(); return nil }
        catch CompanionServiceError.wrongMachine(let refusal) { return refusal }
        catch { Issue.record("Expected wrong_machine, got \(error)"); return nil }
    }

    // MARK: wrong_machine

    @Test func aRefusalNamingAnotherOfThePhonesDesktopsOffersTheAgentThere() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let studio = try await addStudio(to: harness)
        try await harness.loadSession()
        await harness.transport.enqueue(.receipt(try wrongMachine(Self.otherID.uppercased(), commandID: "stop")))

        let refused = await refusal { try await harness.service.cancel(harness.target, clientCommandID: "stop") }
        let other = CompanionTarget(hostID: Self.otherID, projectID: "studio-project", agentID: "agent")
        #expect(refused == .init(machine: Self.otherID, machineName: "Studio Mac", agentName: "Builder", target: other))
        #expect(refused?.message == "Builder is on Studio Mac. Open it there to continue.")
        // Never re-sent on its own: the command carries this desktop's epoch and session.
        #expect(await studio.executed.isEmpty)
        #expect(await harness.transport.executed.count == 1)
    }

    @Test func aRefusalNamingAMachineThePhoneDoesntHaveIsAClearError() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        try await harness.loadSession()
        await harness.transport.enqueue(.receipt(try wrongMachine(Self.unknownID, commandID: "stop")))
        let refused = await refusal { try await harness.service.cancel(harness.target, clientCommandID: "stop") }
        #expect(refused?.machine == Self.unknownID && refused?.machineName == nil && refused?.target == nil)
        #expect(refused?.message == "That agent is on another computer, which isn't connected to this phone. Pair it to reach the agent.")
    }

    @Test func aRefusalNamingAKnownDesktopWithoutTheAgentNamesTheDesktop() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let studio = try await addStudio(to: harness)
        await studio.setAgents(.array([]))
        await studio.emit(.resyncRequired(.reconnected))
        try await harness.waitUntil { harness.store.hosts.first { $0.id == Self.otherID }?.allAgents.isEmpty == true }
        try await harness.loadSession()
        await harness.transport.enqueue(.receipt(try wrongMachine(Self.otherID, commandID: "stop")))
        let refused = await refusal { try await harness.service.cancel(harness.target, clientCommandID: "stop") }
        #expect(refused?.target == nil)
        #expect(refused?.message == "That agent is on Studio Mac. Open it from Studio Mac to continue.")
    }

    /// A malformed machine, or this desktop's own, isn't a usable redirect: the desktop's sentence is shown as a refusal.
    @Test func aRefusalWithoutAnotherWellFormedMachineIsAPlainRefusal() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        try await harness.loadSession()
        for (index, machine) in ["not-a-machine", Harness.hostID].enumerated() {
            await harness.transport.enqueue(.receipt(try wrongMachine(machine, commandID: "stop-\(index)")))
            #expect(await serviceErrorText { try await harness.service.cancel(harness.target, clientCommandID: "stop-\(index)") }
                    == "That agent is on another machine. Send this to that machine.")
        }
    }

    @Test func theProviderFlowReportsWrongMachineToo() async throws {
        let harness = try await CompanionProviderFlowTests().harness()
        defer { harness.stop() }
        await harness.transport.enqueue(.receipt(try wrongMachine(Self.unknownID, commandID: "preview")))
        #expect(await refusal { _ = try await harness.service.providerPreview(harness.target, provider: "codex-cli") }?.machine == Self.unknownID)
    }

    @Test func theStoreShowsTheRefusalAndOpensTheAgentOnItsMachine() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        _ = try await addStudio(to: harness)
        await harness.transport.setRead("chat", Harness.chatSnapshot(fields: ["capabilities": .object(["chat": .bool(true), "interrupt": .bool(true)])]))
        await harness.store.load(harness.target, force: true)
        try await harness.waitUntil { harness.store.agent(for: harness.target)?.capabilities.contains(.cancel) == true }
        await harness.transport.enqueue(.receipt(try wrongMachine(Self.otherID, commandID: "x")))
        await harness.store.cancel(harness.target)

        let other = CompanionTarget(hostID: Self.otherID, projectID: "studio-project", agentID: "agent")
        #expect(harness.store.operationErrors[harness.target] == "Builder is on Studio Mac. Open it there to continue.")
        #expect(harness.store.otherMachineTarget(for: harness.target) == other)
        harness.store.openOnOtherMachine(from: harness.target)
        #expect(harness.store.selection == other)
        #expect(harness.store.operationErrors[harness.target] == nil)
        #expect(harness.store.otherMachineTarget(for: harness.target) == nil)

        // Any other failure drops the offer.
        await harness.transport.enqueue(.rejected(code: "busy", message: "Try later"))
        await harness.store.cancel(harness.target)
        #expect(harness.store.operationErrors[harness.target] == "Try later")
        #expect(harness.store.otherMachineTarget(for: harness.target) == nil)
    }

    @Test func aRefusedSendShowsTheOfferOnTheChat() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        _ = try await addStudio(to: harness)
        try await harness.loadSession()
        await harness.store.load(harness.target, force: true)
        harness.store.drafts[harness.target] = "hello"
        await harness.transport.enqueue(.receipt(try wrongMachine(Self.otherID, commandID: "unused")))
        await harness.store.sendDraft(to: harness.target)
        #expect(harness.store.otherMachineTarget(for: harness.target)?.hostID == Self.otherID)
    }

    // MARK: Command identity

    /// A command id names one command on one desktop. The same id on another desktop is a different command, with
    /// that desktop's epoch, and doesn't replay the first desktop's saved command.
    @Test func savedCommandsAreKeptPerMachine() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let studio = try await addStudio(to: harness)
        await studio.setEpoch("studio-epoch")
        await studio.emit(.resyncRequired(.reconnected))
        try await harness.waitUntil { await studio.readRoutes.filter { $0.name == "capabilities" }.count >= 2 }
        try await harness.loadSession()
        await harness.transport.enqueue(.thrown(.commandOutcomeUnknown(commandID: "same")))
        _ = await serviceErrorText { try await harness.service.cancel(harness.target, clientCommandID: "same") }

        let other = CompanionTarget(hostID: Self.otherID, projectID: "studio-project", agentID: "agent")
        await studio.setRead("chat", Harness.chatSnapshot(session: "studio-session"))
        _ = try await harness.service.history(for: other)
        try await harness.service.cancel(other, clientCommandID: "same")
        let sent = try #require(await studio.executed.first)
        #expect(sent.epoch == "studio-epoch")
        #expect(sent.kind == .interrupt(agentID: "agent", sessionID: "studio-session"))

        // The first desktop's retry still replays exactly what it sent first.
        try await harness.service.cancel(harness.target, clientCommandID: "same")
        let retried = await harness.transport.executed
        #expect(retried.count == 2 && retried[0] == retried[1])
    }

    @Test func commandsNameAgentsByTheirBareIdOnTheirOwnDesktop() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        try await harness.loadSession()
        try await harness.service.cancel(harness.target, clientCommandID: "c")
        #expect(await harness.transport.executed.first?.agentReference == "agent")
        #expect(harness.target.address.formatted == "agent@\(Harness.hostID)")
    }

    // MARK: Senders on other machines

    private func agent(_ id: String, name: String, host: String, project: String = "p") -> CompanionAgent {
        .init(id: .init(hostID: host, projectID: project, agentID: id), name: name, subtitle: "", status: .idle, color: "indigo")
    }
    private func host(_ id: String, name: String, agents: [CompanionAgent]) -> CompanionHost {
        .init(id: id, name: name, endpoint: "", connection: .connected,
              projects: [.init(id: "p", name: "P", agents: agents)])
    }

    @Test func aSenderOnAnotherOfThePhonesDesktopsIsFoundThereAndNamedWithItsMachine() {
        let here = host(Harness.hostID, name: "Laptop", agents: [agent("agent", name: "Local", host: Harness.hostID)])
        let studio = host(Self.otherID, name: "Studio Mac", agents: [agent("agent", name: "Builder", host: Self.otherID)])
        let resolver = CompanionSenderResolver(host: here, hosts: [here, studio])

        let remote = CompanionRoutedMessagePart.Sender(agentID: "agent@\(Self.otherID.uppercased())", name: "Builder on Office")
        let found = resolver.resolve(remote)
        #expect(found?.name == "Builder on Studio Mac")
        #expect(found?.id == "agent@\(Self.otherID)")
        // The same id on this desktop is a different agent.
        #expect(resolver.resolve(.init(agentID: "agent", name: "Local"))?.name == "Local")
        // An address for this desktop is the bare id.
        #expect(resolver.resolve(.init(agentID: "agent@\(Harness.hostID)", name: "Local"))?.name == "Local")
    }

    @Test func aSenderTheMachineDoesntListKeepsItsNameWithTheMachine() {
        let here = host(Harness.hostID, name: "Laptop", agents: [agent("agent", name: "Local", host: Harness.hostID)])
        let studio = host(Self.otherID, name: "Studio Mac", agents: [])
        let resolver = CompanionSenderResolver(host: here, hosts: [here, studio])

        // Never falls back to a name match on this desktop when the id names another machine.
        let gone = CompanionRoutedMessagePart.Sender(agentID: "agent@\(Self.otherID)", name: "Local")
        #expect(resolver.resolve(gone) == nil)
        #expect(resolver.avatarIdentity(for: gone)?.name == "Local on Studio Mac")
        // The desktop's name already says the machine.
        #expect(resolver.avatarIdentity(for: .init(agentID: "agent@\(Self.otherID)", name: "Builder on Studio Mac"))?.name == "Builder on Studio Mac")
        // A machine the phone doesn't have: the desktop's name, which names its machine.
        let unknown = CompanionRoutedMessagePart.Sender(agentID: "agent@\(Self.unknownID)", name: "Builder on Office")
        #expect(resolver.avatarIdentity(for: unknown)?.name == "Builder on Office")
        // A sender on this desktop keeps its name.
        #expect(resolver.avatarIdentity(for: .init(agentID: "agent", name: "Local"))?.name == "Local")
    }
}
