import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

private enum OverflowMode: String, Sendable { case healthy, emptyMinimal, emptyExplicit, tooLarge, failed, close1013 }
private actor AuditSocket: AnnexWebSocket {
    private var packets: [Data]
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    private(set) var sent: [Data] = []
    init(_ packet: Data) { packets = [packet] }
    func receive() async throws -> Data {
        if closed { throw URLError(.networkConnectionLost) }
        if !packets.isEmpty { return packets.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ packet: Data) { if let pending { self.pending = nil; pending.resume(returning: packet) } else { packets.append(packet) } }
    func send(_ data: Data) { sent.append(data) }
    func ping() throws { if closed { throw URLError(.networkConnectionLost) } }
    func close() { closed = true; pending?.resume(throwing: URLError(.networkConnectionLost)); pending = nil }
}
private final class CloseCodeLog: @unchecked Sendable {
    let lock = NSLock(); private var codes: [Int] = []
    func add(_ code: Int) { lock.withLock { codes.append(code) } }
    var values: [Int] { lock.withLock { codes } }
}
private final class AuditCloseDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let codes: CloseCodeLog
    private let lock = NSLock(); private var didOpen = false
    var opened: Bool { lock.withLock { didOpen } }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { lock.withLock { didOpen = true } }
    init(_ codes: CloseCodeLog) { self.codes = codes }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { codes.add(closeCode.rawValue) }
}
private final class AuditURLSocket: AnnexWebSocket, @unchecked Sendable {
    let session: URLSession
    let delegate: AuditCloseDelegate
    let task: URLSessionWebSocketTask
    let codes: CloseCodeLog
    init(port: Int, codes: CloseCodeLog) {
        self.codes = codes
        delegate = AuditCloseDelegate(codes)
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!); task.resume()
    }
    func waitForOpen() async throws {
        for _ in 0..<1000 { if delegate.opened { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw URLError(.cannotConnectToHost)
    }
    func receive() async throws -> Data {
        do { switch try await task.receive() { case .data(let value): return value; case .string(let value): return Data(value.utf8); @unknown default: throw URLError(.badServerResponse) } }
        catch {
            let value = error as NSError
            print("BUILD147_CLOSE_RECEIVE code=\(task.closeCode.rawValue) errorDomain=\(value.domain) errorCode=\(value.code)")
            try? await Task.sleep(for: .milliseconds(15))
            throw error
        }
    }
    func send(_ data: Data) async throws { try await task.send(.data(data)) }
    func ping() async throws { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in task.sendPing { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } } } }
    func close() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
private final class SleepLog: @unchecked Sendable {
    let lock = NSLock(); private var durations: [Double] = []
    func add(_ duration: Duration) { lock.withLock { durations.append(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) } }
    var values: [Double] { lock.withLock { durations } }
    var backoffs: [Double] { lock.withLock { durations.filter { $0 > 0 && $0 < 20 } } }
}
private actor AuditIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    let script: ScriptedAnnexTransport
    let closeCodes = CloseCodeLog()
    var mode = OverflowMode.healthy
    var opened = 0
    var commands = 0
    var permissionRejections = 0
    var fixtureAgentID = "agent"
    var initialSequence: Int64 = 0
    var receipts: [String: AnnexJSON] = [:]
    var helperReceipt: AnnexJSON?
    var holdHelper = false
    var helperWaiting = false
    var helperGate: CheckedContinuation<Void, Never>?
    func setHelperReceipt(_ value: AnnexJSON, hold: Bool = false) { helperReceipt = value; holdHelper = hold }
    func releaseHelper() { holdHelper = false; helperGate?.resume(); helperGate = nil }

    var recordedCommands: [AnnexJSON] = []
    func configureFixture(agentID: String, sequence: Int64, persistent: Bool) async {
        fixtureAgentID = agentID; initialSequence = sequence
        await script.setAgents(.array([.object(["id": .string(agentID), "name": .string("Fixture agent"), "status": .string("idle")])]))
        await script.setFeature("permissions", .object(["version": .integer(1), "persistentApprovals": .bool(persistent)]))
    }
    func setReceipts(_ value: [String: AnnexJSON]) { receipts = value }

    var chat: AnnexJSON?
    var chatStatus = 200
    var chatReads = 0
    var wireProxy: (PinnedAnnexIO, UInt16)?
    func setWireProxy(_ value: PinnedAnnexIO, port: UInt16) { wireProxy = (value, port) }
    var chatQueries: [String] = []
    var chatProxy: (PinnedAnnexIO, UInt16)?
    func setChatProxy(_ value: PinnedAnnexIO, port: UInt16) { chatProxy = (value, port) }
    func terminalSends() async -> [AnnexJSON] { await socket?.sent.compactMap { try? JSONDecoder().decode(AnnexJSON.self, from: $0) } ?? [] }
    func setInitialSequence(_ value: Int64) { initialSequence = value }
    func setChat(_ value: AnnexJSON) { chat = value; chatStatus = 200 }
    func setChatResponse(_ value: AnnexJSON, status: Int) { chat = value; chatStatus = status }
    var socket: AuditSocket?
    let port: Int
    init(port: Int, script: ScriptedAnnexTransport) { self.port = port; self.script = script }
    func configure() async {
        await script.setFeature("dispatcher", .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true), "newLayout": .bool(true), "projectId": .string("__dispatcher__")]))
        await script.setFeature("terminal", .object(["version": .integer(1), "projectShell": .bool(true), "agentShell": .bool(true), "agentAttach": .bool(true)]))
        await script.setFeature("helperRequests", .object(["version": .integer(1)]))
        await script.addCommands(["helper.approve", "helper.decline", "dispatcher.setEnabled"])
    }
    func setMode(_ value: OverflowMode) { mode = value }
    func setProjectName(_ name: String) async { await script.setProjects(.array([.object(["id": .string("project"), "name": .string(name)])])) }
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        let path = request.url!.path
        if path.hasSuffix("/chat") {
            chatReads += 1; chatQueries.append(request.url!.query ?? "")
            if let (proxy, port) = chatProxy {
                var forwarded = request
                var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                url.port = Int(port); forwarded.url = url.url!
                return try await proxy.perform(forwarded)
            }
        }
        let value: AnnexJSON
        var status = 200
        if path.hasSuffix("/identity") {
            value = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if request.httpMethod == "POST" {
            commands += 1
            let command = try JSONDecoder().decode(AnnexJSON.self, from: request.httpBody!)
            recordedCommands.append(command)
            if command["type"]?.string?.hasPrefix("helper.") == true, let receipt = helperReceipt, case .object(var body)? = receipt["body"] {
                if holdHelper { helperWaiting = true; await withCheckedContinuation { helperGate = $0 }; helperWaiting = false }
                status = Int(receipt["status"]?.integer ?? 200)
                body["epoch"] = .string("epoch"); body["commandId"] = command["commandId"]
                value = .object(body)
            } else if command["type"]?.string == "chat.permission", let receipt = receipts[command["optionId"]?.string ?? ""], case .object(var body)? = receipt["body"] {
                status = Int(receipt["status"]?.integer ?? 200)
                body["epoch"] = .string("epoch"); body["commandId"] = command["commandId"]
                value = .object(body)
            } else if command["type"]?.string == "chat.permission", command["optionId"]?.string == "allow" {
                permissionRejections += 1; status = 409
                value = .object(["version": .integer(1), "epoch": .string("epoch"), "commandId": command["commandId"]!, "status": .string("rejected"), "error": .object(["code": .string("incomplete_representation"), "message": .string("This input is incomplete. Review the full request on desktop before approving.")])])
            } else {
                value = .object(["version": .integer(1), "epoch": .string("epoch"), "commandId": command["commandId"]!, "status": .string("completed")])
            }
        } else if path.hasSuffix("/capabilities") { value = try await script.read(.capabilities)
        } else if path.hasSuffix("/projects") { value = try await script.read(.projects)
        } else if path.hasSuffix("/chat") { status = chatStatus; if let chat { value = chat } else { value = await LiveServiceHarness.chatSnapshot() }
        } else if path.hasSuffix("/agents") { value = try await script.read(.agents(projectID: "project"))
        } else { value = .object([:]) }
        return try .init(status: status, data: JSONEncoder().encode(value))
    }
    static func fullPayload(name: String = "Project") throws -> [String: AnnexJSON] {
        ["projects": .array([.object(["id": .string("project"), "name": .string(name)])]),
         "agents": .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])])]),
         "dispatcher": .object(["enabled": .bool(true), "flagOn": .bool(true), "projectId": .string("__dispatcher__"), "agent": .object(["id": .string("dispatcher"), "projectId": .string("__dispatcher__"), "name": .string("Dispatcher"), "status": .string("running")])]),
         "helperRequests": try ContractFixtures.json("snapshot-helper-requests.json")["value"]!, "protocolVersion": .integer(1), "lastSeq": .integer(0)]
    }
    func openWebSocket(_ request: URLRequest) async throws -> any AnnexWebSocket {
        opened += 1
        if let (proxy, port) = wireProxy {
            var forwarded = request
            var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            url.port = Int(port); forwarded.url = url.url!
            return try await proxy.openWebSocket(forwarded)
        }
        if mode == .close1013 {
            let socket = AuditURLSocket(port: port, codes: closeCodes)
            try await socket.waitForOpen()
            return socket
        }
        let frame: AnnexJSON
        if mode == .tooLarge || mode == .failed {
            frame = .object(["type": .string("error"), "payload": .object(["message": .string(mode == .failed ? "snapshot_failed" : "snapshot_too_large")])])
        } else {
            var payload = try Self.fullPayload()
            payload["lastSeq"] = .integer(initialSequence)
            payload["agents"] = .object(["project": try await script.read(.agents(projectID: "project"))])
            if mode == .emptyMinimal || mode == .emptyExplicit {
                payload = ["projects": .array([]), "agents": .object([:]), "lastSeq": .integer(0), "snapshotTruncated": .object(["version": .integer(1), "reason": .string("core_overflow")])]
                if mode == .emptyExplicit { payload["dispatcher"] = .null; payload["helperRequests"] = .array([]) }
            }
            frame = .object(["type": .string("snapshot"), "epoch": .string("epoch"), "payload": .object(payload)])
        }
        let socket = AuditSocket(try JSONEncoder().encode(frame)); self.socket = socket; return socket
    }
    func push(_ packet: Data) async { await socket?.push(packet) }
}
@MainActor private final class HostTape {
    var projects: [Int] = []
    func record(_ hosts: [CompanionHost]) { if let host = hosts.first { projects.append(host.projects.count) } }
}
@MainActor private struct FullAuditHarness {
    let io: AuditIO, transport: AnnexTransport, service: CompanionLiveService, store: CompanionStore
    let manual: AnnexManualClock, sleeps: SleepLog
    let hostID: String
    let tape: HostTape
    let observer: Task<Void, Never>
    let fixtureAgentID: String
    var target: CompanionTarget { .init(hostID: hostID, projectID: "project", agentID: fixtureAgentID) }
    var dispatcher: CompanionTarget { .init(hostID: hostID, projectID: "__dispatcher__", agentID: "dispatcher") }
    var host: CompanionHost? { store.hosts.first }
    static func start(mode: OverflowMode = .healthy, realTime: Bool = false, wireProxy: (PinnedAnnexIO, UInt16)? = nil, agentID: String = "agent", initialSequence: Int64 = 0, persistent: Bool = false, chatOverride: AnnexJSON? = nil, chatStatus: Int = 200) async throws -> Self {
        let io = AuditIO(port: 0, script: ScriptedAnnexTransport())
        if let (proxy, port) = wireProxy { await io.setWireProxy(proxy, port: port) }
        await io.configure(); await io.setMode(mode)
        await io.configureFixture(agentID: agentID, sequence: initialSequence, persistent: persistent)
        if let chatOverride { await io.setChatResponse(chatOverride, status: chatStatus) }
        let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID, verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let credentials = MemoryAnnexCredentialStore(); await credentials.save(try AnnexCredential(bearerToken: "fixture-only"), for: hostID)
        let manual = AnnexManualClock(origin: Date().addingTimeInterval(-1000)); let sleeps = SleepLog()
        let clock = realTime
            ? AnnexClock(now: { Date() }, sleep: { duration in sleeps.add(duration); try await Task.sleep(for: duration) })
            : AnnexClock(now: manual.clock.now, sleep: { duration in sleeps.add(duration); try await manual.clock.sleep(duration) })
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, clock: clock)
        let service = CompanionLiveService(); let store = CompanionStore(service: service, clock: clock); store.start()
        let tape = HostTape(); let events = service.events()
        let observer = Task { for await event in events { if case .hosts(let hosts) = event { tape.record(hosts) } } }
        let harness = Self(io: io, transport: transport, service: service, store: store, manual: manual, sleeps: sleeps, hostID: hostID, tape: tape, observer: observer, fixtureAgentID: agentID)
        await service.register(.init(host: host, alias: "fixture", transport: transport))
        if mode == .healthy {
            try await harness.wait { harness.host?.connection == .connected && harness.host?.dispatcher?.liveAgent != nil && harness.host?.helperRequests.isEmpty == false }
            store.selection = harness.dispatcher
            await store.load(harness.target); await store.load(harness.dispatcher)
        } else { try await harness.wait { await io.opened > 0 && harness.manual.sleeperCount >= (mode == .failed ? 2 : 1) }; try await Task.sleep(for: .milliseconds(30)) }
        return harness
    }
    func stop() async { observer.cancel(); store.stop(); service.remove(hostID: hostID); await transport.disconnect() }
    func wait(tries: Int = 2000, _ condition: () async -> Bool) async throws {
        for _ in 0..<tries { if await condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        Issue.record("Full audit condition timed out"); throw URLError(.timedOut)
    }
    func command() async -> Bool {
        do { _ = try await service.send(.init(target: target, text: "fixture", clientCommandID: UUID().uuidString, isSteering: false)); return true } catch { return false }
    }
    func summary(_ label: String) async {
        print("BUILD147_CORE case=\(label) connection=\(String(describing: host?.connection)) projects=\(host?.projects.count ?? -1) agents=\(host?.projects.flatMap(\.agents).count ?? -1) helpers=\(host?.helperRequests.count ?? -1) dispatcher=\(host?.dispatcher?.liveAgent != nil) agentChat=\(store.conversation(for: target).items.count) dispatcherChat=\(store.conversation(for: dispatcher).items.count) uiCanOperate=\(store.canOperate(target)) uiDispatcherCanOperate=\(store.canOperate(dispatcher)) observedEmptyCatalog=\(tape.projects.contains(0)) command=\(await command()) opens=\(await io.opened) backoffs=\(sleeps.backoffs) closeCodes=\(io.closeCodes.values)")
    }
}

