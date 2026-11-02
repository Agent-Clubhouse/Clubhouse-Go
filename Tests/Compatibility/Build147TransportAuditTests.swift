import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

private enum OverflowMode: String, Sendable { case healthy, emptyMinimal, emptyExplicit, tooLarge, failed, close1013 }
private actor AuditSocket: AnnexWebSocket {
    private var packets: [Data]
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    init(_ packet: Data) { packets = [packet] }
    func receive() async throws -> Data {
        if closed { throw URLError(.networkConnectionLost) }
        if !packets.isEmpty { return packets.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ packet: Data) { if let pending { self.pending = nil; pending.resume(returning: packet) } else { packets.append(packet) } }
    func send(_ data: Data) {}
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
    var chat: AnnexJSON?
    func setChat(_ value: AnnexJSON) { chat = value }
    var socket: AuditSocket?
    let port: Int
    init(port: Int, script: ScriptedAnnexTransport) { self.port = port; self.script = script }
    func configure() async {
        await script.setFeature("dispatcher", .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true), "newLayout": .bool(true), "projectId": .string("__dispatcher__")]))
        await script.setFeature("helperRequests", .object(["version": .integer(1)]))
        await script.addCommands(["helper.approve", "helper.decline", "dispatcher.setEnabled"])
    }
    func setMode(_ value: OverflowMode) { mode = value }
    func setProjectName(_ name: String) async { await script.setProjects(.array([.object(["id": .string("project"), "name": .string(name)])])) }
    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        let path = request.url!.path
        let value: AnnexJSON
        var status = 200
        if path.hasSuffix("/identity") {
            value = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if request.httpMethod == "POST" {
            commands += 1
            let command = try JSONDecoder().decode(AnnexJSON.self, from: request.httpBody!)
            if command["type"]?.string == "chat.permission", command["optionId"]?.string == "allow" {
                permissionRejections += 1; status = 409
                value = .object(["version": .integer(1), "epoch": .string("epoch"), "commandId": command["commandId"]!, "status": .string("rejected"), "error": .object(["code": .string("incomplete_representation"), "message": .string("This input is incomplete. Review the full request on desktop before approving.")])])
            } else {
                value = .object(["version": .integer(1), "epoch": .string("epoch"), "commandId": command["commandId"]!, "status": .string("completed")])
            }
        } else if path.hasSuffix("/capabilities") { value = try await script.read(.capabilities)
        } else if path.hasSuffix("/projects") { value = try await script.read(.projects)
        } else if path.hasSuffix("/chat") { if let chat { value = chat } else { value = await LiveServiceHarness.chatSnapshot() }
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
    var target: CompanionTarget { .init(hostID: hostID, projectID: "project", agentID: "agent") }
    var dispatcher: CompanionTarget { .init(hostID: hostID, projectID: "__dispatcher__", agentID: "dispatcher") }
    var host: CompanionHost? { store.hosts.first }
    static func start(mode: OverflowMode = .healthy, realTime: Bool = false) async throws -> Self {
        let portFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("close1013-port")
        let io = AuditIO(port: Int(try String(contentsOf: portFile, encoding: .utf8))!, script: ScriptedAnnexTransport())
        await io.configure(); await io.setMode(mode)
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
        let harness = Self(io: io, transport: transport, service: service, store: store, manual: manual, sleeps: sleeps, hostID: hostID, tape: tape, observer: observer)
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

@MainActor @Suite(.serialized) struct Build147TransportAuditTests {
    @Test func permissionPreviewSnapshotLiveReplayAndRefusedApproval() async throws {
        let h = try await FullAuditHarness.start()
        do {
            let preview = "HEAD α🙂\n[20 MB input omitted]\nTAIL Ω"
            let note = "INCOMPLETE INPUT: full request must be reviewed on desktop."
            var sequence: Int64 = 2
            var wireSequence: Int64 = 1
            for route in ["snapshot", "live", "replay"] {
                for shape in ["rawInput", "textContent", "toolInputOnly", "warningDescription", "longRawInput"] {
                    let id = "\(route)-\(shape)"
                    let input: AnnexJSON = .object(["file_path": .string("/private/example/large.txt"), "content": .string(shape == "longRawInput" ? String(repeating: "a", count: 450) + "\nINCOMPLETE TAIL NOTE" : preview), "truncated": .bool(true), "totalBytes": .integer(20_000_000)])
                    var fields: [String: AnnexJSON] = ["requestId": .string(id), "toolName": .string("Write"), "title": .string("Write large.txt"), "description": .string(shape == "warningDescription" ? note : "Write file"), "truncated": .bool(true), "totalBytes": .integer(20_000_000), "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow once"), "kind": .string("allow_once")]), .object(["optionId": .string("deny"), "label": .string("Deny"), "kind": .string("reject_once")])])]
                    fields["toolInput"] = input
                    if shape != "toolInputOnly" { fields["rawInput"] = input }
                    if shape == "textContent" { fields["content"] = .array([.object(["type": .string("text"), "text": .string(note + "\n" + preview)])]) }
                    let event = LiveServiceHarness.chatEvent("s1", sequence: sequence, type: "permission_request", data: fields)
                    if route == "snapshot" {
                        await h.io.setChat(LiveServiceHarness.chatSnapshot(fields: ["pendingPermissions": .array([event])]))
                        await h.store.load(h.target, force: true)
                    } else {
                        let envelope: AnnexJSON = .object(["type": .string("chat:event"), "epoch": .string("epoch"), "seq": .integer(wireSequence), "replayed": .bool(route == "replay"), "payload": .object(["agentId": .string("agent"), "event": event])])
                        await h.io.push(try JSONEncoder().encode(envelope))
                        wireSequence += 1
                    }
                    func approval() -> CompanionApproval? { h.store.conversation(for: h.target).items.compactMap { if case .approval(let value) = $0, value.id == id { return value }; return nil }.first }
                    try await h.wait { approval() != nil }
                    let initial = try #require(approval())
                    #expect(initial.title == "Write large.txt")
                    #expect(initial.summary == (shape == "warningDescription" ? note : "Write file"))
                    switch shape {
                    case "toolInputOnly": #expect(initial.detail == nil)
                    case "textContent": #expect(initial.detail == note + "\n" + preview)
                    case "longRawInput": #expect(initial.detail == "large.txt\n" + String(repeating: "a", count: 400))
                    default: #expect(initial.detail == "large.txt\n" + preview)
                    }
                    #expect(initial.options.map(\.label) == ["Allow once", "Deny"])
                    #expect(initial.resolution == .pending)
                    #expect(h.store.canOperate(h.target))
                    #expect(h.store.agent(for: h.target)?.capabilities.contains(.approve) == true)
                    let before = await h.io.commands
                    await h.store.respond(initial, option: initial.options[0], target: h.target)
                    #expect(approval()?.resolution == .pending)
                    #expect(h.store.operationErrors[h.target] == "This input is incomplete. Review the full request on desktop before approving.")
                    #expect(!h.store.pendingCommands.contains(h.target))
                    #expect(!h.store.conversation(for: h.target).requiresResync)
                    // No automatic retry; a second user tap retries, and is refused again.
                    try await Task.sleep(for: .milliseconds(25))
                    #expect(await h.io.commands == before + 1)
                    await h.store.respond(initial, option: initial.options[0], target: h.target)
                    #expect(approval()?.resolution == .pending)
                    #expect(await h.io.commands == before + 2)
                    await h.store.respond(initial, option: initial.options[1], target: h.target)
                    #expect(approval()?.resolution == .denied)
                    #expect(h.store.operationErrors[h.target] == nil)
                    print("BUILD147_PERMISSION route=\(route) shape=\(shape) title=\(initial.title ?? initial.toolName) summary=\(initial.summary) detail=\(initial.detail.debugDescription) approve=pending+desktopSentence+noRetry deny=denied")
                    sequence += 1
                }
            }
            #expect(await h.io.permissionRejections == 30)
            // The desktop's literal permission:request is not the rich chat event 147 projects.
            let before = h.store.conversation(for: h.target).items.count
            await h.io.push(try JSONEncoder().encode(AnnexJSON.object(["type": .string("permission:request"), "epoch": .string("epoch"), "seq": .integer(wireSequence), "payload": .object(["requestId": .string("literal-event"), "toolName": .string("Write"), "toolInput": .string(preview)])])))
            try await Task.sleep(for: .milliseconds(30))
            #expect(h.store.conversation(for: h.target).items.count == before)
            await h.stop()
        } catch { await h.stop(); throw error }
    }

    @Test func optionalFieldsThroughTheRealSocketTransport() async throws {
        let h = try await FullAuditHarness.start()
        do {
            var count = 0
            for field in ["canvasState", "appCanvasState", "bulletinDigests", "snapshotTruncated", "plugins.contributes", "combined"] {
                for shape in Build147SnapshotShapeTests.Shape.allCases {
                    var payload = try AuditIO.fullPayload(name: "raw-\(count)")
                    if field == "plugins.contributes" { var plugin: [String: AnnexJSON] = [:]; plugin["contributes"] = shape.value; payload["plugins"] = .array([.object(plugin)]) }
                    else if field == "combined" { for key in ["canvasState", "appCanvasState", "bulletinDigests"] { payload[key] = shape.value }; payload["snapshotTruncated"] = .object(["version": .integer(1), "reason": .string("frame_limit")]) }
                    else { payload[field] = shape.value }
                    await h.io.setProjectName("raw-\(count)")
                    let data = try JSONEncoder().encode(AnnexJSON.object(["type": .string("snapshot"), "epoch": .string("epoch"), "payload": .object(payload), "snapshotTruncated": .object([:])]))
                    await h.io.push(data)
                    try await h.wait { h.host?.projects.first?.name == "raw-\(count)" && h.host?.connection == .connected }
                    print("BUILD147_RAW field=\(field) shape=\(shape.rawValue) catalog=true connected=true malformed=false")
                    count += 1
                }
            }
            for projectShape in [Build147SnapshotShapeTests.Shape.absent, .object, .null] {
                for agentShape in [Build147SnapshotShapeTests.Shape.absent, .object, .null] {
                    var seed = try AuditIO.fullPayload(name: "seed-\(count)")
                    seed["projectIcons"] = .object(["project": .string("data:image/png;base64,AQID")])
                    seed["agentIcons"] = .object(["agent": .string("data:image/png;base64,AQID")])
                    await h.io.setProjectName("seed-\(count)")
                    await h.io.push(try JSONEncoder().encode(AnnexJSON.object(["type": .string("snapshot"), "epoch": .string("epoch"), "payload": .object(seed)])))
                    try await h.wait { h.host?.projects.first?.name == "seed-\(count)" && h.host?.projects.first?.agents.first?.iconData != nil }
                    var payload = try AuditIO.fullPayload(name: "icons-\(count)")
                    payload["projectIcons"] = projectShape.value; payload["agentIcons"] = agentShape.value
                    await h.io.setProjectName("icons-\(count)")
                    await h.io.push(try JSONEncoder().encode(AnnexJSON.object(["type": .string("snapshot"), "epoch": .string("epoch"), "payload": .object(payload)])))
                    try await h.wait { h.host?.projects.first?.name == "icons-\(count)" && h.host?.connection == .connected }
                    let retained = projectShape == .absent && agentShape == .absent
                    #expect((h.host?.projects.first?.iconData != nil) == retained)
                    #expect((h.host?.projects.first?.agents.first?.iconData != nil) == retained)
                    print("BUILD147_RAW_ICONS projects=\(projectShape.rawValue) agents=\(agentShape.rawValue) accepted=true retained=\(retained)")
                    count += 1
                }
            }
            // Actual fail-closed control: missing snapshot sequence is rejected by the transport.
            let invalid: AnnexJSON = .object(["type": .string("snapshot"), "payload": .object(["projects": .array([]), "agents": .object([:])])])
            await h.io.push(try JSONEncoder().encode(invalid))
            try await h.wait { h.host?.connection == .failed(CompanionLiveService.readableError(AnnexTransportError.malformedResponse)) }
            print("BUILD147_RAW missingSequence=malformedResponse")
        } catch { await h.stop(); throw error }
        await h.stop()
    }

    @Test(.timeLimit(.minutes(2))) func repeatedSnapshotFailedRealTimeCadence() async throws {
        let h = try await FullAuditHarness.start(realTime: true)
        let started = ContinuousClock.now
        await h.io.setMode(.failed)
        await h.service.reconnect(hostID: h.hostID)
        try await h.wait(tries: 20_000) { await h.io.opened >= 3 }
        let first = started.duration(to: .now)
        try await h.wait(tries: 20_000) { await h.io.opened >= 4 }
        let total = started.duration(to: .now)
        let backoffs = Array(h.sleeps.backoffs.prefix(2))
        #expect(backoffs.count == 2)
        #expect(backoffs.allSatisfy { (0.25...0.5).contains($0) })
        print("BUILD147_REAL_D firstRetry=\(first) secondRetry=\(total) backoffs=\(backoffs) cachedProjects=\(h.host?.projects.count ?? -1) helpers=\(h.host?.helperRequests.count ?? -1)")
        await h.stop()
    }

    @Test func coldErrorFramesBeforeAnySnapshot() async throws {
        for mode in [OverflowMode.tooLarge, .failed] {
            let h = try await FullAuditHarness.start(mode: mode)
            await h.summary("cold-" + mode.rawValue)
            let receipt = try await h.transport.execute(.init(epoch: "epoch", kind: .interrupt(agentID: "agent", sessionID: "s1")))
            #expect(receipt.status == .completed)
            #expect(await h.command() == false)
            #expect(h.host?.connection == .connecting)
            print("BUILD147_COLD case=\(mode.rawValue) transportCommand=true serviceCommand=false noPriorCatalog=true")
            await h.stop()
        }
    }

    @Test func coreOverflowOptionsWithCachedStateAndLiveCommands() async throws {
        for mode in [OverflowMode.emptyMinimal, .emptyExplicit, .tooLarge, .failed, .close1013] {
            let h = try await FullAuditHarness.start()
            h.tape.projects.removeAll()
            await h.io.setProjectName("rest-" + mode.rawValue)
            await h.io.setMode(mode)
            await h.service.reconnect(hostID: h.hostID)
            try await h.wait { await h.io.opened >= 2 }
            if mode == .emptyMinimal || mode == .emptyExplicit {
                try await h.wait { h.host?.connection == .connected && h.host?.projects.first?.name == "rest-" + mode.rawValue }
                #expect(h.tape.projects.contains(0))
                if mode == .emptyExplicit {
                    #expect(h.host?.helperRequests.isEmpty == true)
                    #expect(h.store.conversation(for: h.dispatcher).items.isEmpty)
                }
            } else if mode == .failed { try await h.wait { h.manual.sleeperCount >= 2 } }
            else if mode == .close1013 { try await h.wait { !h.sleeps.backoffs.isEmpty } }
            else { try await Task.sleep(for: .milliseconds(30)) }
            await h.summary(mode.rawValue + "-initial")
            if mode == .tooLarge {
                h.manual.advance(by: .seconds(120)); try await Task.sleep(for: .milliseconds(30))
                await h.summary("tooLarge-after120s")
                #expect(await h.io.opened == 2)
                #expect(h.host?.connection == .connecting)
            }
            if mode == .failed {
                for cycle in 1...3 {
                    let previous = await h.io.opened
                    h.manual.advance(by: .seconds(30))
                    try await h.wait { h.sleeps.backoffs.count >= cycle }
                    h.manual.advance(by: .seconds(pow(2, Double(cycle))))
                    try await h.wait { await h.io.opened > previous && h.manual.sleeperCount >= 2 }
                    try await Task.sleep(for: .milliseconds(20))
                    await h.summary("failed-cycle\(cycle)")
                }
            }
            if mode == .close1013 {
                for cycle in 1...4 {
                    let previous = await h.io.opened
                    h.manual.advance(by: .seconds(pow(2, Double(cycle))))
                    try await h.wait { await h.io.opened > previous && h.sleeps.backoffs.count > cycle }
                    await h.summary("close1013-cycle\(cycle)")
                }
                #expect(h.io.closeCodes.values.count >= 5)
                #expect(h.io.closeCodes.values.allSatisfy { $0 == 1005 })
            }
            #expect(h.store.conversation(for: h.target).items.isEmpty == false)
            await h.stop()
        }
    }
}
