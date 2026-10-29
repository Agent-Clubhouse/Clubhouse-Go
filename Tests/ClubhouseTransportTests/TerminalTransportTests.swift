import Foundation
import Testing
@testable import ClubhouseTransport

// MARK: Input chunking

@Test func shortInputIsSentWhole() {
    #expect(AnnexTerminalInput.chunks("ls -la\r") == ["ls -la\r"])
    #expect(AnnexTerminalInput.chunks("").isEmpty)
}

@Test func longInputIsSplitUnderTheDesktopCap() {
    let text = String(repeating: "a", count: 150_000)
    let chunks = AnnexTerminalInput.chunks(text)
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.utf16.count <= 65_536 })
    #expect(chunks.joined() == text)
}

@Test func chunksNeverSplitASurrogatePair() {
    // Each emoji is two UTF-16 units; an odd cap would cut one in half if chunking counted units blindly.
    let text = "x" + String(repeating: "😀", count: 20)
    let chunks = AnnexTerminalInput.chunks(text, maxLength: 5)
    #expect(chunks.joined() == text)
    #expect(chunks.allSatisfy { $0.utf16.count <= 5 })
    #expect(chunks.allSatisfy { String($0.unicodeScalars).unicodeScalars.allSatisfy { $0.value != 0xFFFD } })
    #expect(chunks.first == "x😀😀")
}

// MARK: Attach stitching

@Test func outputAtOrBeforeTheSnapshotIsDropped() {
    #expect(AnnexTerminalOutput.unseen("old", outputSeq: 10, snapshotSeq: 10) == nil)
    #expect(AnnexTerminalOutput.unseen("old", outputSeq: 4, snapshotSeq: 10) == nil)
}

@Test func outputAfterTheSnapshotIsKeptAndAStraddlingFrameIsTrimmed() {
    #expect(AnnexTerminalOutput.unseen("new", outputSeq: 13, snapshotSeq: 10) == "new")
    #expect(AnnexTerminalOutput.unseen("abcdef", outputSeq: 12, snapshotSeq: 10) == "ef")
    #expect(AnnexTerminalOutput.unseen("any", outputSeq: nil, snapshotSeq: 10) == "any")
    #expect(AnnexTerminalOutput.unseen("any", outputSeq: 3, snapshotSeq: nil) == "any")
}

@Test func aStraddleInsideASurrogatePairStartsAtTheNextScalar() {
    // "a😀b" is 4 units; the last 2 units are the emoji's low half and "b".
    #expect(AnnexTerminalOutput.unseen("a😀b", outputSeq: 4, snapshotSeq: 2) == "b")
    #expect(AnnexTerminalOutput.unseen("a😀b", outputSeq: 4, snapshotSeq: 1) == "😀b")
}

// MARK: Frames and capability

@Test func framesMatchTheDesktopProtocol() throws {
    func decode(_ frame: AnnexTerminalFrame) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: frame.encoded()) }
    let project = try decode(.spawnShell(sessionID: "s1", projectID: "p1", agentID: nil))
    #expect(project["type"]?.string == "pty:spawn-shell")
    #expect(project["payload"] == .object(["sessionId": .string("s1"), "projectId": .string("p1")]))
    let agent = try decode(.spawnShell(sessionID: "s1", projectID: "p1", agentID: "a1"))
    #expect(agent["payload"]?["agentId"]?.string == "a1")
    #expect(try decode(.input(id: "s1", data: "x"))["payload"] == .object(["agentId": .string("s1"), "data": .string("x")]))
    #expect(try decode(.resize(id: "s1", cols: 80, rows: 24))["payload"]?["cols"] == .integer(80))
    #expect(try decode(.close(sessionID: "s1"))["type"]?.string == "pty:close")
    #expect(try decode(.attach(agentID: "a1"))["payload"] == .object(["agentId": .string("a1")]))
    #expect(AnnexTerminalFrame.id(of: AnnexEnvelope(type: "error", payload: .object(["op": .string("pty:input"), "agentId": .string("s1")]))) == "s1")
}