private extension FullAuditHarness {
    func frame(_ type: String, seq: Int64? = nil, payload: AnnexJSON, replayed: Bool = false) async throws {
        var fields: [String: AnnexJSON] = ["type": .string(type), "epoch": .string("epoch"), "payload": payload]
        fields["seq"] = seq.map(AnnexJSON.integer)
        if replayed { fields["replayed"] = .bool(true) }
        await io.push(try JSONEncoder().encode(AnnexJSON.object(fields)))
    }
    func chatEvent(_ type: String, seq: Int64, global: Int64, data: [String: AnnexJSON], replayed: Bool = false) async throws {
        try await frame("chat:event", seq: global, payload: .object(["agentId": .string("agent"), "event": LiveServiceHarness.chatEvent("s1", sequence: seq, type: type, data: data)]), replayed: replayed)
    }
    static func criticalSnapshot(extra: [AnnexJSON] = []) -> AnnexJSON {
        let permission = LiveServiceHarness.chatEvent("s1", sequence: 2, type: "permission_request", data: ["requestId": .string("critical-permission"), "toolName": .string("Write"), "description": .string("Write reviewed file"), "rawInput": .object(["file_path": .string("/fake/review.txt"), "content": .string("FULL INPUT")]), "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow"), "kind": .string("allow_once")]), .object(["optionId": .string("deny"), "label": .string("Deny"), "kind": .string("reject_once")])])])
        let question = LiveServiceHarness.chatEvent("s1", sequence: 3, type: "question", data: ["requestId": .string("critical-question"), "questions": .array([.object(["id": .string("which"), "prompt": .string("Which branch?"), "allowFreeText": .bool(true)])])])
        let queued = LiveServiceHarness.chatEvent("s1", sequence: 4, type: "user_message", data: ["messageId": .string("critical-queued"), "text": .string("queued prompt"), "delivery": .string("queued")])
        let queue = LiveServiceHarness.chatEvent("s1", sequence: 5, type: "queue_state", data: ["queuedMessageIds": .array([.string("critical-queued")]), "transition": .object(["messageIds": .array([.string("critical-queued")]), "status": .string("queued")])])
        return LiveServiceHarness.chatSnapshot(events: [queued, queue] + extra, fields: ["state": .string("waiting_input"), "pendingPermissions": .array([permission]), "pendingQuestions": .array([question]), "queuedMessageIds": .array([.string("critical-queued")]), "queueStateSeq": .integer(5), "capabilities": .object(["chat": .bool(true), "queue": .string("client"), "questions": .bool(true), "planApproval": .bool(true)])])
    }
    func seed() async {
        await io.setChat(Self.criticalSnapshot())
        await store.load(target, force: true)
    }
    func assertCritical(status: CompanionAgentStatus = .waiting) {
        let conversation = store.conversation(for: target)
        #expect(conversation.items.contains { if case .approval(let a) = $0 { a.id == "critical-permission" && a.resolution == .pending } else { false } })
        #expect(conversation.items.contains { if case .question(let q) = $0 { q.id == "critical-question" && q.resolution == .pending } else { false } })
        #expect(conversation.items.contains { if case .message(let m) = $0 { m.id == "critical-queued" && m.queueState == .queued } else { false } })
        #expect(store.agent(for: target)?.status == status)
        #expect(conversation.sessionID == "s1")
        #expect(conversation.lastSequence ?? 0 >= 5)
    }
    func recoverFullHistory(extra: [AnnexJSON] = [], status: CompanionAgentStatus = .waiting) async {
        var snapshot = Self.criticalSnapshot(extra: extra)
        if status == .working, case .object(var fields) = snapshot { fields["state"] = .string("running"); snapshot = .object(fields) }
        await io.setChat(snapshot)
        await store.load(target, force: true)
        #expect(store.conversation(for: target).error == nil)
        #expect(!store.conversation(for: target).requiresResync)
        assertCritical(status: status)
    }
}

@MainActor @Suite(.serialized) struct FrameWireAuditTests {
    @Test func proposedPendingOverflowRefreshAndRemoval() async throws {
        let h = try await FullAuditHarness.start(); await h.seed()
        func permission(_ id: String, _ seq: Int64) -> AnnexJSON {
            LiveServiceHarness.chatEvent("s1", sequence: seq, type: "permission_request", data: ["requestId": .string(id), "toolName": .string("Write"), "description": .string("Review " + id), "options": .array([.object(["optionId": .string("deny"), "label": .string("Deny"), "kind": .string("reject_once")])])])
        }
        func page(_ pending: [AnnexJSON], events: [AnnexJSON] = [], watermark: Int64) -> AnnexJSON {
            LiveServiceHarness.chatSnapshot(events: events + [LiveServiceHarness.chatEvent("s1", sequence: watermark, type: "agent_message", data: ["messageId": .string("watermark"), "text": .string("current")])], fields: ["state": .string("waiting_permission"), "pendingPermissions": .array(pending), "pendingPermissionsOmitted": .object(["count": .integer(1), "oldestOmittedSeq": .integer(7)]), "capabilities": .object(["chat": .bool(true), "permissions": .bool(true)])])
        }
        func approval(_ id: String) -> CompanionApproval? { h.store.conversation(for: h.target).items.compactMap { if case .approval(let a) = $0, a.id == id { a } else { nil } }.first }
        do {
            let a = permission("oldest", 6), b = permission("omitted", 7)
            await h.io.setChat(page([a], watermark: 8)); await h.store.load(h.target, force: true)
            #expect(approval("oldest") != nil); #expect(approval("omitted") == nil)
            let reads = await h.io.chatReads
            try await h.chatEvent("permission_resolved", seq: 9, global: 1, data: ["requestId": .string("oldest"), "decision": .string("allow")])
            try await h.wait { approval("oldest")?.resolution == .allowed }
            await h.io.setChat(page([b], watermark: 10))
            try await Task.sleep(for: .milliseconds(150))
            #expect(await h.io.chatReads == reads); #expect(approval("omitted") == nil)
            h.store.selection = h.dispatcher; h.store.selection = h.target
            await h.store.load(h.target, force: h.store.conversation(for: h.target).requiresResync)
            #expect(await h.io.chatReads == reads); #expect(approval("omitted") == nil)
            await h.store.load(h.target, force: true)
            #expect(approval("omitted")?.resolution == .pending)
            // Live card missing from a current capped history disappears when its request event is absent too.
            try await h.chatEvent("permission_request", seq: 11, global: 2, data: ["requestId": .string("live"), "toolName": .string("Write"), "options": .array([])])
            try await h.wait { approval("live") != nil }
            await h.io.setChat(page([a], watermark: 12)); await h.store.load(h.target, force: true)
            #expect(approval("live") == nil); #expect(approval("omitted") == nil)
            // Missing only from pendingPermissions is not deletion if the event tail includes the request.
            await h.io.setChat(page([a], events: [b], watermark: 13)); await h.store.load(h.target, force: true)
            #expect(approval("omitted")?.resolution == .pending)
            // A stale HTTP page preserves newer live items in Store (not an authoritative safety guarantee).
            try await h.chatEvent("permission_request", seq: 20, global: 3, data: ["requestId": .string("newer"), "toolName": .string("Write"), "options": .array([])])
            try await h.wait { approval("newer") != nil }
            await h.io.setChat(page([a], watermark: 14)); await h.store.load(h.target, force: true)
            #expect(approval("newer")?.resolution == .pending)
            #expect(await h.io.opened == 1)
            print("PERMISSION_OVERFLOW synthetic=true resolvedAutoRead=false reenterRead=false menuForceRefresh=recovers currentCappedPage=removesMissingLive pendingListOnly=notAuthoritativeIfEventPresent stalePage=keepsNewer")
            await h.stop()
        } catch { await h.stop(); throw error }
    }

