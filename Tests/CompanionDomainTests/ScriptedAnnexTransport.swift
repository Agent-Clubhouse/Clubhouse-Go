import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// A scriptable `AnnexTransporting` fake for behaviour tests of `CompanionLiveService`: capability documents
/// can be downgraded, reads can fail per route, and each command's outcome is queued ahead of time.
actor ScriptedAnnexTransport: AnnexTransporting {
    /// How the next executed command ends.
    enum Outcome: Sendable {
        case completed(AnnexJSON? = nil)
        case rejected(code: String, message: String)
        case failed(message: String?)
        case thrown(AnnexTransportError)
    }

    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    private(set) var subscriptionCount = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private var connectErrors: [AnnexTransportError] = []

    // Capabilities.
    private var epoch = "epoch"
    private var controlAvailable = true
    private var commands: [String] = ["chat.send", "agent.start", "chat.interrupt", "chat.permission", "chat.question", "chat.queue.remove"]
    private var features: [String: AnnexJSON] = [:]
    private var extraCapabilities: [String: AnnexJSON] = [:]

    // Catalog.
    private var projects: AnnexJSON = .array([.object(["id": .string("project"), "name": .string("Project")])])
    private var agents: AnnexJSON = .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])])
    private var projectsError: AnnexTransportError?

    // Other reads, keyed by route name (see `key(_:)`).
    private var reads: [String: Result<AnnexJSON, AnnexTransportError>] = [:]
    private(set) var readRoutes: [AnnexReadRouteRecord] = []

    // Commands.
    private var outcomes: [Outcome] = []
    private(set) var executed: [AnnexCommand] = []

    func setEpoch(_ value: String) { epoch = value }
    func setControlAvailable(_ value: Bool) { controlAvailable = value }
    func setCommands(_ value: [String]) { commands = value }
    func addCommands(_ value: [String]) { commands += value }
    /// A versioned feature block such as `projectState` or `finishedQuickAgents`.
    func setFeature(_ name: String, _ value: AnnexJSON) { features[name] = value }
    /// Any other top-level capability field, such as `richContent` or `routes`.
    func setCapability(_ name: String, _ value: AnnexJSON) { extraCapabilities[name] = value }
    func setProjects(_ value: AnnexJSON) { projects = value }
    func setAgents(_ value: AnnexJSON) { agents = value }
    func failProjects(_ error: AnnexTransportError?) { projectsError = error }
    func failNextConnect(_ error: AnnexTransportError) { connectErrors.append(error) }
    func setRead(_ route: String, _ value: AnnexJSON) { reads[route] = .success(value) }
    func failRead(_ route: String, _ error: AnnexTransportError) { reads[route] = .failure(error) }
    func enqueue(_ outcome: Outcome) { outcomes.append(outcome) }

    // MARK: Events

    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        subscriptionCount += 1
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        continuation = pair.continuation
        return pair.stream
    }
    func connect() throws {
        connectCount += 1
        if !connectErrors.isEmpty { throw connectErrors.removeFirst() }
        emit(.connection(.connected))
    }
    func disconnect() { disconnectCount += 1; emit(.connection(.disconnected)) }
    func emit(_ event: AnnexTransportEvent) { continuation?.yield(event) }
    /// Ends the event stream, as when the socket closes underneath the subscription.
    func finishEvents(throwing error: Error? = nil) {
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    // MARK: Reads

    static func key(_ route: AnnexReadRoute) -> String {
        switch route {
        case .capabilities: "capabilities"
        case .projects: "projects"
        case .agents: "agents"
        case .chat: "chat"
        case .chatSessions: "chatSessions"
        case .chatContent: "chatContent"
        case .chatHistory: "chatHistory"
        case .createOptions: "createOptions"
        case .agentSettings: "agentSettings"
        case .gitStatus: "gitStatus"
        case .gitDiff: "gitDiff"
        default: "other"
        }
    }

    private var capabilitiesDocument: AnnexJSON {
        var caps: [String: AnnexJSON] = [
            "version": .integer(1), "epoch": .string(epoch), "controlAuth": .string("mtls-pinned-client"),
            "controlAvailable": .bool(controlAvailable),
            "idempotency": .object(["scope": .string("client"), "maxEntries": .integer(256), "ttlMs": .integer(60000)]),
            "commands": .array(commands.map(AnnexJSON.string)),
        ]
        caps.merge(features) { _, new in new }
        caps.merge(extraCapabilities) { _, new in new }
        return .object(caps)
    }

    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON {
        readRoutes.append(.init(route))
        switch route {
        case .capabilities: return capabilitiesDocument
        case .projects:
            if let projectsError { throw projectsError }
            return projects
        case .agents: return agents
        default:
            switch reads[Self.key(route)] {
            case .success(let value)?: return value
            case .failure(let error)?: throw error
            case nil: throw AnnexTransportError.unsupportedCapability("fixture")
            }
        }
    }

    // MARK: Commands

    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        executed.append(command)
        let outcome = outcomes.isEmpty ? .completed(nil) : outcomes.removeFirst()
        let status: String, error: AnnexJSON, result: AnnexJSON
        switch outcome {
        case .completed(let value): status = "completed"; error = .null; result = value ?? .null
        case .rejected(let code, let message):
            status = "rejected"; error = .object(["code": .string(code), "message": .string(message)]); result = .null
        case .failed(let message):
            status = "failed"; result = .null
            error = message.map { .object(["code": .string("failed"), "message": .string($0)]) } ?? .null
        case .thrown(let thrown): throw thrown
        }
        return try AnnexJSON.object(["version": .integer(1), "epoch": .string(epoch), "commandId": .string(command.commandID),
                                     "status": .string(status), "error": error, "result": result]).decode(AnnexCommandReceipt.self)
    }
}