private func capabilities(_ terminal: String?) throws -> AnnexCapabilities {
    let block = terminal.map { #","terminal":\#($0)"# } ?? ""
    let json = #"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[],"idempotency":{"scope":"s","maxEntries":1,"ttlMs":1}\#(block)}"#
    return try JSONDecoder().decode(AnnexCapabilities.self, from: Data(json.utf8))
}

@Test func terminalCapabilityGatesTerminals() throws {
    #expect(try capabilities(nil).supportsTerminal == false)
    let full = try capabilities(#"{"version":1,"projectShell":true,"agentShell":true,"agentAttach":false,"maxShellsPerConnection":8,"maxInputLength":4096}"#)
    #expect(full.supportsTerminal)
    #expect(full.terminal?.agentAttach == false)
    #expect(full.terminal?.maxInputLength == 4096)
    // A malformed or future block grants nothing, without failing the rest of the document.
    #expect(try capabilities(#"{"version":"one","projectShell":"yes"}"#).supportsTerminal == false)
    #expect(try capabilities(#"{"version":2,"projectShell":true}"#).supportsTerminal == false)
    #expect(try capabilities(#"{"version":1,"projectShell":true}"#).terminal?.maxInputLength == 65_536)
}

// MARK: Transport

private actor TerminalSocket: AnnexWebSocket {
    private var messages = [Data(#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#.utf8)]
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var sent: [AnnexJSON] = []
    func receive() async throws -> Data {
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ json: String) {
        let data = Data(json.utf8)
        if let pending { self.pending = nil; pending.resume(returning: data) } else { messages.append(data) }
    }
    func send(_ data: Data) throws { sent.append(try JSONDecoder().decode(AnnexJSON.self, from: data)) }
    func ping() {}
    func close() { pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil }
}

private actor TerminalIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    let terminal: Bool
    let socket = TerminalSocket()
    init(terminal: Bool) { self.terminal = terminal }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let body: AnnexJSON
        if request.url?.path.hasSuffix("identity") == true {
            body = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else {
            var caps: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("e"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true),
                                             "commands": .array([]), "idempotency": .object(["scope": .string("s"), "maxEntries": .integer(1), "ttlMs": .integer(3_600_000)])]
            if terminal {
                caps["terminal"] = .object(["version": .integer(1), "projectShell": .bool(true), "agentShell": .bool(true), "agentAttach": .bool(true),
                                            "maxShellsPerConnection": .integer(8), "maxInputLength": .integer(4)])
            }
            body = .object(caps)
        }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(body))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket { socket }
}

private func connected(terminal: Bool) async throws -> (AnnexTransport, TerminalIO, AsyncThrowingStream<AnnexTransportEvent, Error>, AsyncStream<AnnexTerminalEvent>) {
    let io = TerminalIO(terminal: terminal)
    let fingerprint = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: fingerprint,
                                    verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-only"), for: host.hostID)
    let transport = AnnexTransport(host: host, credentials: credentials, io: io)
    let events = await transport.events()
    let terminalEvents = await transport.terminalEvents()
    try await transport.connect()
    for try await event in events { if case .message(let envelope) = event, envelope.type == "snapshot" { break } }
    return (transport, io, events, terminalEvents)
}

@Test func terminalFramesTravelOnTheirOwnStream() async throws {
    let (transport, io, events, terminalEvents) = try await connected(terminal: true)
    await io.socket.push(#"{"type":"pty:data","payload":{"agentId":"s1","data":"hi","outputSeq":2}}"#)
    await io.socket.push(#"{"type":"error","payload":{"message":"session_not_found","op":"pty:close","sessionId":"s1"}}"#)
    await io.socket.push(#"{"type":"agent:status","payload":{"id":"a1","status":"running"}}"#)
    var frames: [String] = []
    for await event in terminalEvents {
        if case .frame(let envelope) = event { frames.append(envelope.type) }
        if frames.count == 2 { break }
    }
    #expect(frames == ["pty:data", "error"])
    // The chat stream sees the next ordinary message, and no terminal frames.
    for try await event in events {
        if case .message(let envelope) = event, envelope.type != "snapshot" { #expect(envelope.type == "agent:status"); break }
    }
    await transport.disconnect()
}

@Test func sendTerminalSplitsInputUnderTheAdvertisedCap() async throws {
    let (transport, io, _, _) = try await connected(terminal: true)
    try await transport.sendTerminal(.input(id: "s1", data: "abcdefghij"))
    let inputs = await io.socket.sent.filter { $0["type"]?.string == "pty:input" }.compactMap { $0["payload"]?["data"]?.string }
    #expect(inputs == ["abcd", "efgh", "ij"])
    await transport.disconnect()
    await #expect(throws: AnnexTransportError.self) { try await transport.sendTerminal(.input(id: "s1", data: "x")) }
}

@Test func sendTerminalNeedsTheCapability() async throws {
    let (transport, _, _, _) = try await connected(terminal: false)
    await #expect(throws: AnnexTransportError.unsupportedCapability("terminal")) {
        try await transport.sendTerminal(.spawnShell(sessionID: "s1", projectID: "p1", agentID: nil))
    }
    await transport.disconnect()
}