    @Test func unknownNextSequenceAdvancesWithoutResyncButDoesNotRecoverOmittedState() async throws {
        let h = try await FullAuditHarness.start(); await h.seed(); h.assertCritical()
        do {
            try await h.frame("frame:omitted", seq: 1, payload: .object(["originalType": .string("chat:event"), "bytes": .integer(20_000_000), "agentId": .string("agent")]))
            try await h.chatEvent("agent_message", seq: 6, global: 1, data: ["messageId": .string("duplicate-must-not-appear"), "text": .string("duplicate")])
            try await h.chatEvent("agent_message", seq: 6, global: 2, data: ["messageId": .string("after-omitted"), "text": .string("still connected")])
            try await h.wait { h.store.conversation(for: h.target).items.contains { $0.id == "message:after-omitted" } }
            #expect(!h.store.conversation(for: h.target).items.contains { $0.id == "message:duplicate-must-not-appear" })
            #expect(h.host?.connection == .connected)
            #expect(!h.store.conversation(for: h.target).requiresResync)
            #expect(await h.io.opened == 1)
            h.assertCritical()
            let full = LiveServiceHarness.chatEvent("s1", sequence: 7, type: "agent_message", data: ["messageId": .string("full-history"), "text": .string("omitted text restored by HTTP")])
            await h.recoverFullHistory(extra: [full])
            #expect(h.store.conversation(for: h.target).items.contains { $0.id == "message:full-history" })
            print("FRAME_AUDIT q1 cursor=advanced duplicate=dropped next=delivered reconnects=0 critical=kept autoRefetch=false explicitHistory=restored")
            await h.stop()
        } catch { await h.stop(); throw error }
    }

    @Test func toolPreviewWithoutRawOutputFinishesAndHistoryRestoresFullOutput() async throws {
        let h = try await FullAuditHarness.start(); await h.seed()
        do {
            try await h.chatEvent("tool_call", seq: 6, global: 1, data: ["toolCallId": .string("tool"), "toolName": .string("Bash"), "kind": .string("execute"), "status": .string("in_progress"), "rawInput": .object(["command": .string("cat huge.txt")])])
            let preview = "HEAD α🙂\n[output omitted]\nTAIL Ω"
            let update: [String: AnnexJSON] = ["toolCallId": .string("tool"), "status": .string("completed"), "duration": .integer(123), "truncated": .bool(true), "totalBytes": .integer(20_000_000), "content": .array([.object(["type": .string("terminal"), "output": .string(preview)])])]
            try await h.chatEvent("tool_call_update", seq: 7, global: 2, data: update)
            func tool() -> CompanionTool? { h.store.conversation(for: h.target).items.compactMap { if case .tool(let t) = $0 { t } else { nil } }.first }
            try await h.wait { tool()?.state == .completed }
            #expect(tool()?.output == preview); #expect(tool()?.name == "Bash"); #expect(tool()?.summary == "$ cat huge.txt")
            h.assertCritical()
            let full = "FULL OUTPUT " + String(repeating: "z", count: 10000)
            let fullEvent = LiveServiceHarness.chatEvent("s1", sequence: 7, type: "tool_call_update", data: ["toolCallId": .string("tool"), "toolName": .string("Bash"), "status": .string("completed"), "rawOutput": .string(full)])
            await h.recoverFullHistory(extra: [fullEvent])
            #expect(tool()?.output == full)
            // Append semantics must not be used for a replacement preview.
            try await h.chatEvent("tool_call_update", seq: 8, global: 3, data: ["toolCallId": .string("tool"), "contentMode": .string("append"), "content": .array([.object(["type": .string("text"), "text": .string(preview)])])])
            try await h.wait { tool()?.output == full + preview }
            print("FRAME_AUDIT q2 completed=true rawOutput=absent preview=renderable critical=kept fullHistory=restored appendPreview=duplicates")
            await h.stop()
        } catch { await h.stop(); throw error }
    }

    @Test func shorterPTYAckKeepsScreenCursorAndOutputSequenceWithoutReattach() async throws {
        let h = try await FullAuditHarness.start(); await h.seed()
        let channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
        let session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "Fixture", channel: channel, cols: 40, rows: 4)
        session.start()
        do {
            try await h.wait { await h.io.terminalSends().contains { $0["type"]?.string == "pty:attach" } }
            try await h.frame("pty:data", payload: .object(["agentId": .string("agent"), "data": .string("DUPLICATE"), "outputSeq": .integer(9)]))
            let reduced = "\u{1B}[2J\u{1B}[Hkept-history\r\nSCREEN\u{1B}[2;4H"
            try await h.frame("pty:attach:ack", payload: .object(["agentId": .string("agent"), "buffer": .string(reduced), "outputSeq": .integer(10), "cols": .integer(40), "rows": .integer(4), "truncated": .bool(true), "omittedLines": .integer(9999)]))
            try await h.wait { session.state == .running }
            #expect(session.screen.cursorRow == 1 && session.screen.cursorCol == 3)
            #expect(session.screen.grid[0].map(\.text).joined().hasPrefix("kept-history"))
            #expect(session.screen.grid[1].map(\.text).joined().hasPrefix("SCREEN"))
            try await h.frame("pty:data", payload: .object(["agentId": .string("agent"), "data": .string("!"), "outputSeq": .integer(11)]))
            try await h.wait { session.screen.grid[1][3].text == "!" }
            #expect(session.screen.cursorRow == 1 && session.screen.cursorCol == 4)
            try await Task.sleep(for: .milliseconds(50))
            #expect(await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1)
            #expect(await h.io.opened == 1)
            h.assertCritical(); await h.recoverFullHistory()
            print("FRAME_AUDIT q3 rendered=true cursor=1,4 dedupedEarlyOutput=true attachCount=1 critical=kept chatHistory=available omittedTerminalHistory=noFetchRoute")
            session.close(); await h.stop()
        } catch { session.close(); await h.stop(); throw error }
    }

    @Test func hookAndOuterPermissionInputsAreIgnoredWhileRichCardsUseDescriptionContentRawInput() async throws {
        let h = try await FullAuditHarness.start(); await h.seed()
        do {
            let before = h.store.conversation(for: h.target)
            for (offset, type) in ["hook:event", "permission:request"].enumerated() {
                try await h.frame(type, seq: Int64(offset + 1), payload: .object(["agentId": .string("agent"), "toolInput": .string("64 KiB bounded preview"), "event": .object(["toolInput": .string("nested preview"), "message": .string("bounded message")])]))
            }
            try await h.chatEvent("permission_request", seq: 6, global: 3, data: ["requestId": .string("preview-card"), "toolName": .string("Write"), "title": .string("Write review.txt"), "description": .string("INCOMPLETE: review full input on desktop"), "rawInput": .object(["file_path": .string("/fake/review.txt"), "content": .string(String(repeating: "a", count: 450) + "SECRET TAIL")]), "truncated": .bool(true), "totalBytes": .integer(20_000_000)])
            func card() -> CompanionApproval? { h.store.conversation(for: h.target).items.compactMap { if case .approval(let a) = $0, a.id == "preview-card" { a } else { nil } }.first }
            try await h.wait { card() != nil }
            #expect(card()?.summary == "INCOMPLETE: review full input on desktop")
            #expect(card()?.detail == "review.txt\n" + String(repeating: "a", count: 400))
            let explicit = "INCOMPLETE: review full input on desktop\nHEAD\n[omitted]\nTAIL"
            let event = LiveServiceHarness.chatEvent("s1", sequence: 7, type: "permission_request", data: ["requestId": .string("preview-card"), "toolName": .string("Write"), "description": .string("INCOMPLETE: review full input on desktop"), "content": .array([.object(["type": .string("text"), "text": .string(explicit)])]), "rawInput": .object(["content": .string("unused raw input")])])
            await h.io.setChat(SelfSnapshot.withPending(event))
            await h.store.load(h.target, force: true)
            #expect(card()?.detail == explicit)
            h.assertCritical()
            #expect(h.store.conversation(for: h.target).items.count == before.items.count + 1)
            #expect(await h.io.opened == 1)
            print("FRAME_AUDIT q4 hook+outer=ignored critical=kept richRawInput=first400Characters richContent=fullProvidedText warning=summary HTTPpending=rendered fullHistory=available")
            await h.stop()
        } catch { await h.stop(); throw error }
    }

    @MainActor private enum SelfSnapshot {
        static func withPending(_ event: AnnexJSON) -> AnnexJSON {
            guard case .object(var data) = FullAuditHarness.criticalSnapshot() else { fatalError() }
            data["pendingPermissions"] = .array(data["pendingPermissions"].arrayValue + [event]); return .object(data)
        }
    }

    @Test func canvasOmissionAndUnknownTruncationMarkerPreserveCriticalStateButEmptyIconMapsClearImages() async throws {
        let h = try await FullAuditHarness.start(); await h.seed()
        do {
            let url = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
            for shape in ["seed", "omitCanvasesKeepIcons", "clearIcons"] {
                var payload = try AuditIO.fullPayload(name: shape)
                payload["agents"] = .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("waiting_input"), "icon": .string("agent.png")])])])
                payload["agentIcons"] = shape == "clearIcons" ? .object([:]) : .object(["agent": .string(url)])
                payload["projectIcons"] = shape == "clearIcons" ? .object([:]) : .object(["project": .string(url)])
                if shape == "seed" { payload["canvasState"] = .object(["notes": .array([.string("canvas text")])]); payload["appCanvasState"] = .object(["notes": .array([.string("app canvas text")])]) }
                else { payload["snapshotTruncated"] = .object(["version": .integer(1), "reason": .string("frame_limit"), "omitted": .array([.string("canvasState"), .string("appCanvasState")]), "bytes": .integer(9_000_000)]) }
                await h.io.setProjectName(shape)
                try await h.frame("snapshot", payload: .object(payload))
                try await h.wait { h.host?.projects.first?.name == shape && h.host?.connection == .connected }
                #expect((h.host?.projects.first?.iconData != nil) == (shape != "clearIcons"))
                #expect((h.store.agent(for: h.target)?.iconData != nil) == (shape != "clearIcons"))
                h.assertCritical()
                #expect(h.host?.connection == .connected)
            }
            await h.recoverFullHistory()
            print("FRAME_AUDIT q6 marker=ignored omittedCanvases=noGoCanvasModel mapsKept=imagesKept explicitEmptyMaps=bothImagesCleared critical=kept fullHistory=available")
            await h.stop()
        } catch { await h.stop(); throw error }
    }
}
#if os(macOS)
@MainActor private final class FrameHTTPPeer {
    let process: Process
    let io: PinnedAnnexIO
    let port: UInt16
    let root: URL
    init() throws {
        let source = URL(fileURLWithPath: #filePath)
        let top = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = top.appendingPathComponent("frame-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let full = LiveServiceHarness.chatEvent("s1", sequence: 6, type: "tool_call_update", data: ["toolCallId": .string("full-history-tool"), "status": .string("completed"), "rawOutput": .string("FULL OLD OUTPUT")])
        let giant = LiveServiceHarness.chatEvent("s1", sequence: 6, type: "tool_call_update", data: ["toolCallId": .string("giant"), "status": .string("completed"), "rawOutput": .string(String(repeating: "z", count: 16 * 1024 * 1024))])
        var recent = FullAuditHarness.criticalSnapshot(extra: [LiveServiceHarness.chatEvent("s1", sequence: 1000, type: "agent_message", data: ["messageId": .string("recent"), "text": .string("Latest bounded page")])])
        if case .object(var fields) = recent { fields["truncated"] = .bool(true); fields["nextBeforeSeq"] = .integer(900); recent = .object(fields) }
        let values = ["small": FullAuditHarness.criticalSnapshot(extra: [full]), "large": FullAuditHarness.criticalSnapshot(extra: [giant]), "recent": recent, "older": LiveServiceHarness.chatSnapshot(events: [full], fields: ["nextBeforeSeq": .null])]
        for (name, value) in values { try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name + ".json")) }
        try JSONEncoder().encode(AnnexJSON.object(["type": .string("snapshot"), "epoch": .string("epoch"), "payload": .object(try AuditIO.fullPayload())])).write(to: root.appendingPathComponent("snapshot.json"))
        for name in ["pty-full.json", "pty-short.json", "pty-empty.json", "http-raw-buffer.txt"] {
            let file = top.appendingPathComponent("frame-2682-frames").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: file) }
        }
        let pipe = Pipe(); process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", top.deletingLastPathComponent().appendingPathComponent("Tests/Compatibility/frame-http-peer.mjs").path, root.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte); guard line.count < 4096 else { throw URLError(.badServerResponse) } }
        struct Handshake: Decodable { let port: UInt16; let pin: String }
        let fixture = try JSONDecoder().decode(Handshake.self, from: line); port = fixture.port
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: port), verifiedHostID: LiveServiceHarness.hostID, verifiedCertificatePin: AnnexCertificatePin(sha256: fixture.pin))
        io = PinnedAnnexIO(host: host) // Actual default16MiB limit, not a fake error.
    }
    func control(_ mode: String, framing: String = "length") async throws {
        _ = try await io.perform(URLRequest(url: URL(string: "https://127.0.0.1:\(port)/control?mode=\(mode)&framing=\(framing)")!))
    }
    func metrics() async throws -> AnnexJSON {
        let response = try await io.perform(URLRequest(url: URL(string: "https://127.0.0.1:\(port)/metrics")!))
        return try JSONDecoder().decode(AnnexJSON.self, from: response.data)
    }
    func stop() { if process.isRunning { process.terminate() }; process.waitUntilExit(); try? FileManager.default.removeItem(at: root) }
}

