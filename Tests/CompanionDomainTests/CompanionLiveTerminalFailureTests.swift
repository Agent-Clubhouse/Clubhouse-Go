import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// A terminal transport whose sends can fail, and whose terminal stream can end underneath the channel.
private actor FailingTerminalTransport: AnnexTransporting {
    private var continuation: AsyncStream<AnnexTerminalEvent>.Continuation?
    private(set) var sent: [AnnexTerminalFrame] = []
    private(set) var subscriptions = 0
    private var sendErrors: [AnnexTransportError] = []
    func failNextSend(_ error: AnnexTransportError) { sendErrors.append(error) }
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> { AsyncThrowingStream { _ in } }
    func connect() async throws {}
    func disconnect() async {}
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON { .null }
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt { throw AnnexTransportError.disconnected }
    func terminalEvents() async -> AsyncStream<AnnexTerminalEvent> {
        subscriptions += 1
        let (stream, continuation) = AsyncStream<AnnexTerminalEvent>.makeStream()
        self.continuation = continuation
        continuation.yield(.connection(.connected))
        return stream
    }
    func sendTerminal(_ frame: AnnexTerminalFrame) async throws {
        if !sendErrors.isEmpty { throw sendErrors.removeFirst() }
        sent.append(frame)
    }
    func push(_ type: String, _ payload: AnnexJSON) { continuation?.yield(.frame(AnnexEnvelope(type: type, payload: payload))) }
    /// The transport drops a terminal stream that falls behind.
    func endStream() { continuation?.finish() }
}

@Suite @MainActor struct CompanionLiveTerminalFailureTests {
    private let project = CompanionProjectTarget(hostID: "h", projectID: "p")

    private func first(_ stream: AsyncStream<CompanionTerminalChannelEvent>, _ count: Int = 1) async -> [CompanionTerminalChannelEvent] {
        var events: [CompanionTerminalChannelEvent] = []
        for await event in stream {
            events.append(event)
            if events.count == count { break }
        }
        return events
    }

    @Test(arguments: [
        (AnnexTransportError.unsupportedCapability("terminal"), CompanionTerminalChannelEvent.failed(CompanionTerminalAvailability.updateDesktop)),
        (.disconnected, .connectionLost),
        (.rateLimited(code: nil, retryAfterSeconds: nil), .failed("The desktop is busy. Try again in a moment.")),
    ])
    func aShellThatCantBeRequestedSaysWhy(error: AnnexTransportError, expected: CompanionTerminalChannelEvent) async {
        let transport = FailingTerminalTransport()
        let channel = CompanionLiveTerminalChannel(transport: transport, scope: .project(project), sessionID: "s1")
        let events = channel.events()
        await transport.failNextSend(error)
        await channel.open(cols: 80, rows: 24)
        #expect(await first(events) == [expected])
        #expect(await transport.sent.isEmpty)
        await channel.close()
    }

    @Test func anOpenShellFollowsThePhonesSizeAndClosesItsSession() async {
        let transport = FailingTerminalTransport()
        let channel = CompanionLiveTerminalChannel(transport: transport, scope: .project(project), sessionID: "s1")
        let events = channel.events()
        // Before the desktop acknowledges the shell, a resize is only remembered.
        await channel.open(cols: 80, rows: 24)
        await channel.resize(cols: 100, rows: 30)
        await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/repo")]))
        #expect(await first(events) == [.opened(cwd: "/repo", snapshot: nil, cols: nil, rows: nil)])
        await channel.resize(cols: 120, rows: 40)
        // A resize the desktop can't take is dropped quietly; the shell keeps running.
        await transport.failNextSend(.disconnected)
        await channel.resize(cols: 90, rows: 20)
        await channel.close()
        #expect(await transport.sent == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .resize(id: "s1", cols: 120, rows: 40),
                                         .close(sessionID: "s1")])
    }

    @Test func aDroppedTerminalStreamIsTakenAgainAndReportedLost() async throws {
        let transport = FailingTerminalTransport()
        let channel = CompanionLiveTerminalChannel(transport: transport, scope: .project(project), sessionID: "s1")
        let events = channel.events()
        await channel.open(cols: 80, rows: 24)
        await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1")]))
        await transport.endStream()
        #expect(await first(events, 2) == [.opened(cwd: nil, snapshot: nil, cols: nil, rows: nil), .connectionLost])
        for _ in 0..<1000 where await transport.subscriptions < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await transport.subscriptions == 2)
        await channel.close()
    }

    @Test func sendingInputPassesTheTransportsErrorThrough() async {
        let transport = FailingTerminalTransport()
        let channel = CompanionLiveTerminalChannel(transport: transport, scope: .agentPTY(.init(hostID: "h", projectID: "p", agentID: "agent")))
        await transport.failNextSend(.disconnected)
        await #expect(throws: AnnexTransportError.disconnected) { try await channel.send("ls\r") }
        // An agent's PTY keeps the desktop's size: resizes are never sent.
        await channel.resize(cols: 10, rows: 10)
        #expect(await transport.sent.isEmpty)
    }
}

@MainActor @Test func aNewSessionAbandonsTheOpenTurnAndTheObserverStaysBounded() {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let observer = CompanionStreamDiagnostics(telemetry: telemetry)
    let target = CompanionTarget(hostID: "host", projectID: "project", agentID: "agent")
    func event(_ session: String, _ seq: Int64, _ type: String) -> AnnexJSON {
        .object(["sessionId": .string(session), "seq": .integer(seq), "type": .string(type), "data": .object([:])])
    }
    observer.receive(event("one", 1, "turn_started"), target: target)
    observer.receive(event("two", 1, "turn_started"), target: target)
    #expect(telemetry.snapshot().records.map(\.failure) == [.abandoned])

    // Beyond 32 agents, the oldest cursor goes, finishing its open turn.
    for index in 0..<32 {
        observer.receive(event("s", 1, "turn_started"), target: .init(hostID: "host", projectID: "project", agentID: "other-\(index)"))
    }
    #expect(telemetry.snapshot().records.contains { $0.failure == .overflow })
    // Malformed events are ignored.
    observer.receive(.object(["sessionId": .string("s"), "seq": .integer(-1), "type": .string("turn_started")]), target: target)
    observer.receive(.object(["seq": .integer(1), "type": .string("turn_started")]), target: target)
}
