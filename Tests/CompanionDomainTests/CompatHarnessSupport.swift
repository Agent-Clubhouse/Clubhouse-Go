import CryptoKit
import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// Compatibility harness (diagnostic, test-only). Drives the REAL AnnexTransport, CompanionLiveService and CompanionStore
// with a fake AnnexIO/WebSocket serving host-exported fixtures, on an AnnexManualClock. Not covered: URLSession (its
// per-host pool, timeouts, TLS), SwiftUI, device CPU/scheduling, network. See docs/diag/compat-harness-interface.md.
//
// It must compile against three product revisions (f242adf, a0ad2b83, 1e8f194e), so it uses no API newer than f242adf
// and none of ScriptedAnnexTransport's newer helpers. The conversation view is excluded from the SwiftPM targets, so
// `CompatViewDriver` restates its two reload rules per revision; build f242adf with `-Xswiftc -DCOMPAT_VIEW_PRE_ABE8D06`.

enum CompatFixture: String, CaseIterable, CustomTestStringConvertible, Sendable {
    // Acceptance pair (host commit 48c08c27): capabilities.dispatcher.enabled = true, matching the snapshot.
    case v2beta7 = "v2-beta7", v2beta8 = "v2-beta8"
    // Negative control only: capabilities.dispatcher.enabled = false conflicts with the selected Dispatcher's snapshot.
    case negctlBeta7 = "negctl-dispatcher-disabled-beta7", negctlBeta8 = "negctl-dispatcher-disabled-beta8"
    var testDescription: String { rawValue }
    static let acceptance: [CompatFixture] = [.v2beta7, .v2beta8]
    static let negativeControl: [CompatFixture] = [.negctlBeta7, .negctlBeta8]
    var sha256: String {
        switch self {
        case .v2beta7: "7701517bba5982cd4a16a9e4fc766701c3c605cbf1788684d3babfb749b35a93"
        case .v2beta8: "6eb12004ef1ee104b0fa236ee0402f45545e5baba42cd3c4d56a6f911517e509"
        case .negctlBeta7: "6d7846bfb9f8ecb447febe2024c8159ca0bb8b2baa4d0697e2e52f1747048052"
        case .negctlBeta8: "8b78c7c732f7b82e507920203a850058eeecc148067205f6158af3bb95fb140e"
        }
    }
    /// beta.8 sends a snapshot refresh on permission create and another on withdraw; beta.7 sends neither.
    var refreshSnapshotsPerPair: (created: Int, withdrawn: Int) { isBeta8 ? (1, 1) : (0, 0) }
    var isBeta8: Bool { self == .v2beta8 || self == .negctlBeta8 }
    var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/CompatHarness")
    }
}

struct CompatHostFixture: Sendable {
    let fixture: CompatFixture
    let routes: [String: (status: Int, body: AnnexJSON)]
    let snapshotPayload: [String: AnnexJSON]
    let chatFrames: [AnnexJSON]
    let selectedAgent: String
    let expectedReply: String
    let baselineSeq: Int64