extension FrameWireAuditTests {
    @Test func realPinnedHTTPOver16MiBHasManualRecoveryAndArchiveNeedsBoundedPages() async throws {
        let h = try await FullAuditHarness.start(); await h.seed()
        let peer = try FrameHTTPPeer()
        do {
            await h.io.setChatProxy(peer.io, port: peer.port)
            for framing in ["length", "chunked"] {
                try await peer.control("oversized", framing: framing)
                await #expect(throws: AnnexTransportError.responseTooLarge) {
                    try await peer.io.perform(URLRequest(url: URL(string: "https://127.0.0.1:\(peer.port)/api/v1/mobile/agents/agent/chat")!))
                }
                await h.store.load(h.target, force: true)
                #expect(h.store.conversation(for: h.target).error != nil)
                #expect(h.store.conversation(for: h.target).requiresResync)
                #expect(!h.store.conversation(for: h.target).isLoading)
                h.assertCritical()
                let reads = await h.io.chatReads
                try await Task.sleep(for: .milliseconds(50))
                #expect(await h.io.chatReads == reads)
                #expect(h.host?.connection == .connected)
                print("FRAME_AUDIT q5 framing=\(framing) error=\(h.store.conversation(for: h.target).error ?? "none") critical=kept autoRetry=false websocket=connected")
            }
            let archive = CompanionArchiveTranscript(reader: try h.service.archive(for: h.target, sessionID: "s1"))
            await archive.loadEarlier()
            #expect(archive.error != nil && !archive.isLoaded && archive.nextBeforeSequence == nil)
            let failedReads = await h.io.chatReads
            try await Task.sleep(for: .milliseconds(50))
            #expect(await h.io.chatReads == failedReads)
            try await peer.control("small")
            await h.store.load(h.target, force: true)
            #expect(h.store.conversation(for: h.target).error == nil)
            h.assertCritical()
            await archive.loadEarlier()
            #expect(archive.error == nil && archive.isLoaded)
            #expect(archive.items.contains { if case .tool(let t) = $0 { t.output == "FULL OLD OUTPUT" } else { false } })
            let paging = CompanionArchiveTranscript(reader: try h.service.archive(for: h.target, sessionID: "s1"))
            try await peer.control("poison")
            await paging.loadEarlier()
            #expect(paging.nextBeforeSequence == 900)
            let items = paging.items
            await paging.loadEarlier()
            #expect(paging.error != nil && paging.nextBeforeSequence == 900 && paging.items == items)
            await paging.loadEarlier()
            #expect(paging.error != nil && paging.nextBeforeSequence == 900)
            try await peer.control("paged")
            await paging.loadEarlier()
            #expect(paging.error == nil && paging.nextBeforeSequence == nil)
            #expect(paging.items.contains { if case .tool(let t) = $0 { t.output == "FULL OLD OUTPUT" } else { false } })
            h.assertCritical()
            #expect(await h.io.chatQueries.contains { $0.contains("beforeSeq=900") && $0.contains("limit=300") })
            #expect(await h.io.opened == 1)
            print("FRAME_AUDIT q5 samePoisonPage=manualFailureAgain cursor=900+retained noAutoLoop=true smallerPage=recovers olderFullOutput=restored critical=kept")
            peer.stop(); await h.stop()
        } catch { peer.stop(); await h.stop(); throw error }
    }
}
#endif

extension FrameWireAuditTests {
    @Test func actual2682SerializerAndEmptyFallbackThroughGoTerminal() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("frame-2682-frames")
        let expected = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent("pty-expected.json")))
        for kind in ["short", "empty"] {
            let h = try await FullAuditHarness.start(); await h.seed()
            let channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
            let session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "Captured2682", channel: channel, cols: 40, rows: 4)
            session.start()
            do {
                try await h.wait { await h.io.terminalSends().contains { $0["type"]?.string == "pty:attach" } }
                let seq = try #require(expected["outputSeq"]?.integer)
                try await h.frame("pty:data", payload: .object(["agentId": .string("agent"), "data": .string("DUPLICATE"), "outputSeq": .integer(seq)]))
                let frame = try Data(contentsOf: root.appendingPathComponent("pty-\(kind).json"))
                #expect(frame.count <= 8 * 1024 * 1024)
                await h.io.push(frame)
                try await h.wait { session.state == .running }
                func screen() -> [String] { session.screen.grid.map { row in row.map(\.text).joined().replacingOccurrences(of: " +$", with: "", options: .regularExpression) } }
                if kind == "short" {
                    #expect(screen() == expected["expected"]?["screen"].arrayValue.compactMap(\.string))
                    #expect(session.screen.cursorCol == expected["expected"]?["cursorX"]?.int)
                    #expect(session.screen.cursorRow == expected["expected"]?["cursorY"]?.int)
                    #expect(session.screen.applicationCursorKeys)
                    #expect(session.screen.bracketedPaste)
                    let visible = session.screen.cursorVisible
                    #expect(visible, "Both full and limited xterm captures omit hidden-cursor state")
                } else {
                    #expect(screen().allSatisfy { $0.isEmpty })
                    #expect(session.screen.cursorCol == 0 && session.screen.cursorRow == 0)
                    #expect(!session.screen.applicationCursorKeys && !session.screen.bracketedPaste && session.screen.cursorVisible)
                    #expect(!session.screen.plainText().contains("omitted"), "147 gives no omission warning")
                }
                try await h.frame("pty:data", payload: .object(["agentId": .string("agent"), "data": .string("Z"), "outputSeq": .integer(seq + 1)]))
                try await h.wait { session.screen.plainText().contains("Z") }
                if kind == "short" {
                    #expect(screen() == expected["after"]?["screen"].arrayValue.compactMap(\.string))
                    #expect(session.screen.cursorCol == expected["after"]?["cursorX"]?.int)
                    #expect(session.screen.cursorRow == expected["after"]?["cursorY"]?.int)
                } else {
                    #expect(session.screen.grid[0][0].text == "Z")
                    #expect(session.screen.cursorCol == 1 && session.screen.cursorRow == 0)
                    #expect(screen() != expected["after"]?["screen"].arrayValue.compactMap(\.string), "Transport continuity is not restored terminal state")
                }
                try await Task.sleep(for: .milliseconds(50))
                #expect(await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1)
                #expect(await h.io.opened == 1)
                h.assertCritical()
                try await h.chatEvent("agent_message", seq: 6, global: 1, data: ["messageId": .string("after-captured-pty"), "text": .string("global cursor intact")])
                try await h.wait { h.store.conversation(for: h.target).items.contains { $0.id == "message:after-captured-pty" } }
                await h.recoverFullHistory()
                print("FRAME_2682 case=\(kind) sha=265b3dfefd6a45d837e095750c6e689d822384f7 bytes=\(frame.count) state=running cursor=\(session.screen.cursorRow),\(session.screen.cursorCol) appCursor=\(session.screen.applicationCursorKeys) bracketedPaste=\(session.screen.bracketedPaste) visibleCursor=\(session.screen.cursorVisible) attachCount=1 reconnects=0 critical=kept fullChatHistory=available")
                session.close(); await h.stop()
            } catch { session.close(); await h.stop(); throw error }
        }
    }
}
#if os(macOS)
extension FrameWireAuditTests {
    @Test func actualOversizedAttachRepeatsAfterReconnect() async throws {
        let peer = try FrameHTTPPeer(); try await peer.control("pty-full")
        let h = try await FullAuditHarness.start(wireProxy: (peer.io, peer.port)); await h.seed()
        let channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
        let session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "Poison attach", channel: channel)
        session.start()
        do {
            for cycle in 1...3 {
                try await h.wait(tries: 5000) { (try? await peer.metrics()["attaches"]?.int) ?? 0 >= cycle && session.state == .reconnecting }
                #expect(h.store.conversation(for: h.target).items.contains { $0.id == "approval:critical-permission" })
                #expect(h.store.conversation(for: h.target).items.contains { $0.id == "question:critical-question" })
                #expect(h.store.conversation(for: h.target).items.contains { $0.id == "message:critical-queued" })
                print("FRAME_2682 oversizedCycle=\(cycle) terminal=\(session.state) host=\(String(describing: h.host?.connection)) wsOpens=\(await h.io.opened) requiresResync=\(h.store.conversation(for: h.target).requiresResync) retrySleeps=\(h.sleeps.values)")
                if cycle < 3 { for _ in 0..<100 { if h.manual.sleeperCount >= 1 { break }; try await Task.sleep(for: .milliseconds(2)) }; await h.manual.advance(by: .seconds(60)) }
            }
            let metrics = try await peer.metrics()
            #expect(metrics["attaches"]?.int ?? 0 >= 3)
            #expect(await h.io.opened >= 3)
            await h.recoverFullHistory()
            session.close(); await h.stop(); peer.stop()
        } catch { session.close(); await h.stop(); peer.stop(); throw error }
    }
}
#endif
#if os(macOS)
extension FrameWireAuditTests {
    @Test func actual2682RawBufferHTTPFallbackStillExceedsClientCap() async throws {
        let peer = try FrameHTTPPeer()
        defer { peer.stop() }
        // Body captured by invoking the actual pinned source handler with raw fallback.
        let bytes = try Data(contentsOf: peer.root.appendingPathComponent("http-raw-buffer.txt"))
        #expect(bytes.count == 19_210_093 && bytes.count > 16 * 1024 * 1024)
        await #expect(throws: AnnexTransportError.responseTooLarge) {
            try await peer.io.perform(URLRequest(url: URL(string: "https://127.0.0.1:\(peer.port)/api/v1/agents/agent/buffer")!))
        }
        print("FRAME_2682 rawHTTPFallbackBytes=\(bytes.count) realPinnedHTTP=responseTooLarge handler=actualSource manager=rawFallbackStub")
    }
}
#endif