/// A read the fake answered, kept as plain values for assertions.
struct AnnexReadRouteRecord: Sendable, Equatable {
    var name: String
    var mediaRef: String?
    var filePath: String?
    var sessionID: String?
    init(_ route: AnnexReadRoute) {
        name = ScriptedAnnexTransport.key(route)
        switch route {
        case .chatContent(_, let ref, let path): mediaRef = ref; filePath = path
        case .chatHistory(_, let session, _, _): sessionID = session
        default: break
        }
    }
}

/// One live service with a store observing it, registered with a scripted desktop.
@MainActor struct LiveServiceHarness {
    static let hostID = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
    let target = CompanionTarget(hostID: hostID, projectID: "project", agentID: "agent")
    var project: CompanionProjectTarget { .init(hostID: Self.hostID, projectID: "project") }
    let transport: ScriptedAnnexTransport
    let service: CompanionLiveService
    let store: CompanionStore

    /// `configure` runs before the host is registered, so the first catalog refresh already sees it.
    static func start(alias: String = "Fixture", waitForConnection: Bool = true,
                      configure: (ScriptedAnnexTransport) async -> Void = { _ in },
                      prepare: (CompanionLiveService) -> Void = { _ in }) async throws -> LiveServiceHarness {
        let transport = ScriptedAnnexTransport()
        await configure(transport)
        let service = CompanionLiveService()
        prepare(service)
        let store = CompanionStore(service: service)
        store.start()
        let harness = LiveServiceHarness(transport: transport, service: service, store: store)
        await service.register(.init(host: try trustedHost(), alias: alias, transport: transport))
        if waitForConnection { try await harness.waitUntil { harness.host?.connection == .connected } }
        return harness
    }

    static func trustedHost() throws -> TrustedAnnexHost {
        try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                             verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
    }

    var host: CompanionHost? { store.hosts.first { $0.id == Self.hostID } }

    func stop() {
        store.stop()
        service.remove(hostID: Self.hostID)
    }

    /// Short polling for asynchronous event handling; fails the test after about five seconds.
    func waitUntil(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for fixture condition", sourceLocation: sourceLocation)
        throw AnnexTransportError.disconnected
    }

    /// Emits a resync and waits for the catalog refresh it schedules, so new capabilities apply.
    /// It follows the service's own events, subscribed before the resync: the host goes synchronizing, then
    /// connected once the refresh has applied everything. Then it waits for the store to show that same host.
    /// Read counts or the store's view alone can't say this: the store may still show the connection from before.
    func refreshCatalog(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let events = service.events()
        await transport.emit(.resyncRequired(.reconnected))
        let watcher = Task { @MainActor () -> CompanionHost? in
            var synchronizing = false
            for await event in events {
                guard case .hosts(let hosts) = event, let host = hosts.first(where: { $0.id == Self.hostID }) else { continue }
                if host.connection == .synchronizing { synchronizing = true }
                else if synchronizing, host.connection == .connected { return host }
            }
            return nil
        }
        let timeout = Task { try await Task.sleep(for: .seconds(5)); watcher.cancel() }
        let refreshed = await watcher.value
        timeout.cancel()
        guard let refreshed else {
            Issue.record("Timed out waiting for the catalog refresh", sourceLocation: sourceLocation)
            throw AnnexTransportError.disconnected
        }
        try await waitUntil({ host == refreshed }, sourceLocation: sourceLocation)
    }

    /// A chat snapshot for `session` with one assistant message, so commands have a session to address.
    static func chatSnapshot(session: String = "s1", events extra: [AnnexJSON] = [], fields: [String: AnnexJSON] = [:]) -> AnnexJSON {
        var snapshot: [String: AnnexJSON] = [
            "sessionId": .string(session), "state": .string("idle"),
            "events": .array([chatEvent(session, sequence: 1, type: "agent_message", data: ["messageId": .string("hello"), "text": .string("Hello")])] + extra),
            "capabilities": .object(["chat": .bool(true)]),
        ]
        snapshot.merge(fields) { _, new in new }
        return .object(snapshot)
    }

    static func chatEvent(_ session: String, sequence: Int64, type: String, data: [String: AnnexJSON]) -> AnnexJSON {
        .object(["sessionId": .string(session), "seq": .integer(sequence), "type": .string(type), "data": .object(data)])
    }

    /// Loads the agent's chat so commands addressed to its session can be sent.
    func loadSession(_ snapshot: AnnexJSON = chatSnapshot()) async throws {
        await transport.setRead("chat", snapshot)
        _ = try await service.history(for: target)
    }

    func snapshotEvent(_ fields: [String: AnnexJSON]) -> AnnexTransportEvent {
        var payload: [String: AnnexJSON] = [
            "projects": .array([.object(["id": .string("project"), "name": .string("Project")])]),
            "agents": .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])])]),
        ]
        payload.merge(fields) { _, new in new }
        return .message(.init(type: "snapshot", payload: .object(payload)))
    }
}

/// The text of a service error, for asserting on the message the user sees.
@MainActor func serviceErrorText(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil }
    catch let error as CompanionServiceError { return error.errorDescription }
    catch { return "\(type(of: error)): \(error)" }
}

/// The case of a service error, without its text.
enum ServiceErrorKind: Equatable { case unavailable, rejected, uncertain, other, none }
@MainActor func serviceErrorKind(_ body: () async throws -> Void) async -> ServiceErrorKind {
    do { try await body(); return .none }
    catch let error as CompanionServiceError {
        switch error { case .unavailable: return .unavailable; case .rejected: return .rejected; case .uncertain: return .uncertain }
    } catch { return .other }
}
