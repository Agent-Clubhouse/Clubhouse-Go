import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// The visible chat's reconnect reload, and what may and may not wait for it.
/// After a resync the selected conversation reloads as soon as the desktop's capabilities are read for the new
/// connection: not after every project's agents. Commands still wait for the whole refresh (`.connected`), and
/// helper-routing labels fill in later without holding the connection gate or the serial event drain.
@MainActor @Suite struct DispatcherRefreshGateTests {
    typealias H = LiveServiceHarness

    static func helperRoutingPage(revision: String, marker: String) throws -> AnnexJSON {
        let bare = try #require(ContractFixtures.json("helper-routing.json")["bare"]?["response"]?["body"])
        guard case .object(var page) = bare, case .object(var labels)? = page["labels"],
              case .object(var reason)? = labels["reason"] else { throw AnnexTransportError.malformedResponse }
        reason["probe_marker"] = .string(marker)
        labels["reason"] = .object(reason)
        page["labels"] = .object(labels)
        page["revision"] = .string(revision)
        return .object(page)
    }
    static func configureHelperRouting(_ transport: ScriptedAnnexTransport) async throws {
        let caps = try ContractFixtures.body("capabilities.json")
        await transport.setFeature("helperRouting", caps["helperRouting"] ?? .null)
        await transport.setRead("helperRouting", try helperRoutingPage(revision: "r0.0", marker: "zero"))
    }
    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// A started harness whose selected conversation is loaded.
    static func selectedAndLoaded(configure: (ScriptedAnnexTransport) async -> Void = { _ in }) async throws -> H {
        let h = try await H.start(configure: configure)
        await h.transport.setRead("chat", H.chatSnapshot())
        h.store.selection = h.target
        await h.store.load(h.target, force: true)
        #expect(h.store.conversation(for: h.target).isLoaded)
        return h
    }
    /// Waits until the reconnect has finished: connected, and the conversation reloaded.
    static func settled(_ h: H) async throws {
        try await h.waitUntil {
            let c = h.store.conversation(for: h.target)
            return h.host?.connection == .connected && !c.isLoading && !c.requiresResync
        }
    }

    // MARK: Reload timing