extension FrameWireAuditTests {
    @Test func proposedTerminalUnavailableErrorWorksWithoutAck() async throws {
        try await verifyTerminalUnavailableError(captured: nil)
    }
    private func verifyTerminalUnavailableError(captured: Data?) async throws {
        let h = try await FullAuditHarness.start(); await h.seed()
        try await h.chatEvent("session_state", seq: 6, global: 1, data: ["state": .string("running")])
        try await h.wait { h.store.agent(for: h.target)?.status == .working }
        let channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
        let session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "Unavailable", channel: channel, cols: 40, rows: 4)
        session.start()
        do {
            try await h.wait { await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1 }
            #expect(session.state == .connecting)
            // Exact proposed sendPtyError shape, no ack before or after it.
            if let captured { await h.io.push(captured) }
            else { try await h.frame("error", payload: .object(["message": .string("terminal_unavailable"), "op": .string("pty:attach"), "agentId": .string("agent")])) }
            let wording = "The desktop couldn't start a shell: terminal_unavailable"
            try await h.wait { session.state == .failed(wording) }
            h.assertCritical(status: .working)
            #expect(h.store.agent(for: h.target)?.isRunning == true)
            #expect(h.host?.connection == .connected)
            #expect(!h.store.conversation(for: h.target).requiresResync)
            await h.manual.advance(by: .seconds(120))
            try await Task.sleep(for: .milliseconds(50))
            #expect(session.state == .failed(wording))
            #expect(await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1)
            #expect(await h.io.opened == 1)
            session.restart() // The failed terminal's actual Try again action.
            try await h.wait { await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 2 }
            try await h.frame("pty:attach:ack", payload: .object(["agentId": .string("agent"), "buffer": .string("restored"), "outputSeq": .integer(10), "cols": .integer(40), "rows": .integer(4)]))
            try await h.wait { session.state == .running && session.screen.plainText() == "restored" }
            try await h.frame("pty:data", payload: .object(["agentId": .string("agent"), "data": .string("!"), "outputSeq": .integer(11)]))
            try await h.wait { session.screen.plainText() == "restored!" }
            h.assertCritical(status: .working)
            await h.recoverFullHistory(status: .working)
            print("FRAME_FAILURE terminal_unavailable=noAckNeeded wording=\(wording) agent=working critical=kept autoRetry=false manualRetry=oneAttach recovery=rendered+orderedOutput")
            session.close(); await h.stop()
        } catch { session.close(); await h.stop(); throw error }
    }
}

extension FrameWireAuditTests {
    @Test func focusedTerminalFailureShapesAndManualRecovery() async throws {
        for candidate in ["ackError", "ptyExit", "internalError", "missingOp", "missingAgent"] {
            let h = try await FullAuditHarness.start(); await h.seed()
            try await h.chatEvent("session_state", seq: 6, global: 1, data: ["state": .string("running")])
            try await h.wait { h.store.agent(for: h.target)?.status == .working }
            var channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
            var session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "Candidate", channel: channel, cols: 40, rows: 4)
            session.start()
            do {
                try await h.wait { await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1 }
                let expected: CompanionTerminalSession.State
                let display: String
                switch candidate {
                case "ackError":
                    expected = .running; display = "blank terminal; error ignored; no retry control"
                    try await h.frame("pty:attach:ack", payload: .object(["agentId": .string("agent"), "error": .string("terminal_unavailable")]))
                case "ptyExit":
                    expected = .exited(code: 1); display = "Exited with code 1.; Reattach"
                    try await h.frame("pty:exit", payload: .object(["agentId": .string("agent"), "exitCode": .integer(1)]))
                case "internalError":
                    let message = "The desktop couldn't open this terminal. Try again."
                    expected = .failed(message); display = message + "; Try again"
                    try await h.frame("error", payload: .object(["agentId": .string("agent"), "op": .string("pty:attach"), "message": .string("internal_error")]))
                case "missingOp":
                    expected = .connecting; display = "Connecting forever; no retry control"
                    try await h.frame("error", payload: .object(["agentId": .string("agent"), "message": .string("terminal_unavailable")]))
                default:
                    expected = .connecting; display = "Connecting forever; no retry control"
                    try await h.frame("error", payload: .object(["op": .string("pty:attach"), "message": .string("terminal_unavailable")]))
                }
                if candidate == "missingOp" || candidate == "missingAgent" { try await Task.sleep(for: .milliseconds(30)) }
                else { try await h.wait { session.state == expected } }
                await h.manual.advance(by: .seconds(120))
                try await Task.sleep(for: .milliseconds(30))
                #expect(session.state == expected)
                #expect(await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1)
                #expect(await h.io.opened == 1)
                h.assertCritical(status: .working)
                #expect(h.store.agent(for: h.target)?.isRunning == true)
                #expect(h.host?.connection == .connected)
                #expect(!h.store.conversation(for: h.target).requiresResync)
                if candidate == "internalError" || candidate == "ptyExit" {
                    session.restart()
                } else {
                    if candidate == "ackError" {
                        session.restart() // Running is guarded; connecting has no offered retry UI.
                        try await Task.sleep(for: .milliseconds(20))
                        #expect(await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1)
                    }
                    session.close(); await channel.close()
                    channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
                    session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "Reopened", channel: channel, cols: 40, rows: 4)
                    session.start()
                }
                try await h.wait { await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 2 }
                try await h.frame("pty:attach:ack", payload: .object(["agentId": .string("agent"), "buffer": .string("recovered"), "outputSeq": .integer(100), "cols": .integer(40), "rows": .integer(4)]))
                try await h.wait { session.state == .running && session.screen.plainText() == "recovered" }
                try await h.frame("pty:data", payload: .object(["agentId": .string("agent"), "data": .string("!"), "outputSeq": .integer(101)]))
                try await h.wait { session.screen.plainText() == "recovered!" }
                h.assertCritical(status: .working); await h.recoverFullHistory(status: .working)
                print("FRAME_FAILURE candidate=\(candidate) display=\(display) loops=0 agent=working critical=kept recovery=\(candidate == "internalError" || candidate == "ptyExit" ? "retryButton" : "closeAndReopen")+validAck+orderedOutput")
                session.close(); await h.stop()
            } catch { session.close(); await h.stop(); throw error }
        }
    }
}

extension FrameWireAuditTests {
    @Test func rawReplayAtFinal2682FitsAndPreservesOnlyStatePresentInRetainedRaw() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("frame-2682-raw")
        let metadata = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent("raw-expected.json")))
        #expect(metadata["sha"]?.string == "ae2cf9b7d95ed2ae4229221d4be37320686f960a")
        for row in metadata["cases"].arrayValue {
            let kind = try #require(row["kind"]?.string)
            let h = try await FullAuditHarness.start(); await h.seed()
            let channel = CompanionLiveTerminalChannel(transport: h.transport, scope: .agentPTY(h.target))
            let session = CompanionTerminalSession(scope: .agentPTY(h.target), title: "Raw2682", channel: channel, cols: 40, rows: 4)
            session.start()
            do {
                try await h.wait { await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1 }
                let data = try Data(contentsOf: root.appendingPathComponent("raw-\(kind).json"))
                let decoded = try JSONDecoder().decode(AnnexEnvelope.self, from: data)
                #expect(decoded.payload?["bufferOmitted"] == nil)
                #expect(decoded.payload?["buffer"]?.string?.isEmpty == false)
                #expect(data.count <= 8 * 1024 * 1024)
                await h.io.push(data)
                try await h.wait { session.state == .running }
                func lines() -> [String] { session.screen.grid.map { $0.map(\.text).joined().replacingOccurrences(of: " +$", with: "", options: .regularExpression) } }
                let visible = lines(), cursorRow = session.screen.cursorRow, cursorCol = session.screen.cursorCol
                let app = session.screen.applicationCursorKeys, paste = session.screen.bracketedPaste
                #expect(visible == row["live"]?["screen"].arrayValue.compactMap(\.string))
                #expect(cursorRow == row["live"]?["cursorY"]?.int && cursorCol == row["live"]?["cursorX"]?.int)
                #expect(row["expected"]?["appCursor"] == .bool(app))
                #expect(row["expected"]?["bracketedPaste"] == .bool(paste))
                if kind == "missingModes" {
                    #expect(!app && !paste)
                    #expect(row["live"]?["appCursor"] == .bool(true) && row["live"]?["bracketedPaste"] == .bool(true))
                } else { #expect(app && paste) }
                if kind == "screenOnly" {
                    let scrollback = session.screen.scrollback.count
                    #expect(scrollback == 0 && row["scrollbackLines"]?.int == 0)
                    #expect(row["encodedBudget"]?.int == 512, "Explicit reduced test budget forces the actual screen-only branch")
                }
                let seq = try #require(row["outputSeq"]?.integer)
                try await h.frame("pty:data", payload: .object(["agentId": .string("agent"), "data": .string("Z"), "outputSeq": .integer(seq + 1)]))
                try await h.wait { session.screen.cursorCol == row["after"]?["cursorX"]?.int }
                let after = lines(), finalRow = session.screen.cursorRow, finalCol = session.screen.cursorCol
                #expect(after == row["after"]?["screen"].arrayValue.compactMap(\.string))
                #expect(finalRow == row["after"]?["cursorY"]?.int && finalCol == row["after"]?["cursorX"]?.int)
                try await Task.sleep(for: .milliseconds(30))
                #expect(await h.io.terminalSends().filter { $0["type"]?.string == "pty:attach" }.count == 1)
                #expect(await h.io.opened == 1)
                h.assertCritical(); await h.recoverFullHistory()
                print("FRAME_RAW_FINAL sha=ae2cf9b7d95ed2ae4229221d4be37320686f960a case=\(kind) bytes=\(data.count) budget=\(row["encodedBudget"]?.int ?? 0) rawBytes=\(row["rawBytes"]?.int ?? 0) cursor=\(finalRow),\(finalCol) appCursor=\(app) paste=\(paste) nativeScrollback=\(session.screen.scrollback.count) attach=1 reconnects=0 critical=kept")
                session.close(); await h.stop()
            } catch { session.close(); await h.stop(); throw error }
        }
    }
}

