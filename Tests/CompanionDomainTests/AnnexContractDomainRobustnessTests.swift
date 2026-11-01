import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Table-driven damage to the desktop's real fixtures, through the phone's domain decoders: a missing optional
/// field, an unknown field, a value of the wrong type or a cut-short document must never crash, and must degrade
/// as documented (skip the entry, fall back to a default, or refuse the read as malformed).
@Suite @MainActor struct AnnexContractDomainRobustnessTests {
    static let wrongTypes: [AnnexJSON] = [.string("x"), .integer(-3), .number(1e300), .bool(true), .array([.null]), .object(["x": .integer(1)]), .null]

    /// Every way to damage `value` one field at a time, down to `depth`: each field removed, and each set to every wrong type.
    static func damaged(_ value: AnnexJSON, depth: Int = 3) -> [AnnexJSON] {
        guard depth > 0 else { return [] }
        switch value {
        case .object(let fields):
            var out: [AnnexJSON] = []
            for (key, child) in fields {
                var removed = fields; removed.removeValue(forKey: key); out.append(.object(removed))
                for wrong in wrongTypes where wrong != child { var changed = fields; changed[key] = wrong; out.append(.object(changed)) }
                for inner in damaged(child, depth: depth - 1) { var changed = fields; changed[key] = inner; out.append(.object(changed)) }
            }
            var extra = fields; extra["futureField"] = .object(["nested": .array([.string("x")])]); out.append(.object(extra))
            return out
        case .array(let items):
            // The first item stands for the rest: they share one shape.
            guard let first = items.first else { return [] }
            return [.array([])] + damaged(first, depth: depth - 1).map { .array([$0] + items.dropFirst()) }
        default: return []
        }
    }

    @Test func createOptionsSurviveDamage() throws {
        let body = try ContractFixtures.body("create-options.json")
        var decoded = 0
        for value in Self.damaged(body) {
            guard let options = try? CompanionCreateOptions(json: value) else { continue }
            decoded += 1
            // Whatever survives is well formed: every option has an id, and a default is always chosen.
            #expect(options.options.orchestrators.allSatisfy { !$0.id.isEmpty })
            #expect(!options.defaultColor.isEmpty && !options.defaultModel.isEmpty)
        }
        #expect(decoded > 100)
        // Without orchestrators and defaults the form can't be built: refused, not guessed.
        guard case .object(var fields) = body else { return }
        fields.removeValue(forKey: "orchestrators"); fields.removeValue(forKey: "defaults")
        #expect(throws: (any Error).self) { try CompanionCreateOptions(json: .object(fields)) }
    }

    @Test func agentSettingsSurviveDamage() throws {
        let body = try ContractFixtures.body("agent-settings.json")
        var decoded = 0
        for value in Self.damaged(body) {
            guard let settings = try? CompanionAgentSettings(json: value) else { continue }
            decoded += 1
            #expect(!settings.name.value.isEmpty)
        }
        #expect(decoded > 100)
        guard case .object(var fields) = body, case .object(var settings)? = fields["settings"], case .object(var model)? = settings["model"] else { return }
        // A setting without `editable` is one the phone never offers to change.
        model.removeValue(forKey: "editable"); settings["model"] = .object(model); fields["settings"] = .object(settings)
        #expect(try CompanionAgentSettings(json: .object(fields)).model.editable == .never)
        // Without a name it isn't a settings document.
        settings.removeValue(forKey: "name"); fields["settings"] = .object(settings)
        #expect(throws: AnnexTransportError.malformedResponse) { try CompanionAgentSettings(json: .object(fields)) }
    }

    @Test func chatControlsSurviveDamage() throws {
        let controls = try #require(try ContractFixtures.body("chat-snapshot.json")["chatControls"])
        for value in Self.damaged(controls) {
            let decoded = CompanionChatControls(snapshot: value)
            // Only known levels and distinct, non-empty models and efforts survive.
            #expect(Set(decoded?.models.map(\.id) ?? []).count == decoded?.models.count ?? 0)
            #expect(decoded?.efforts.allSatisfy { !$0.isEmpty } ?? true)
        }
        #expect(CompanionChatControls(snapshot: .null) == nil)
        #expect(CompanionChatControls(snapshot: .array([])) == nil)
    }