    /// Returns ms from resync to the store's own `/chat` read, and the read order. Nothing here calls `load`.
    static func resyncToChatRead(projects n: Int, latency: Duration) async throws -> (ms: Double, routes: [String]) {
        let h = try await selectedAndLoaded { transport in
            await transport.setProjects(.array([.object(["id": .string("project"), "name": .string("Project")])]
                + (1..<max(1, n)).map { .object(["id": .string("p\($0)"), "name": .string("P\($0)")]) }))
        }
        defer { h.stop() }
        await h.transport.setReadDelay(latency)
        let baseline = await h.transport.readRoutes.count
        let chats = await h.transport.chatReads.count
        let start = ContinuousClock.now
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.chatReads.count > chats }
        let elapsed = ms(start.duration(to: .now))
        let routes = Array(await h.transport.readRoutes.map(\.name).dropFirst(baseline))
        try await settled(h)
        return (elapsed, routes)
    }

    @Test func visibleChatReloadDoesNotScaleWithProjectCount() async throws {
        let one = try await Self.resyncToChatRead(projects: 1, latency: .milliseconds(50))
        let many = try await Self.resyncToChatRead(projects: 14, latency: .milliseconds(50))
        print("GATE N=1 resync→chat \(Int(one.ms))ms routes=\(one.routes)")
        print("GATE N=14 resync→chat \(Int(many.ms))ms routes=\(many.routes)")
        let agentsBeforeChat = many.routes.prefix { $0 != "chat" }.filter { $0 == "agents" }.count
        #expect(agentsBeforeChat == 0, "visible /chat waited for \(agentsBeforeChat) agents reads")
        #expect(many.ms - one.ms < 300, "resync→chat grew by \(Int(many.ms - one.ms))ms for 13 more projects")
    }

    // MARK: Exactly one reload, of the selected conversation only

    @Test func reconnectLoadsTheSelectedChatExactlyOnce() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        // The early read is still in flight when the host becomes connected; the connected edge must not add one.
        let chats = await h.transport.chatReads.count
        await h.transport.holdNextRead("chat", returning: H.chatSnapshot())
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("chat") }
        try await h.waitUntil { h.host?.connection == .connected }
        #expect(h.store.conversation(for: h.target).isLoading)
        // A conversation coming on screen while that read owns it does not start a second one.
        await h.store.loadOnOpen(h.target)
        await h.transport.resumeRead("chat")
        try await Self.settled(h)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.transport.chatReads.count - chats == 1)

        // And with no overlap: an early read that finishes first is the only one.
        let again = await h.transport.chatReads.count
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.chatReads.count > again }
        try await Self.settled(h)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.transport.chatReads.count - again == 1)
    }

    @Test func aFailedEarlyReloadIsRetriedOnceWhenConnected() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        let chats = await h.transport.chatReads.count
        await h.transport.failRead("chat", .disconnected)
        await h.transport.pauseNextRead("projects")
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("projects") }
        try await h.waitUntil { h.store.conversation(for: h.target).error != nil && !h.store.conversation(for: h.target).isLoading }
        #expect(h.store.conversation(for: h.target).requiresResync)
        await h.transport.setRead("chat", H.chatSnapshot())
        await h.transport.resumeRead("projects")
        try await Self.settled(h)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.transport.chatReads.count - chats == 2)
    }

    @Test func reconnectReloadsOnlyTheSelectedConversation() async throws {
        let other = CompanionTarget(hostID: H.hostID, projectID: "project", agentID: "agent2")
        let h = try await H.start { transport in
            await transport.setAgents(.array([
                .object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")]),
                .object(["id": .string("agent2"), "name": .string("Agent 2"), "status": .string("idle")]),
            ]))
        }
        defer { h.stop() }
        await h.transport.setRead("chat", H.chatSnapshot())
        await h.store.load(h.target, force: true)
        await h.store.load(other, force: true)
        h.store.selection = other
        let chats = await h.transport.chatReads.count
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil {
            let c = h.store.conversation(for: other)
            return h.host?.connection == .connected && !c.isLoading && !c.requiresResync
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(Array(await h.transport.chatReads.dropFirst(chats)) == ["agent2"])
        #expect(h.store.conversation(for: h.target).requiresResync, "the unselected conversation waits until it is opened")

        // Selecting the stale one reloads it, once.
        h.store.selection = h.target
        try await Self.settled(h)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Array(await h.transport.chatReads.dropFirst(chats)) == ["agent2", "agent"])

        // Nothing selected: a reconnect reads no chat at all.
        h.store.selection = nil
        let none = await h.transport.chatReads.count
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { h.store.conversation(for: h.target).requiresResync }
        try await h.waitUntil { h.host?.connection == .connected }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.transport.chatReads.count == none)
    }

    // MARK: Commands stay gated

    @Test func sendAndApproveStayBlockedUntilTheHostIsOperable() async throws {
        let permission = H.chatEvent("s1", sequence: 3, type: "permission_request", data: [
            "requestId": .string("perm-1"), "toolName": .string("Bash"), "rawInput": .object(["command": .string("ls")]),
            "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow"), "kind": .string("allow_once")])])])
        let snapshot = H.chatSnapshot(fields: ["state": .string("waiting_permission"), "pendingPermissions": .array([permission])])
        let h = try await H.start()
        defer { h.stop() }
        await h.transport.setRead("chat", snapshot)
        h.store.selection = h.target
        await h.store.load(h.target, force: true)
        // A local, unconfirmed message must survive the early reload.
        h.store.drafts[h.target] = "Typed while away"

        await h.transport.pauseNextRead("projects")
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("projects") }
        try await h.waitUntil {
            let c = h.store.conversation(for: h.target)
            return c.isLoaded && !c.isLoading && !c.requiresResync
        }
        // The chat is current, but the catalog refresh is not done: nothing may be sent or approved yet.
        #expect(h.host?.connection == .synchronizing)
        #expect(h.host?.canReadHistory == true)
        #expect(!h.store.canOperate(h.target))
        #expect(!h.store.canSend(h.target))
        let approval = try #require(h.store.pinnedApproval(for: h.target))
        #expect(approval.resolution == .pending)
        let option = try #require(approval.options.first)
        await h.store.sendDraft(to: h.target)
        await h.store.respond(approval, option: option, target: h.target)
        #expect(await h.transport.executed.isEmpty)
        #expect(h.store.drafts[h.target] == "Typed while away")

        await h.transport.resumeRead("projects")
        try await h.waitUntil { h.host?.connection == .connected }
        #expect(h.store.canOperate(h.target))
        #expect(h.store.pinnedApproval(for: h.target)?.id == "perm-1")
        await h.store.respond(approval, option: option, target: h.target)
        #expect(await h.transport.executed.map(\.type) == ["chat.permission"])
    }

    // MARK: Retirement and stale completions

    /// #632: a resync retires a load that began on the previous connection; its late reply never lands.
    @Test func aResyncRetiresTheEarlyReloadAndItsLateReplyIsDropped() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        let old = H.chatSnapshot(events: [H.chatEvent("s1", sequence: 2, type: "agent_message",
                                                     data: ["messageId": .string("old"), "text": .string("Old")])])
        let new = H.chatSnapshot(events: [H.chatEvent("s1", sequence: 2, type: "agent_message",
                                                     data: ["messageId": .string("new"), "text": .string("New")])])
        await h.transport.holdNextRead("chat", returning: old)
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("chat") }
        #expect(h.store.conversation(for: h.target).isLoading)

        await h.transport.setRead("chat", new)
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.chatReads.count >= 3 }
        try await Self.settled(h)
        let ids = { h.store.conversation(for: h.target).items.map(\.id) }
        #expect(ids().contains("message:new"))
        await h.transport.resumeRead("chat")
        try await Task.sleep(for: .milliseconds(200))
        #expect(ids().contains("message:new"))
        #expect(!ids().contains("message:old"))
        #expect(!h.store.conversation(for: h.target).requiresResync)
    }

    /// A refresh pass that began before a newer resync cannot open history reads for the newer one.
    @Test func anOlderRefreshPassCannotMarkTheNewerConnectionReadable() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        let chats = await h.transport.chatReads.count
        await h.transport.pauseNextRead("capabilities")
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("capabilities") }
        await h.transport.pauseNextRead("projects")
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { h.host?.connection == .synchronizing }
        await h.transport.resumeRead("capabilities")
        try await h.waitUntil { await h.transport.isReadPaused("projects") }
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.host?.historyReadable == false)
        #expect(await h.transport.chatReads.count == chats)
        await h.transport.resumeRead("projects")
        try await Self.settled(h)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.transport.chatReads.count - chats == 1)
    }

    /// An authentication failure during synchronizing cancels the refresh; its capabilities reply opens nothing.
    @Test func anAuthenticationFailureKeepsTheChatClosed() async throws {
        let h = try await Self.selectedAndLoaded()
        defer { h.stop() }
        let chats = await h.transport.chatReads.count
        await h.transport.pauseNextRead("capabilities")
        await h.transport.emit(.resyncRequired(.reconnected))
        try await h.waitUntil { await h.transport.isReadPaused("capabilities") }
        await h.transport.emit(.connection(.failed(.rejected(status: 401, code: "peer_not_paired", message: nil))))
        try await h.waitUntil { if case .failed = h.host?.connection { true } else { false } }
        await h.transport.resumeRead("capabilities")
        try await Task.sleep(for: .milliseconds(200))
        guard case .failed = h.host?.connection else { Issue.record("connection left failed: \(String(describing: h.host?.connection))"); return }
        #expect(h.host?.canReadHistory == false)
        #expect(await h.transport.chatReads.count == chats)
        #expect(h.store.conversation(for: h.target).requiresResync)
        #expect(!h.store.canOperate(h.target))
    }

    // MARK: Helper-routing labels are not a gate

    /// Cold start: the label cache is empty; a held helper-routing read must not keep the host from connecting.
    @Test func connectedIsPublishedWhileHelperRoutingIsSlow() async throws {
        let h = try await H.start(waitForConnection: false) { transport in
            try? await Self.configureHelperRouting(transport)
            await transport.pauseNextRead("helperRouting")
        }
        defer { h.stop() }
        try await h.waitUntil { await h.transport.isReadPaused("helperRouting") }
        try await h.waitUntil { h.host?.connection == .connected }
        #expect(h.host?.helperRoutingLabels.isEmpty == true)
        await h.transport.resumeRead("helperRouting")
        // The labels still arrive once loaded.
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "zero" }
        #expect(h.host?.helperRoutingRevision == "r0.0")
    }

    /// A snapshot with a new revision starts a label read; chat events behind it apply at once, in order.
    @Test func chatEventsApplyInOrderWhileSnapshotLabelsLoad() async throws {
        let h = try await H.start { transport in try? await Self.configureHelperRouting(transport) }
        defer { h.stop() }
        await h.transport.setRead("chat", H.chatSnapshot())
        await h.store.load(h.target, force: true)
        let before = h.store.conversation(for: h.target).items.count
        await h.transport.holdNextRead("helperRouting", returning: try Self.helperRoutingPage(revision: "r9.9", marker: "nine"))
        await h.transport.emit(h.snapshotEvent(["helperRoutingRevision": .string("r9.9")]))
        try await h.waitUntil { await h.transport.isReadPaused("helperRouting") }
        for (seq, id) in [(Int64(2), "m2"), (3, "m3"), (4, "m4")] {
            await h.transport.emit(.message(.init(type: "chat:event", payload: .object([
                "agentId": .string("agent"),
                "event": H.chatEvent("s1", sequence: seq, type: "agent_message", data: ["messageId": .string(id), "text": .string(id)]),
            ]))))
        }
        try await h.waitUntil { h.store.conversation(for: h.target).items.count == before + 3 }
        #expect(h.store.conversation(for: h.target).items.suffix(3).map(\.id) == ["message:m2", "message:m3", "message:m4"])
        #expect(await h.transport.isReadPaused("helperRouting"), "the label read was still held while the events applied")
        await h.transport.resumeRead("helperRouting")
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "nine" }
    }

    @Test func aLateLabelReplyForAnOlderRevisionIsDropped() async throws {
        let h = try await H.start { transport in try? await Self.configureHelperRouting(transport) }
        defer { h.stop() }
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "zero" }
        await h.transport.holdNextRead("helperRouting", returning: try Self.helperRoutingPage(revision: "r1", marker: "one"))
        await h.transport.emit(.message(.init(type: "helper_routing:changed", payload: .object(["revision": .string("r1")]))))
        try await h.waitUntil { await h.transport.isReadPaused("helperRouting") }
        await h.transport.setRead("helperRouting", try Self.helperRoutingPage(revision: "r2", marker: "two"))
        await h.transport.emit(.message(.init(type: "helper_routing:changed", payload: .object(["revision": .string("r2")]))))
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "two" }
        await h.transport.resumeRead("helperRouting")
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.host?.helperRoutingRevision == "r2")
        #expect(h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "two")
        #expect(h.host?.connection == .connected)
    }

    @Test func aFailedLabelReadNeitherBlocksNorClobbersAndTheNextRevisionLoads() async throws {
        let h = try await H.start { transport in try? await Self.configureHelperRouting(transport) }
        defer { h.stop() }
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "zero" }
        await h.transport.failRead("helperRouting", .disconnected)
        await h.transport.emit(.message(.init(type: "helper_routing:changed", payload: .object(["revision": .string("r3")]))))
        try await h.waitUntil { await h.transport.readRoutes.filter { $0.name == "helperRouting" }.count >= 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.host?.connection == .connected)
        #expect(h.host?.helperRoutingRevision == "r3")
        #expect(h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "zero", "a failure keeps the last labels")
        await h.transport.setRead("helperRouting", try Self.helperRoutingPage(revision: "r4", marker: "four"))
        await h.transport.emit(.message(.init(type: "helper_routing:changed", payload: .object(["revision": .string("r4")]))))
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "four" }
    }

    /// A label read from before a reconnect is retired with its connection; its late reply is dropped.
    @Test func aLabelReplyFromAnOlderConnectionIsDropped() async throws {
        let h = try await H.start { transport in try? await Self.configureHelperRouting(transport) }
        defer { h.stop() }
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "zero" }
        await h.transport.holdNextRead("helperRouting", returning: try Self.helperRoutingPage(revision: "r1", marker: "one"))
        await h.transport.emit(.message(.init(type: "helper_routing:changed", payload: .object(["revision": .string("r1")]))))
        try await h.waitUntil { await h.transport.isReadPaused("helperRouting") }
        await h.transport.setRead("helperRouting", try Self.helperRoutingPage(revision: "r5", marker: "five"))
        await h.service.suspend()
        await h.service.resume()
        try await h.waitUntil { h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "five" }
        await h.transport.resumeRead("helperRouting")
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.host?.helperRoutingRevision == "r5")
        #expect(h.host?.helperRoutingLabels["reason"]?["probe_marker"] == "five")
    }

    // MARK: Per-project agents reads

    static let mergeProjects = (1...7).map { "p\($0)" }
    static func agentsList(_ project: String) -> AnnexJSON {
        .array([.object(["id": .string("\(project)-a"), "name": .string("A \(project)"), "status": .string("idle")])])
    }
    static func configureMergeProjects(_ transport: ScriptedAnnexTransport, reversed: Bool) async {
        await transport.setProjects(.array([.object(["id": .string("project"), "name": .string("Project")])]
            + mergeProjects.map { .object(["id": .string($0), "name": .string($0.uppercased())]) }))
        for (index, id) in mergeProjects.enumerated() {
            await transport.setAgents(agentsList(id), forProject: id)
            let step = reversed ? mergeProjects.count - index : index + 1
            await transport.setAgentsDelay(.milliseconds(10 * step), forProject: id)
        }
    }

    @Test(arguments: [false, true])
    func agentsReadsAreBoundedAndMergeInProjectOrder(reversed: Bool) async throws {
        let h = try await H.start { await Self.configureMergeProjects($0, reversed: reversed) }
        defer { h.stop() }
        let projects = try #require(h.host?.projects)
        #expect(projects.map(\.id) == ["project"] + Self.mergeProjects)
        for id in Self.mergeProjects {
            #expect(projects.first { $0.id == id }?.agents.map(\.id.agentID) == ["\(id)-a"])
        }
        #expect(projects.first?.agents.map(\.id.agentID) == ["agent"])
        let inFlight = await h.transport.maxAgentsInFlight
        #expect(inFlight >= 2 && inFlight <= CompanionLiveService.agentsReadConcurrency, "max in flight \(inFlight)")
        #expect(Set(await h.transport.agentsReadOrder.prefix(Self.mergeProjects.count)) == Set(Self.mergeProjects))
    }

    @Test func theMergeIsTheSameWhateverOrderReadsFinishIn() async throws {
        let projects: [AnnexJSON] = (Self.mergeProjects + ["p2"]).map { .object(["id": .string($0)]) } + [.object(["id": .string("")]), .object([:])]
        var results: [[String: AnnexJSON]] = []
        for reversed in [false, true] {
            let transport = await ScriptedAnnexTransport()
            await Self.configureMergeProjects(transport, reversed: reversed)
            results.append(try await CompanionLiveService.readAgents(projects, transport: transport))
            results.append(try await CompanionLiveService.readAgents(projects, transport: transport, limit: 1))
        }
        let expected = Dictionary(uniqueKeysWithValues: Self.mergeProjects.map { ($0, Self.agentsList($0)) })
        for result in results { #expect(result == expected) }
    }

    /// One failed agents read fails the refresh, as the serial loop did.
    @Test func aFailedAgentsReadFailsTheRefresh() async throws {
        let h = try await H.start { await Self.configureMergeProjects($0, reversed: false) }
        defer { h.stop() }
        await h.transport.failAgents(.rejected(status: 500, code: "internal", message: "Boom"), forProject: "p3")
        try await h.refreshCatalog(allowingFailure: true)
        guard case .failed = h.host?.connection else { Issue.record("expected failed, got \(String(describing: h.host?.connection))"); return }
    }
}