extension FrameWireAuditTests {
    @Test func final2682CapturedFailureFramesMatchProposalAndRecover() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("frame-2682-raw")
        let metadata = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent("raw-expected.json")))
        #expect(metadata["sha"]?.string == "ae2cf9b7d95ed2ae4229221d4be37320686f960a")
        for source in ["unfit", "lastResort"] {
            let captured = try Data(contentsOf: root.appendingPathComponent("failure-\(source).json"))
            let value = try JSONDecoder().decode(AnnexJSON.self, from: captured)
            #expect(value == .object(["type": .string("error"), "payload": .object(["message": .string("terminal_unavailable"), "op": .string("pty:attach"), "agentId": .string("agent")])]))
            try await verifyTerminalUnavailableError(captured: captured)
            print("FRAME_FINAL_FAILURE sha=ae2cf9b7d95ed2ae4229221d4be37320686f960a source=\(source) bytes=\(captured.count) proposal=exact failedWithoutAck=true recoveredAfterManualRetry=true")
        }
    }
}

@MainActor private extension FrameWireAuditTests {
    func permissionCapture(_ name: String) throws -> AnnexJSON {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("frame-2686")
        return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    func fixturePage(_ pending: [AnnexJSON], extra: [AnnexJSON] = []) -> AnnexJSON {
        let question = LiveServiceHarness.chatEvent("sess_live", sequence: 3, type: "question", data: ["requestId": .string("kept-question"), "questions": .array([.object(["id": .string("q"), "prompt": .string("Which?"), "allowFreeText": .bool(true)])])])
        let queued = LiveServiceHarness.chatEvent("sess_live", sequence: 4, type: "user_message", data: ["messageId": .string("kept-queued"), "text": .string("queued"), "delivery": .string("queued")])
        let queue = LiveServiceHarness.chatEvent("sess_live", sequence: 5, type: "queue_state", data: ["queuedMessageIds": .array([.string("kept-queued")])])
        return LiveServiceHarness.chatSnapshot(session: "sess_live", events: [queued, queue] + extra, fields: ["state": .string("waiting_permission"), "pendingPermissions": .array(pending), "pendingQuestions": .array([question]), "queuedMessageIds": .array([.string("kept-queued")]), "queueStateSeq": .integer(5), "capabilities": .object(["chat": .bool(true), "questions": .bool(true), "queue": .string("client")])])
    }
    func fixtureApproval(_ h: FullAuditHarness, id: String = "perm_1") -> CompanionApproval? {
        h.store.conversation(for: h.target).items.compactMap { if case .approval(let a) = $0, a.id == id { a } else { nil } }.first
    }
    func fixtureCritical(_ h: FullAuditHarness, cursor: Int) {
        let c = h.store.conversation(for: h.target)
        #expect(c.sessionID == "sess_live"); #expect(c.lastSequence == cursor)
        #expect(c.items.contains { if case .question(let q) = $0 { q.id == "kept-question" && q.resolution == .pending } else { false } })
        #expect(c.items.contains { if case .message(let m) = $0 { m.id == "kept-queued" && m.queueState == .queued } else { false } })
        #expect(h.store.agent(for: h.target)?.status == .approval)
        #expect(h.host?.connection == .connected)
    }
}

@MainActor extension FrameWireAuditTests {
    @Test func final2686RealPermissionFixtureBothRoutesAndPersistentOptions() async throws {
        let fixture = try permissionCapture("permission-fixture.json"), pending = try #require(fixture["pendingPermission"])
        let warning = "Incomplete input: this request is too large to show in full here. Review it on the desktop to approve it. You can still deny it here."
        let refusal = "This request is too large to review here. Review it on the desktop to approve it, or deny it here."
        for live in [false, true] { for persistent in [false, true] {
            let h = try await FullAuditHarness.start(agentID: "durable_chat", persistent: persistent)
            do {
                await h.io.setReceipts(["allow": fixture["approve"]!["response"]!, "always": fixture["approve"]!["response"]!, "deny": fixture["deny"]!])
                await h.io.setChat(fixturePage(live ? [] : [pending])); await h.store.load(h.target, force: true)
                if live { try await h.frame("chat:event", seq: 1, payload: .object(["agentId": .string("durable_chat"), "event": pending])); try await h.wait { fixtureApproval(h) != nil } }
                var a = try #require(fixtureApproval(h)); #expect(a.title == "Write big.ts"); #expect(a.toolName == "Write")
                #expect(a.summary.hasPrefix(warning)); #expect(a.detail?.hasPrefix(warning) == true)
                #expect(a.detail?.contains("big.ts") == true)
                #expect(a.options.map(\.id) == ["allow", "always", "deny"]); #expect(a.options.map(\.label) == ["Allow", "Always allow", "Deny"])
                #expect(a.options[1].scope == "npm test:*"); #expect(a.options[1].needsConfirmation)
                fixtureCritical(h, cursor: 8)
                let before = await h.io.commands
                await h.store.respond(a, option: a.options[0], target: h.target)
                #expect(fixtureApproval(h)?.resolution == .pending); #expect(h.store.operationErrors[h.target] == refusal)
                #expect(await h.io.commands == before + 1)
                a = try #require(fixtureApproval(h)); await h.store.respond(a, option: a.options[1], target: h.target)
                #expect(await h.io.commands == before + (persistent ? 2 : 1)); #expect(fixtureApproval(h)?.resolution == .pending)
                if persistent { #expect(h.store.operationErrors[h.target] == refusal) }
                a = try #require(fixtureApproval(h)); await h.store.respond(a, option: a.options[2], target: h.target)
                #expect(fixtureApproval(h)?.resolution == .denied); #expect(h.store.operationErrors[h.target] == nil)
                fixtureCritical(h, cursor: 8)
                let commands = await h.io.recordedCommands
                #expect(commands.last?["optionId"]?.string == "deny")
                #expect(commands.allSatisfy { $0["options"] == nil && $0["label"] == nil })
                #expect(await h.io.opened == 1)
                print("PERMISSION_FIXTURE route=\(live ? "live" : "HTTP") persistent=\(persistent) warning=immediate allow=409 pending=true always=\(persistent ? "409" : "desktopOnly") deny=settled critical=kept")
                await h.stop()
            } catch { await h.stop(); throw error }
        } }
    }

    @Test func final2686ActualCommandReceiptsSmallMismatchRestartAndPreview() async throws {
        let captured = try permissionCapture("commands.json")
        #expect(captured["sha"]?.string == "1a684c1cef0d1b7ca7b3da6dff04ceccab500d2a")
        let deny = try #require(try permissionCapture("permission-fixture.json")["deny"])
        var emitted: [AnnexJSON] = []
        for c in captured["cases"].arrayValue where c["optionId"]?.string != "deny" {
            let h = try await FullAuditHarness.start(agentID: "durable_chat", persistent: true)
            do {
                let event = try #require(c["event"]), optionID = c["optionId"]?.string ?? "allow"
                await h.io.setChat(fixturePage([event])); await h.store.load(h.target, force: true)
                await h.io.setReceipts([optionID: c, "deny": deny])
                var a = try #require(fixtureApproval(h)); let option = try #require(a.options.first { $0.id == optionID })
                await h.store.respond(a, option: option, target: h.target)
                let rejected = c["status"]?.integer == 409
                #expect(fixtureApproval(h)?.resolution == (rejected ? .pending : .allowed))
                let sent = try #require(await h.io.recordedCommands.last)
                #expect(sent["type"]?.string == "chat.permission"); #expect(sent["requestId"]?.string == "perm_1"); #expect(sent["optionId"]?.string == optionID)
                #expect(sent["options"] == nil); #expect(sent["label"] == nil)
                emitted.append(.object(["name": c["name"]!, "command": sent]))
                if rejected {
                    #expect(h.store.operationErrors[h.target] == c["body"]?["error"]?["message"]?.string)
                    a = try #require(fixtureApproval(h)); let reject = try #require(a.options.first { $0.id == "deny" })
                    await h.store.respond(a, option: reject, target: h.target)
                    #expect(fixtureApproval(h)?.resolution == .denied)
                }
                print("PERMISSION_COMMAND actualCH=true case=\(c["name"]?.string ?? "") status=\(c["status"]?.integer ?? 0) optionId=unaltered labels=notSent rejectedRemainsDeniable=\(rejected)")
                await h.stop()
            } catch { await h.stop(); throw error }
        }
        let archive = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try JSONEncoder().encode(AnnexJSON.array(emitted)).write(to: archive.deletingLastPathComponent().appendingPathComponent("frame-2686/go-commands-" + archive.lastPathComponent + ".json"), options: .atomic)
    }

    @Test func final2686RealToolPreviewFixtureAndSyntheticNoticeOptions() async throws {
        let fixture = try permissionCapture("tool-fixture.json"), frame = try #require(fixture["frame"])
        let h = try await FullAuditHarness.start(agentID: "durable_chat", initialSequence: 999)
        do {
            await h.io.setChat(fixturePage([])); await h.store.load(h.target, force: true)
            await h.io.push(try JSONEncoder().encode(frame))
            func tool() -> CompanionTool? { h.store.conversation(for: h.target).items.compactMap { if case .tool(let t) = $0 { t } else { nil } }.first }
            try await h.wait { tool()?.id == "call_write" }
            #expect(tool()?.name == "Write big.ts"); #expect(tool()?.summary == "big.ts"); #expect(tool()?.kind == .edit)
            #expect(tool()?.awaitsApproval == true)
            #expect(h.store.conversation(for: h.target).lastSequence == 101)
            #expect(await h.io.opened == 1)
            // Unbuilt overflow proposal: summary has no 400-character limit; rawInput content does.
            let warning = "Incomplete input: this request is too large to show in full here. Review it on the desktop to approve it. You can still deny it here."
            let note = "3 additional requests are pending; use Refresh conversation or review them on desktop."
            var options: [AnnexJSON] = (0..<15).map { .object(["optionId": .string("allow-\($0)"), "label": .string(String(repeating: "L", count: 256)), "kind": .string("allow_once"), "scope": .string(String(repeating: "S", count: 256))]) }
            options.append(.object(["optionId": .string("deny-kept"), "label": .string("Deny"), "kind": .string("reject_once")]))
            let p = LiveServiceHarness.chatEvent("sess_live", sequence: 102, type: "permission_request", data: ["requestId": .string("synthetic"), "title": .string("Write big.ts"), "toolName": .string("Write"), "description": .string(warning + " " + String(repeating: "context ", count: 60) + note), "rawInput": .object(["file_path": .string("/work/app/big.ts"), "content": .string(String(repeating: "x", count: 500))]), "options": .array(options)])
            await h.io.setChat(fixturePage([p])); await h.store.load(h.target, force: true)
            let a = try #require(fixtureApproval(h, id: "synthetic")); #expect(a.summary.hasPrefix(warning)); #expect(a.summary.hasSuffix(note)); #expect(a.summary.count > 400)
            #expect(a.detail == "big.ts\n" + String(repeating: "x", count: 400)); #expect(a.options.count == 16); #expect(a.options[0].label.utf8.count == 256); #expect(a.options[0].scope?.utf8.count == 256)
            #expect(a.options.last?.id == "deny-kept"); await h.store.respond(a, option: a.options[15], target: h.target)
            #expect(fixtureApproval(h, id: "synthetic")?.resolution == .denied)
            #expect(await h.io.recordedCommands.last?["optionId"]?.string == "deny-kept")
            print("TOOL_FIXTURE actual=true id=kept kind=edit pendingApproval=true smallRaw=big.ts notice=summaryUnclipped rawBody=400chars proposalOptions=16 denyID=kept")
            await h.stop()
        } catch { await h.stop(); throw error }
    }
}

@MainActor extension FrameWireAuditTests {
    @Test func proposedAllRowsOr503CachedAndColdRecovery() async throws {
        let failure: AnnexJSON = .object(["error": .string("pending_overflow"), "pendingCount": .integer(9999), "message": .string("9999 requests are pending, too many to show here. Review them on the desktop.")])
        let expected = "Desktop request failed (503): pending_overflow."
        let h = try await FullAuditHarness.start(); await h.seed()
        let items = h.store.conversation(for: h.target).items, cursor = h.store.conversation(for: h.target).lastSequence
        await h.io.setChatResponse(failure, status: 503); await h.store.load(h.target, force: true)
        #expect(h.store.conversation(for: h.target).items == items); #expect(h.store.conversation(for: h.target).lastSequence == cursor)
        #expect(h.store.conversation(for: h.target).error == expected); #expect(!h.store.conversation(for: h.target).isLoading); #expect(h.store.conversation(for: h.target).requiresResync)
        h.assertCritical(); #expect(await h.io.opened == 1)
        #expect(!h.store.canOperate(h.target)); #expect(!h.store.canSend(h.target))
        let reads = await h.io.chatReads; try await Task.sleep(for: .milliseconds(100)); #expect(await h.io.chatReads == reads)
        await h.io.setChat(FullAuditHarness.criticalSnapshot()); await h.store.load(h.target, force: true)
        #expect(h.store.conversation(for: h.target).error == nil); #expect(!h.store.conversation(for: h.target).requiresResync); h.assertCritical(); #expect(h.store.canOperate(h.target))
        await h.stop()
        let cold = try await FullAuditHarness.start(chatOverride: failure, chatStatus: 503)
        #expect(cold.store.conversation(for: cold.target).items.isEmpty); #expect(cold.store.conversation(for: cold.target).error == expected)
        #expect(!cold.store.conversation(for: cold.target).isLoading); #expect(!cold.store.conversation(for: cold.target).isLoaded)
        await cold.io.setChat(FullAuditHarness.criticalSnapshot()); await cold.store.load(cold.target, force: true)
        cold.assertCritical(); #expect(cold.store.conversation(for: cold.target).error == nil)
        print("PENDING503 synthetic=true visible=\(expected) cached=retained cursor=retained autoRetry=false cold=explicitFailure retry=recovered serverMessage=ignored")
        await cold.stop()
    }