    static func load(_ fixture: CompatFixture) throws -> CompatHostFixture {
        let data = try Data(contentsOf: fixture.directory.appending(path: fixture.rawValue + ".json"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == fixture.sha256 else { throw CompatError.fixtureHash(fixture.rawValue, digest) }
        let json = try JSONDecoder().decode(AnnexJSON.self, from: data)
        var routes: [String: (Int, AnnexJSON)] = [:]
        if case .object(let map)? = json["routes"] {
            for (path, value) in map { routes[path] = (Int(value["status"]?.integer ?? 0), value["body"] ?? .null) }
        }
        guard case .object(let payload)? = json["snapshot"]?["payload"] else { throw CompatError.shape("snapshot.payload") }
        return CompatHostFixture(fixture: fixture, routes: routes, snapshotPayload: payload, chatFrames: json["chatFrames"].arrayValue,
                                 selectedAgent: json["selectedAgent"]?.string ?? "", expectedReply: json["expectedVisibleReply"]?.string ?? "",
                                 baselineSeq: payload["lastSeq"]?.integer ?? 0)
    }
    var chatPath: String { "/api/v1/mobile/agents/\(selectedAgent)/chat" }
    var chatBody: AnnexJSON { routes[chatPath]?.body ?? .null }
}

enum CompatError: Error { case fixtureHash(String, String), shape(String), timeout(String) }

/// The phone's socket. `ping()` models URLSessionAnnexWebSocket: an unanswered ping fails after 10 s on the injected clock.
actor CompatSocket: AnnexWebSocket {
    private var queue: [Data] = []
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var closed = false
    private(set) var sent: [AnnexJSON] = []
    var answersPings = true
    let clock: AnnexClock
    init(first: Data, clock: AnnexClock) { queue = [first]; self.clock = clock }
    func setAnswersPings(_ value: Bool) { answersPings = value }
    func push(_ data: Data) {
        guard !closed else { return }
        if let pending { self.pending = nil; pending.resume(returning: data) } else { queue.append(data) }
    }
    func receive() async throws -> Data {
        if closed { throw URLError(.networkConnectionLost) }
        if !queue.isEmpty { return queue.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) { if let value = try? JSONDecoder().decode(AnnexJSON.self, from: data) { sent.append(value) } }
    func ping() async throws {
        if closed { throw URLError(.networkConnectionLost) }
        if answersPings { return }
        try await clock.sleep(.seconds(10))
        close()
        throw URLError(.timedOut)
    }
    func close() {
        closed = true
        pending?.resume(throwing: URLError(.networkConnectionLost)); pending = nil
    }
}

/// The desktop as the host fixture describes it, plus controls: a dead route (every request waits 30 s, then times
/// out, as URLSession's request timeout does), held responses per path, and per-path overrides.
actor CompatIO: AnnexIO {
    struct Request: Sendable { let method: String; let path: String; let authorized: Bool; let at: Int }
    let identity = AnnexPairingIdentity()
    let fixture: CompatHostFixture
    let clock: AnnexClock
    var hostID: String { (try? AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64)) ?? "" }
    private(set) var requests: [Request] = []
    private(set) var sockets: [CompatSocket] = []
    private(set) var serverSeq: Int64
    var dead = false
    private var overrides: [String: (Int, AnnexJSON)] = [:]
    private var holdNext: Set<String> = []
    private var held: [String: CheckedContinuation<(Int, AnnexJSON), Never>] = [:]
    init(fixture: CompatHostFixture, clock: AnnexClock) { self.fixture = fixture; self.clock = clock; serverSeq = fixture.baselineSeq }

    func setDead(_ value: Bool) { dead = value }
    func override(_ path: String, status: Int, body: AnnexJSON) { overrides[path] = (status, body) }
    func clearOverride(_ path: String) { overrides.removeValue(forKey: path) }
    var currentSeq: Int64 { serverSeq }
    /// Reserves the next global sequence without sending, for a snapshot that counts an event not yet delivered.
    func reserveSeq() -> Int64 { serverSeq += 1; return serverSeq }
    /// One `chat:event` for the selected agent. `seq` is a reserved sequence, or the next one.
    func sendEvent(_ event: AnnexJSON, seq reserved: Int64? = nil) async throws {
        let seq: Int64
        if let reserved { seq = reserved } else { serverSeq += 1; seq = serverSeq }
        let frame: AnnexJSON = .object(["type": .string("chat:event"), "seq": .integer(seq),
                                        "payload": .object(["agentId": event["agentId"] ?? .null, "event": event])])
        await socket?.push(try JSONEncoder().encode(frame))
    }
    /// A refresh snapshot at an explicit `lastSeq`, with an optional payload edit.
    func pushSnapshot(lastSeq: Int64, edit: @Sendable (inout [String: AnnexJSON]) -> Void = { _ in }) async throws {
        var payload = fixture.snapshotPayload
        if case .object(var machine)? = payload["machine"] { machine["fingerprint"] = .string(hostID); payload["machine"] = .object(machine) }
        edit(&payload)
        payload["lastSeq"] = .integer(lastSeq)
        await socket?.push(try JSONEncoder().encode(AnnexJSON.object(["type": .string("snapshot"), "payload": .object(payload)])))
    }
    func hold(_ path: String) { holdNext.insert(path) }
    func isHeld(_ path: String) -> Bool { held[path] != nil }
    func release(_ path: String, status: Int, body: AnnexJSON) { held.removeValue(forKey: path)?.resume(returning: (status, body)) }
    func count(_ path: String) -> Int { requests.filter { $0.path == path && $0.method == "GET" }.count }
    func count(prefix: String, suffix: String) -> Int { requests.filter { $0.path.hasPrefix(prefix) && $0.path.hasSuffix(suffix) }.count }
    var posts: Int { requests.filter { $0.method != "GET" && $0.method != "WS" }.count }
    private(set) var notFound: [String] = []
    var unauthorized: Int { requests.filter { !$0.authorized }.count }
    var paths: [String] { requests.map(\.path) }
    var socket: CompatSocket? { sockets.last }

    /// The snapshot as the host sends it, bound to this run's host identity (`machine.fingerprint` is the only field
    /// rewritten: the transport refuses a snapshot from another machine) and at the server's current sequence.
    func snapshotFrame() throws -> Data {
        var payload = fixture.snapshotPayload
        if case .object(var machine)? = payload["machine"] { machine["fingerprint"] = .string(hostID); payload["machine"] = .object(machine) }
        payload["lastSeq"] = .integer(serverSeq)
        return try JSONEncoder().encode(AnnexJSON.object(["type": .string("snapshot"), "payload": .object(payload)]))
    }
    /// Sends a fixture chat frame, renumbered onto the server's global sequence.
    func sendChatFrame(_ frame: AnnexJSON) async throws {
        guard case .object(var object) = frame else { return }
        serverSeq += 1; object["seq"] = .integer(serverSeq)
        await socket?.push(try JSONEncoder().encode(AnnexJSON.object(object)))
    }
    /// beta.7 and beta.8 both buffer `permission:request` with a sequence. Only beta.8 follows it with a snapshot refresh.
    func permissionCreated(id: String, refreshes: Int) async throws {
        serverSeq += 1
        let frame: AnnexJSON = .object(["type": .string("permission:request"), "seq": .integer(serverSeq), "payload": .object([
            "requestId": .string(id), "agentId": .string("durable_chat"), "toolName": .string("Bash"), "toolInput": .object([:]),
            "message": .string("fixture"), "timeout": .integer(120_000), "deadline": .integer(1_800_000_120_000)])])
        await socket?.push(try JSONEncoder().encode(frame))
        for _ in 0..<refreshes { await socket?.push(try snapshotFrame()) }
    }
    /// Withdrawal itself sends no buffered frame on either release; beta.8 sends a snapshot refresh.
    /// Sensitivity control only: an event the server buffered but this socket never received, then a snapshot at that seq.
    func refreshSnapshotAheadOfStream() async throws {
        serverSeq += 1
        await socket?.push(try snapshotFrame())
    }
    func permissionWithdrawn(refreshes: Int) async throws {
        for _ in 0..<refreshes { await socket?.push(try snapshotFrame()) }
    }

    func perform(_ request: URLRequest) async throws -> AnnexHTTPResponse {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        requests.append(.init(method: method, path: path, authorized: request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true, at: requests.count))
        if dead { try await clock.sleep(.seconds(30)); throw URLError(.timedOut) }
        if path.hasSuffix("/identity") {
            return try .init(status: 200, data: JSONEncoder().encode(AnnexJSON.object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(hostID)])))
        }
        if method != "GET" { return try .init(status: 500, data: JSONEncoder().encode(AnnexJSON.object(["error": .string("harness_refuses_commands")]))) }
        let answer: (Int, AnnexJSON)
        if holdNext.remove(path) != nil {
            answer = await withCheckedContinuation { held[path] = $0 }
        } else if let override = overrides[path] {
            answer = override
        } else if let route = fixture.routes[path] {
            answer = (route.status, route.body)
        } else {
            notFound.append(path)
            answer = (404, .object(["error": .string("not_found")]))
        }
        return try .init(status: answer.0, data: JSONEncoder().encode(answer.1))
    }
    func openWebSocket(_ request: URLRequest) async throws -> any AnnexWebSocket {
        requests.append(.init(method: "WS", path: request.url?.path ?? "", authorized: request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true, at: requests.count))
        if dead { try await clock.sleep(.seconds(30)); throw URLError(.timedOut) }
        let socket = CompatSocket(first: try snapshotFrame(), clock: clock)
        sockets.append(socket)
        return socket
    }
}