    /// Damaged chat events fold without crashing; an event without its session, sequence or type is ignored.
    @Test func chatEventsSurviveDamage() throws {
        let events = (try ContractFixtures.json("chat-events.json")["frames"]).arrayValue.compactMap { $0["payload"]?["event"] }
        #expect(events.filter { $0["type"]?.string == "user_message" }.count == 5,
                "Every routed shape participates in the damage matrix")
        let snapshotEvents = (try ContractFixtures.body("chat-snapshot.json")["events"]).arrayValue
        for event in events + snapshotEvents {
            for value in Self.damaged(event, depth: 4) {
                var projection = CompanionChatProjector()
                projection.apply(value)
                projection.apply(value, allowOlderPending: true)
                if value["sessionId"]?.string == nil || value["seq"]?.integer == nil || value["type"]?.string == nil {
                    #expect(projection.items.isEmpty && projection.lastSequence == 0)
                }
            }
        }
    }

    /// A damaged chat snapshot still yields a conversation (or an error), never a crash.
    @Test func chatSnapshotSurvivesDamage() throws {
        let snapshot = try ContractFixtures.body("chat-snapshot.json")
        for value in Self.damaged(snapshot, depth: 2) {
            var projection = CompanionChatProjector()
            for event in value["events"].arrayValue { projection.apply(event) }
            for event in value["pendingPermissions"].arrayValue + value["pendingQuestions"].arrayValue { projection.apply(event, allowOlderPending: true) }
            if let caps = value["capabilities"], caps != .null { projection.updateCapabilities(caps) }
            if let controls = CompanionChatControls(snapshot: value["chatControls"]) { projection.controls = controls }
            projection.applyQueueSnapshot(value)
            _ = CompanionLiveService.contentRoots(from: value, windows: false)
            _ = CompanionChatProjector.status(value["state"]?.string)
        }
    }

    /// Helper requests: an entry without an id, kind, project or requester is skipped; a dispose without its
    /// facts can only be declined.
    @Test func helperRequestsSurviveDamage() throws {
        let list = try #require(try ContractFixtures.json("snapshot-helper-requests.json")["value"])
        for value in Self.damaged(list, depth: 4) {
            for request in CompanionLiveService.helperRequests(from: value, hostID: "h") {
                #expect(!request.id.isEmpty && !request.projectID.isEmpty && !request.requesterID.isEmpty)
                if request.kind == .dispose { #expect(request.helperID != nil) }
            }
        }
        guard case .array(let items) = list, case .object(var dispose) = items[1] else { return }
        dispose.removeValue(forKey: "dispose")
        let declineOnly = CompanionLiveService.helperRequests(from: .array([.object(dispose)]), hostID: "h")
        #expect(declineOnly.first?.dispose?.canDispose == false)
    }

    @Test func snapshotStateSurvivesDamage() throws {
        let payload = try #require(try ContractFixtures.json("snapshot.json")["frame"]?["payload"])
        for value in Self.damaged(try #require(payload["finishedQuickAgents"]), depth: 4) {
            for (_, runs) in CompanionFinishedRun.desktopLists(value, hostID: "h") ?? [:] { #expect(runs.allSatisfy { !$0.target.agentID.isEmpty }) }
        }
        for value in Self.damaged(try #require(payload["projectState"]), depth: 3) { _ = CompanionProjectState.map(from: value) }
        for value in Self.damaged(try #require(payload["theme"]), depth: 2) { _ = CompanionLiveService.theme(from: value, terminal: payload["terminalColors"]) }
        for value in Self.wrongTypes { _ = CompanionLiveService.idleDays(from: value) }
        // Not sent (an older desktop) is nil, so the phone keeps its own state; an empty object is an empty one.
        #expect(CompanionFinishedRun.desktopLists(nil, hostID: "h") == nil && CompanionProjectState.map(from: nil) == nil)
        #expect(CompanionFinishedRun.desktopLists(.object([:]), hostID: "h") == [:])
        for agent in (payload["agents"]?["proj_app"]).arrayValue {
            for value in Self.damaged(agent, depth: 2) {
                var model = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: "a"), name: "a", subtitle: "", status: .idle, model: nil)
                CompanionLiveService.applyIdentity(value, icon: value["icon"], to: &model)
                _ = CompanionLiveService.detail(from: value["detailedStatus"])
                _ = value["lastActivityAt"].flatMap(CompanionLiveService.date(from:))
            }
        }
    }

    /// The live service with a damaged snapshot frame: the host stays usable.
    @Test func damagedSnapshotFramesKeepTheHostUsable() async throws {
        let frame = try #require(try ContractFixtures.json("snapshot.json")["frame"])
        guard case .object(var envelope) = frame, case .object(let payload)? = envelope["payload"] else { return }
        let transport = ContractTransport()
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 7432), verifiedHostID: AnnexContractDomainTests.hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        defer { store.stop(); service.remove(hostID: AnnexContractDomainTests.hostID) }
        await service.register(.init(host: host, alias: "Studio Mac", transport: transport))
        for (key, _) in payload {
            for wrong in Self.wrongTypes {
                var damaged = payload; damaged[key] = wrong
                envelope["payload"] = .object(damaged)
                try transport.emit(.object(envelope))
            }
        }
        envelope["payload"] = .object(payload)
        try transport.emit(.object(envelope))
        for _ in 0..<400 where store.hosts.first?.projects.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.hosts.first?.projects.map(\.name) == ["App", "docs"])
    }
}