    @Test func proposedMinimalDenyOnlyZeroOptionsAndDuplicateTail() async throws {
        let warning = "Incomplete input: this request is too large to show in full here. Review it on the desktop to approve it. You can still deny it here."
        for persistent in [false, true] {
            let h = try await FullAuditHarness.start(persistent: persistent)
            func request(_ id: String, seq: Int64, kinds: [String], minimal: Bool = true, omitOptions: Bool = false) -> AnnexJSON {
                var data: [String: AnnexJSON] = ["requestId": .string(id), "toolCallId": .string("tool-" + id), "toolName": .string("Write"), "title": .string("Write big.ts"), "description": .string(minimal ? warning : "FULL ORIGINAL"), "options": .array(kinds.map { .object(["optionId": .string($0), "label": .string($0), "kind": .string($0)]) })]
                if minimal { data["truncated"] = .object(["originalBytes": .integer(500000)]) } else { data["rawInput"] = .object(["file_path": .string("/work/app/big.ts"), "content": .string("full input")]) }
                if omitOptions { data.removeValue(forKey: "options") }
                return LiveServiceHarness.chatEvent("s1", sequence: seq, type: "permission_request", data: data)
            }
            func page(_ pending: [AnnexJSON], events: [AnnexJSON] = []) -> AnnexJSON { LiveServiceHarness.chatSnapshot(events: events, fields: ["state": .string("waiting_permission"), "pendingPermissions": .array(pending), "capabilities": .object(["chat": .bool(true)])]) }
            do {
                for kind in ["reject_once", "reject_always", "cancel_turn"] {
                    await h.io.setChat(page([request(kind, seq: 6, kinds: [kind])]))
                    await h.store.load(h.target, force: true)
                    let a = try #require(fixtureApproval(h, id: kind)); #expect(a.summary == warning); #expect(a.detail == nil); #expect(a.options.count == 1); #expect(!a.options[0].allows)
                    let before = await h.io.commands
                    await h.store.respond(a, option: a.options[0], target: h.target)
                    let answerable = kind != "reject_always" || persistent
                    #expect(fixtureApproval(h, id: kind)?.resolution == (answerable ? .denied : .pending))
                    #expect(await h.io.commands == before + (answerable ? 1 : 0))
                }
                for missing in [false, true] {
                    await h.io.setChat(page([request("view-only", seq: 6, kinds: [], omitOptions: missing)])); await h.store.load(h.target, force: true)
                    let a = try #require(fixtureApproval(h, id: "view-only")); #expect(a.options.isEmpty); #expect(a.resolution == .pending); #expect(h.store.pinnedApproval(for: h.target) == nil)
                    let before = await h.io.commands
                    await h.store.respond(a, option: .init(id: "invented", label: "Allow", kind: .allowOnce), target: h.target)
                    #expect(await h.io.commands == before)
                    h.store.drafts[h.target] = "Chat still works"; await h.store.sendDraft(to: h.target)
                    #expect(await h.io.commands == before + 1)
                }
                let full = request("duplicate", seq: 8, kinds: ["allow_once", "reject_once"], minimal: false)
                let minimal = request("duplicate", seq: 8, kinds: ["reject_once"])
                await h.io.setChat(page([minimal], events: [full])); await h.store.load(h.target, force: true)
                let a = try #require(fixtureApproval(h, id: "duplicate")); #expect(a.summary == warning); #expect(a.options.map(\.id) == ["reject_once"]); #expect(a.detail == nil)
                #expect(h.store.conversation(for: h.target).items.filter { $0.id == "approval:duplicate" }.count == 1)
                print("MINIMAL_PERMISSION synthetic=true persistent=\(persistent) denyOnce=works cancelTurn=works rejectAlways=\(persistent ? "works" : "desktopOnly") emptyOrMissingOptions=viewOnly chat=works duplicateTail=minimalWins")
                await h.stop()
            } catch { await h.stop(); throw error }
        }
    }

    @Test func proposedQuestionFallbacksMustNotInventOrOmitPromptText() async throws {
        let h = try await FullAuditHarness.start()
        func question(_ fields: [String: AnnexJSON]) -> AnnexJSON { LiveServiceHarness.chatEvent("s1", sequence: 6, type: "question", data: ["requestId": .string("oversized-question"), "questions": .array([.object(fields)])]) }
        func q() -> CompanionQuestion? { h.store.conversation(for: h.target).items.compactMap { if case .question(let q) = $0, q.id == "oversized-question" { q } else { nil } }.first }
        func page(_ event: AnnexJSON) -> AnnexJSON { LiveServiceHarness.chatSnapshot(fields: ["state": .string("waiting_input"), "pendingQuestions": .array([event]), "capabilities": .object(["chat": .bool(true), "questions": .bool(true)])]) }
        do {
            let exactID = "Exact unshortened Claude question?"
            await h.io.setChat(page(question(["id": .string(exactID), "prompt": .string(exactID), "options": .array([]), "allowFreeText": .bool(false)])))
            await h.store.load(h.target, force: true)
            var card = try #require(q()); #expect(card.prompts.count == 1); #expect(card.prompts[0].id == exactID)
            #expect(!CompanionStore.validAnswers([exactID: .text("")], for: card)); #expect(!CompanionStore.validAnswers([exactID: .text("invented")], for: card))
            let before = await h.io.commands; await h.store.answer(card, answers: [exactID: .text("invented")], target: h.target); #expect(await h.io.commands == before)
            // Free text without options is still an answer path if enabled: unsafe for an incomplete prompt.
            await h.io.setChat(page(question(["id": .string(exactID), "prompt": .string("Incomplete preview"), "options": .array([]), "allowFreeText": .bool(true)])))
            await h.store.load(h.target, force: true); card = try #require(q())
            #expect(CompanionStore.validAnswers([exactID: .text("answer")], for: card))
            await h.store.answer(card, answers: [exactID: .text("answer")], target: h.target)
            #expect(await h.io.recordedCommands.last?["answers"]?[exactID]?.string == "answer")
            // Missing prompt text is silently compactMapped away, permitting an empty answer map.
            await h.io.setChat(page(question(["id": .string(exactID), "options": .array([])]))); await h.store.load(h.target, force: true)
            card = try #require(q()); #expect(card.prompts.isEmpty); #expect(CompanionStore.validAnswers([:], for: card))
            await h.store.answer(card, answers: [:], target: h.target)
            #expect(q()?.resolution == .answered); #expect(await h.io.recordedCommands.last?["answers"] == .object([:]))
            print("QUESTION_FALLBACK synthetic=true noOptionsNoFreeText=disabled noOptionsFreeText=answerable missingPrompt=emptyPrompts emptyAnswers=sent HTTP503=preferredExplicitFailure")
            await h.stop()
        } catch { await h.stop(); throw error }
    }
}

@MainActor private extension FrameWireAuditTests {
    func toolDeltaCapture() throws -> AnnexJSON {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("frame-2686-delta/tool-delta.json")
        return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root))
    }
    func deltaTool(_ h: FullAuditHarness, _ id: String) -> CompanionTool? {
        h.store.conversation(for: h.target).items.compactMap { if case .tool(let t) = $0, t.id == id { t } else { nil } }.first
    }
}

@MainActor extension FrameWireAuditTests {
    @Test func final2686DeltaActualFixtureAndGeneratedCallHaveNoteAndLocation() async throws {
        let captured = try toolDeltaCapture(), note = try #require(captured["note"]?.string)
        #expect(captured["sha"]?.string == "274d3acb975f9160a130df611f4547a3a431c7e0")
        for key in ["fixture", "actualCall"] {
            let h = try await FullAuditHarness.start(agentID: "durable_chat", initialSequence: 999)
            do {
                await h.io.setChat(fixturePage([])); await h.store.load(h.target, force: true)
                let frame = try #require(key == "fixture" ? captured[key]?["frame"] : captured[key])
                await h.io.push(try JSONEncoder().encode(frame))
                try await h.wait { deltaTool(h, "call_write") != nil }
                let t = try #require(deltaTool(h, "call_write"))
                #expect(t.output == note); #expect(t.location == "/work/app/big.ts"); #expect(t.summary == "big.ts")
                #expect(t.name == "Write big.ts"); #expect(t.kind == .edit); #expect(t.state == .running); #expect(t.awaitsApproval)
                #expect(h.store.conversation(for: h.target).lastSequence == 101)
                #expect(t.verb == "Edit"); #expect(t.target == "/work/app/big.ts")
                print("TOOL_DELTA_CALL source=\(key) note=firstOutputBlock location=kept title=WriteBigTs state=pending UI=collapsedDisclosureOutput")
                await h.stop()
            } catch { await h.stop(); throw error }
        }
    }