/// CompanionConversationView's two reload rules for the selected conversation, per product revision.
@MainActor final class CompatViewDriver {
    let store: CompanionStore
    let target: CompanionTarget
    private var last: CompanionConnection?
    private var watcher: Task<Void, Never>?
    private(set) var connectionReloads = 0
    init(store: CompanionStore, target: CompanionTarget) { self.store = store; self.target = target }

    /// `.task(id: target)`.
    func open() async {
        #if COMPAT_VIEW_PRE_ABE8D06
        await store.load(target, force: store.conversation(for: target).requiresResync)
        #else
        await store.loadOnOpen(target)
        #endif
    }
    /// `.onChange(of: connection)`, sampled every millisecond.
    func mount() {
        last = store.host(for: target)?.connection ?? .offline
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }
    private func sample() {
        let current = store.host(for: target)?.connection ?? .offline
        defer { last = current }
        guard current != last else { return }
        let conversation = store.conversation(for: target)
        #if COMPAT_VIEW_PRE_ABE8D06
        let applies = true
        #else
        let applies = store.selection != target
        #endif
        if applies && current.canOperate && conversation.requiresResync && !conversation.isLoading {
            connectionReloads += 1
            Task { await store.load(target, force: true) }
        }
    }
    func unmount() { watcher?.cancel(); watcher = nil }
}

/// Transitions of the selected conversation, sampled every millisecond.
@MainActor final class CompatSampler {
    let store: CompanionStore
    let target: CompanionTarget
    private var task: Task<Void, Never>?
    private var wasLoading = false
    private(set) var loadStarts = 0
    private(set) var loadEnds = 0
    private(set) var endsNeedingResync = 0
    private(set) var phases: [CompanionRecoveryStatus.Phase] = []
    /// Set by a test once the previous page is no longer current; any sample that presents it as current counts.
    var stalePage: [CompanionTimelineItem]?
    /// Set by a test: true when the conversation shows something no longer current. Counted while presented as current.
    var staleCheck: (() -> Bool)?
    private(set) var staleShownAsCurrent = 0
    init(store: CompanionStore, target: CompanionTarget) { self.store = store; self.target = target }
    func start() {
        wasLoading = store.conversation(for: target).isLoading
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled { self?.sample(); try? await Task.sleep(for: .milliseconds(1)) }
        }
    }
    func sample() {
        let c = store.conversation(for: target)
        if c.isLoading && !wasLoading { loadStarts += 1 }
        if !c.isLoading && wasLoading { loadEnds += 1; if c.requiresResync { endsNeedingResync += 1 } }
        wasLoading = c.isLoading
        let phase = CompanionRecoveryStatus(connection: store.host(for: target)?.connection ?? .offline, isLoading: c.isLoading,
                                            requiresResync: c.requiresResync, error: c.error).phase
        if phases.last != phase { phases.append(phase) }
        if let stalePage, c.items == stalePage, phase == .hidden { staleShownAsCurrent += 1 }
        if let staleCheck, staleCheck(), phase == .hidden { staleShownAsCurrent += 1 }
    }
    func stop() { task?.cancel(); sample() }
}

@MainActor struct CompatHarness {
    let fixture: CompatHostFixture
    let io: CompatIO
    let manual: AnnexManualClock
    let transport: AnnexTransport
    let service: CompanionLiveService
    let store: CompanionStore
    let target: CompanionTarget
    let driver: CompatViewDriver
    let sampler: CompatSampler
    /// Poll budget per wait: the "bounded steps" of the assertions (1 ms each).
    static let maxSteps = 3000