    @Test func final2686DeltaNoteAppendRepeatsReplayAndHistoryThenReplacement() async throws {
        let c = try toolDeltaCapture(), note = try #require(c["note"]?.string)
        let start = try #require(c["start"]), append = try #require(c["append"]), repeats = c["repetitions"].arrayValue
        let h = try await FullAuditHarness.start(agentID: "durable_chat", initialSequence: 999)
        func count(_ text: String) -> Int { text.components(separatedBy: note).count - 1 }
        func output() -> String { deltaTool(h, "append_tool")?.output ?? "" }
        do {
            await h.io.setChat(fixturePage([])); await h.store.load(h.target, force: true)
            await h.io.push(try JSONEncoder().encode(start)); try await h.wait { deltaTool(h, "append_tool") != nil }
            let old = output()
            await h.io.push(try JSONEncoder().encode(append)); try await h.wait { deltaTool(h, "append_tool")?.state == .completed }
            #expect(output() == old + note); #expect(count(output()) == 1)
            #expect(deltaTool(h, "append_tool")?.awaitsApproval == false)
            for frame in repeats { await h.io.push(try JSONEncoder().encode(frame)) }
            try await h.wait { h.store.conversation(for: h.target).lastSequence == 230 }
            let accumulated = output()
            #expect(count(accumulated) == 129); #expect(accumulated == old + String(repeating: note, count: 129))
            #expect(accumulated.utf8.count == old.utf8.count + note.utf8.count * 129)
            let events = ([start, append] + repeats).compactMap { $0["payload"]?["event"] }
            await h.io.setChat(fixturePage([], extra: events))
            // Real disconnect/connect boundary with same-epoch authoritative snapshot cursor.
            await h.io.setInitialSequence(1129)
            await h.transport.disconnect(); try await h.transport.connect()
            try await h.wait { await h.io.opened == 2 && h.host?.connection == .connected }
            for frame in [start, append] + repeats {
                if case .object(var fields) = frame { fields["replayed"] = .bool(true); await h.io.push(try JSONEncoder().encode(AnnexJSON.object(fields))) }
            }
            // Transport drops old global seq; projector also drops same inner seq under a new global seq.
            try await h.frame("chat:event", seq: 1130, payload: try #require(repeats.last?["payload"]), replayed: true)
            let barrier = LiveServiceHarness.chatEvent("sess_live", sequence: 231, type: "agent_message", data: ["messageId": .string("after-replay"), "text": .string("after replay")])
            try await h.frame("chat:event", seq: 1131, payload: .object(["agentId": .string("durable_chat"), "event": barrier]), replayed: true)
            try await h.wait { h.store.conversation(for: h.target).lastSequence == 231 }
            #expect(output() == accumulated); #expect(count(output()) == 129)
            #expect(await h.io.opened == 2)
            await h.io.setChat(fixturePage([], extra: events + [barrier])); await h.store.load(h.target, force: true)
            #expect(output() == accumulated); #expect(count(output()) == 129)
            await h.store.load(h.target, force: true); #expect(output() == accumulated)
            let replacement = try #require(c["replacement"])
            await h.io.push(try JSONEncoder().encode(replacement)); try await h.wait { h.store.conversation(for: h.target).lastSequence == 300 }
            let replaced = output()
            #expect(replaced.hasPrefix("REPLACEMENT HEAD")); #expect(replaced.contains("bytes of this output are omitted")); #expect(!replaced.contains("EARLIER CONTENT")); #expect(!replaced.contains(note))
            #expect(deltaTool(h, "append_tool")?.state == .completed); #expect(deltaTool(h, "append_tool")?.id == "append_tool")
            await h.io.setChat(fixturePage([], extra: events + [try #require(replacement["payload"]?["event"])])); await h.store.load(h.target, force: true)
            #expect(output() == replaced); #expect(await h.io.opened == 2)
            print("TOOL_DELTA_APPEND initialNotes=1 repeatUnique=128 totalNotes=129 aggregateGrowthBytes=\(note.utf8.count * 129) replayDuplicateGrowth=0 HTTPReloadGrowth=0 replacement=clearsOldContent reconnects=1 final=completed")
            await h.stop()
        } catch { await h.stop(); throw error }
    }
}

@MainActor extension FrameWireAuditTests {
    @Test func final2686DeltaDesktopOnlyWarningAndRefusalReachCard() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("frame-2686-delta/desktop-only-copy.json")
        let c = try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root)), event = try #require(c["preview"])
        let warning = "Incomplete input: this request is too large to show in full here. Review it on the desktop."
        let refusal = "This request is too large to review here. Review it on the desktop."
        let h = try await FullAuditHarness.start(agentID: "durable_chat")
        do {
            await h.io.setChat(fixturePage([event])); await h.store.load(h.target, force: true)
            let a = try #require(fixtureApproval(h, id: "no-deny")); #expect(a.summary.hasPrefix(warning)); #expect(a.detail?.hasPrefix(warning) == true)
            #expect(!a.summary.contains("deny it here")); #expect(a.options.map(\.id) == ["allow"])
            await h.io.setReceipts(["allow": try #require(c["receipt"])])
            await h.store.respond(a, option: a.options[0], target: h.target)
            #expect(h.store.operationErrors[h.target] == refusal); #expect(fixtureApproval(h, id: "no-deny")?.resolution == .pending)
            #expect(await h.io.commands == 1)
            print("DESKTOP_ONLY_COPY sha=274d3ac warning=visibleSummaryAndDetails refusal=exactDesktopSentence pending=true noDenyPromise=true")
            await h.stop()
        } catch { await h.stop(); throw error }
    }
}

@MainActor extension FrameWireAuditTests {
    @Test func proposedHelperConsumedReceiptsBothSnapshotOrdersAndIdempotency() async throws {
        let noMapping = "No valid helper mapping remains. This request was consumed; nothing was created."
        let notFound = "This request was already answered, or what it would change has changed. Check Needs you again."
        let startRefused = "The desktop refused to start this helper. The consumed request will disappear."
        func receipt(_ status: String, code: String, message: String, http: Int = 409) -> AnnexJSON {
            .object(["status": .integer(Int64(http)), "body": .object(["version": .integer(1), "commandId": .string("<commandId>"), "epoch": .string("<epoch>"), "status": .string(status), "error": .object(["code": .string(code), "message": .string(message)])])])
        }
        for failed in [false, true] { for snapshotFirst in [false, true] {
            let h = try await FullAuditHarness.start(); await h.seed()
            func snapshot(_ present: Bool) async throws {
                var payload = try AuditIO.fullPayload()
                payload["helperRequests"] = .array(present ? [.object(["requestId": .string("consumed-start"), "kind": .string("start"), "projectId": .string("project"), "requester": .object(["agentId": .string("agent"), "name": .string("Agent")]), "helper": .object(["name": .string("Helper")]), "summary": .string("Start helper"), "requestedAt": .string("2026-11-01T00:00:00Z"), "expiresAt": .null, "start": .object(["task": .string("Synthetic helper task")])])] : [])
                try await h.frame("snapshot", payload: .object(payload))
                try await h.wait { h.host?.helperRequests.contains { $0.id == "consumed-start" } == present && h.host?.connection == .connected }
            }
            do {
                try await snapshot(true)
                let request = try #require(h.host?.helperRequests.first { $0.id == "consumed-start" })
                #expect(h.store.canAnswer(request))
                let sentence = failed ? startRefused : noMapping
                await h.io.setHelperReceipt(receipt(failed ? "failed" : "rejected", code: failed ? "helper_start_refused" : "no_valid_mapping", message: sentence), hold: true)
                let answer = Task { await h.store.answer(request, approve: true) }
                try await h.wait { await h.io.helperWaiting && h.store.helperRequestsInFlight.contains(request.slot) }
                #expect(!h.store.canAnswer(request))
                let command = try #require(await h.io.recordedCommands.last), commandID = try #require(command["commandId"]?.string)
                #expect(command["type"]?.string == "helper.approve")
                if snapshotFirst {
                    try await snapshot(false)
                    #expect(h.store.helperRequestsInFlight.contains(request.slot))
                    #expect(h.store.helperRequestErrors[request.slot] == nil)
                }
                await h.io.releaseHelper(); await answer.value
                #expect(!h.store.helperRequestsInFlight.contains(request.slot))
                #expect(h.store.helperRequestErrors[request.slot] == sentence)
                #expect(h.store.canAnswer(request) == !snapshotFirst)
                #expect(h.host?.helperRequests.contains { $0.id == request.id } == !snapshotFirst)
                // Real transport idempotency record: same commandId yields cached receipt, zero new POSTs.
                let before = await h.io.commands
                do { try await h.service.answerHelperRequest(request, approve: true, force: false, clientCommandID: commandID); Issue.record("Consumed helper must not succeed") }
                catch { #expect(error.localizedDescription == sentence) }
                #expect(await h.io.commands == before)
                // A second manual tap in the receipt-before-snapshot window uses a fresh UUID.
                await h.io.setHelperReceipt(receipt("rejected", code: "helper_request_not_found", message: "Already consumed", http: 404))
                if !snapshotFirst {
                    await h.store.answer(request, approve: true)
                    #expect(await h.io.commands == before + 1)
                    let second = try #require(await h.io.recordedCommands.last?["commandId"]?.string)
                    #expect(second != commandID); #expect(h.store.helperRequestErrors[request.slot] == notFound)
                    try await snapshot(false)
                } else {
                    await h.store.answer(request, approve: true)
                    #expect(await h.io.commands == before) // removed row blocks stale UI invocation
                    do { try await h.service.answerHelperRequest(request, approve: true, force: false, clientCommandID: UUID().uuidString); Issue.record("Consumed helper must stay refused") }
                    catch { #expect(error.localizedDescription == notFound) }
                    #expect(await h.io.commands == before + 1)
                }
                let after = await h.io.commands
                try await Task.sleep(for: .milliseconds(100)); #expect(await h.io.commands == after)
                #expect(!h.store.canAnswer(request)); #expect(!h.store.helperRequestsInFlight.contains(request.slot))
                #expect(h.store.helperRequestErrors[request.slot] == (snapshotFirst ? sentence : notFound))
                #expect(h.host?.helperRequests.isEmpty == true)
                #expect(await h.io.recordedCommands.allSatisfy { $0["type"]?.string == "helper.approve" })
                h.assertCritical()
                print("HELPER_CONSUMED synthetic=true outcome=\(failed ? "failed" : "rejected") snapshotFirst=\(snapshotFirst) row=removed inFlight=cleared staleErrorMap=retained errorWasVisibleBeforeRemoval=\(!snapshotFirst) repeatSameID=cacheHit secondNewID=404 autoRetry=false duplicateCreation=noneInFake")
                await h.stop()
            } catch { await h.io.releaseHelper(); await h.stop(); throw error }
        } }
    }
}