    static func start(_ fixture: CompatFixture) async throws -> CompatHarness {
        let loaded = try CompatHostFixture.load(fixture)
        let manual = AnnexManualClock(origin: Date(timeIntervalSince1970: 1_800_000_000))
        let clock = manual.clock
        let io = CompatIO(fixture: loaded, clock: clock)
        let hostID = await io.hostID
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                                        verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "fixture-only"), for: hostID)
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, clock: clock)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "compat-harness-icons/\(UUID().uuidString)")
        let service = CompanionLiveService(iconStore: CompanionIconStore(directory: root))
        let store = CompanionStore(service: service, clock: clock)
        store.start()
        let target = CompanionTarget(hostID: hostID, projectID: "__dispatcher__", agentID: loaded.selectedAgent)
        let harness = CompatHarness(fixture: loaded, io: io, manual: manual, transport: transport, service: service, store: store,
                                    target: target, driver: CompatViewDriver(store: store, target: target), sampler: CompatSampler(store: store, target: target))
        await service.register(.init(host: host, alias: "fixture", transport: transport))
        _ = try await harness.wait("first catalog") { await harness.catalogComplete() }
        return harness
    }

    var host: CompanionHost? { store.hosts.first { $0.id == target.hostID } }
    var conversation: CompanionConversation { store.conversation(for: target) }
    func catalogComplete() async -> Bool {
        guard host?.connection == .connected else { return false }
        return await io.count(prefix: "/api/v1/projects/", suffix: "/agents") >= 14
    }
    func chatReads() async -> Int { await io.count(fixture.chatPath) }
    func catalogPasses() async -> Int { await io.count("/api/v1/projects") }

    /// RootView's selection, then the conversation view mounting.
    func select() async {
        store.selection = target
        driver.mount()
        sampler.start()
        await driver.open()
    }
    func stop() async {
        driver.unmount(); sampler.stop()
        store.stop(); service.remove(hostID: target.hostID)
        await transport.disconnect()
    }

    /// Polls up to `maxSteps` times; returns the steps used, or throws with the label.
    @discardableResult
    func wait(_ label: String, steps: Int = maxSteps, _ condition: () async -> Bool) async throws -> Int {
        for step in 0..<steps {
            if await condition() { return step }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CompatError.timeout(label)
    }
    /// Lets queued work run without moving the manual clock.
    func settle(_ steps: Int = 60) async { for _ in 0..<steps { try? await Task.sleep(for: .milliseconds(1)) } }
    func advance(_ seconds: Double) async {
        manual.advance(by: .milliseconds(Int(seconds * 1000)))
        await settle(5)
    }

    var usable: Bool {
        let c = conversation
        return host?.connection == .connected && c.isLoaded && !c.isLoading && !c.requiresResync && c.error == nil
    }
    func texts() -> [String] {
        conversation.items.compactMap { if case .message(let m) = $0 { return m.text }; return nil }
    }
    func pendingApprovals() -> Int {
        conversation.items.reduce(0) { count, item in
            if case .approval(let a) = item, a.resolution == .pending { return count + 1 }
            return count
        }
    }
    /// The fixture's projected message order: the user's prompt, the visible reply, then the routed update.
    func projectsFixtureInOrder() -> Bool {
        let t = texts()
        guard let you = t.firstIndex(of: "Tell me when checkout is fixed."),
              let reply = t.firstIndex(of: fixture.expectedReply),
              let news = t.firstIndex(where: { $0.hasPrefix("2 updates, oldest first") }) else { return false }
        return you < reply && reply < news && t.filter { $0 == fixture.expectedReply }.count == 1
    }
    /// The fixture page with the visible reply replaced, as another display run of the same agent would serve it.
    func page(reply: String, session: String? = nil) -> AnnexJSON {
        guard case .object(var body) = fixture.chatBody else { return .null }
        body["events"] = .array(body["events"].arrayValue.map { event in
            guard case .object(var e) = event else { return event }
            if let session { e["sessionId"] = .string(session) }
            if e["type"]?.string == "agent_message", case .object(var data)? = e["data"] { data["text"] = .string(reply); e["data"] = .object(data) }
            if e["type"]?.string == "agent_message_chunk", case .object(var data)? = e["data"] { data["text"] = .string(reply); e["data"] = .object(data) }
            return .object(e)
        })
        if let session { body["sessionId"] = .string(session) }
        return .object(body)
    }

    func row(_ name: String, _ fields: [(String, Any)]) {
        let product = ProcessInfo.processInfo.environment["COMPAT_PRODUCT_SHA"] ?? "unset"
        print("COMPAT_ROW test=\(name) product=\(product) fixture=\(fixture.fixture.rawValue) " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }
}
