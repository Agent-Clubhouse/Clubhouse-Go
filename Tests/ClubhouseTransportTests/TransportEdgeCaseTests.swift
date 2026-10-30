import Foundation
import Testing
@testable import ClubhouseTransport

// Small, synchronous edges of the transport vocabulary: command encodings, trace context
// parsing, pairing response validation, Bonjour resolution failures and OTLP attributes.

// MARK: Commands

private func encode(_ kind: AnnexCommand.Kind, id: String = "cmd", epoch: String = "epoch1") throws -> AnnexJSON {
    try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: id, epoch: epoch, kind: kind).encoded())
}

@Test func permissionAndQuestionAnswersTargetTheRequest() throws {
    let permission = try encode(.permission(agentID: "a", sessionID: "s", requestID: "r1", optionID: "allow_always"))
    #expect(permission["type"] == .string("chat.permission"))
    #expect(permission["agentId"] == .string("a"))
    #expect(permission["sessionId"] == .string("s"))
    #expect(permission["requestId"] == .string("r1"))
    #expect(permission["optionId"] == .string("allow_always"))
    let answers: [String: AnnexJSON] = ["q1": .array([.string("Yes")]), "q2": .string("free text")]
    let question = try encode(.question(agentID: "a", sessionID: "s", requestID: "r2", answers: answers))
    #expect(question["requestId"] == .string("r2"))
    #expect(question["answers"] == .object(answers))
}

@Test func spawnCarriesOptionalModelAndOrchestratorOnlyWhenSet() throws {
    let bare = try encode(.spawn(projectID: "p", prompt: "fix it"))
    #expect(bare["type"] == .string("agent.spawn"))
    #expect(bare["projectId"] == .string("p"))
    #expect(bare["prompt"] == .string("fix it"))
    #expect(bare["model"] == nil)
    #expect(bare["orchestrator"] == nil)
    #expect(bare["agentId"] == nil)
    let full = try encode(.spawn(projectID: "p", prompt: "go", model: "opus", orchestrator: "claude-code"))
    #expect(full["model"] == .string("opus"))
    #expect(full["orchestrator"] == .string("claude-code"))
}

@Test func commandIdentityMustBeBounded() throws {
    let kind = AnnexCommand.Kind.stop(agentID: "a")
    for (id, epoch) in [("", "e"), (String(repeating: "x", count: 129), "e"), ("c", ""), ("c", String(repeating: "e", count: 129))] {
        #expect(throws: AnnexTransportError.malformedResponse) { try encode(kind, id: id, epoch: epoch) }
    }
    #expect(try encode(kind, id: String(repeating: "x", count: 128))["commandId"]?.string?.count == 128)
}

// MARK: Trace context

@Test func traceContextFromJSONNeedsAStringParentAndOptionalStringState() {
    let parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    #expect(AnnexTraceContext.from(nil) == nil)
    #expect(AnnexTraceContext.from(.object([:])) == nil)
    #expect(AnnexTraceContext.from(.object(["traceparent": .integer(1)])) == nil)
    #expect(AnnexTraceContext.from(.object(["traceparent": .string("garbage")])) == nil)
    #expect(AnnexTraceContext.from(.object(["traceparent": .string(parent)]))?.traceparent == parent)
    #expect(AnnexTraceContext.from(.object(["traceparent": .string(parent), "tracestate": .null])) != nil)
    #expect(AnnexTraceContext.from(.object(["traceparent": .string(parent), "tracestate": .integer(3)])) == nil)
    #expect(AnnexTraceContext.from(.object(["traceparent": .string(parent), "tracestate": .string("vendor=ok")])) != nil)
    #expect(AnnexTraceContext.from(.object(["traceparent": .string(parent), "tracestate": .string("bad state")])) == nil)
    // Vendor state is validated but never retained.
    #expect(AnnexTraceContext.from(.object(["traceparent": .string(parent), "tracestate": .string("vendor=ok")]))?.tracestate == nil)
}

// MARK: Pairing

private actor OneResponseIO: AnnexIO {
    let response: AnnexHTTPResponse
    init(_ response: AnnexHTTPResponse) { self.response = response }
    func perform(_ request: URLRequest) -> AnnexHTTPResponse { response }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}
/// RSA key generation costs about a second; one throwaway identity serves every pairing test here.
private let edgeIdentity = Result { try AnnexClientIdentity.ephemeral() }

@Test func pairingRejectsProtocolModeAndCertificateMismatches() async throws {
    let server = AnnexPairingIdentity()
    let fingerprint = try AnnexPairingIdentity.fingerprint(publicKeyBase64: server.publicKeyBase64)
    let pin = String(repeating: "ab", count: 32)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: fingerprint,
                                   verifiedCertificatePin: AnnexCertificatePin(sha256: pin))
    func body(version: Int = 1, mode: String = "session", certificate: String = pin) throws -> Data {
        try JSONEncoder().encode(AnnexJSON.object(["token": .string("fake-only"), "publicKey": .string(server.publicKeyBase64),
            "fingerprint": .string(fingerprint), "alias": .string("Desk"), "tlsCertificateFingerprint": .string(certificate),
            "mobileProtocolVersion": .integer(Int64(version)), "pairingMode": .string(mode)]))
    }
    for data in [try body(version: 2), try body(mode: "persistent"), try body(certificate: String(repeating: "cd", count: 32))] {
        let store = MemoryAnnexCredentialStore()
        let client = try AnnexPairingClient(host: host, clientIdentity: edgeIdentity.get(), credentials: store, io: OneResponseIO(AnnexHTTPResponse(status: 200, data: data)))
        await #expect(throws: AnnexTransportError.identityMismatch) { try await client.pair(pin: "123456", alias: "Phone") }
        #expect(await store.credential(for: host.hostID) == nil)
    }
    let malformed = try AnnexPairingClient(host: host, clientIdentity: edgeIdentity.get(), credentials: MemoryAnnexCredentialStore(),
                                           io: OneResponseIO(AnnexHTTPResponse(status: 200, data: Data("{}".utf8))))
    await #expect(throws: AnnexTransportError.malformedResponse) { try await malformed.pair(pin: "123456", alias: "Phone") }
    await #expect(throws: AnnexTransportError.malformedResponse) { try await malformed.pair(pin: "", alias: "Phone") }
    let wrongPIN = try AnnexPairingClient(host: host, clientIdentity: edgeIdentity.get(), credentials: MemoryAnnexCredentialStore(),
                                          io: OneResponseIO(AnnexHTTPResponse(status: 401, data: Data())))
    await #expect(throws: AnnexTransportError.unauthorized) { try await wrongPIN.pair(pin: "000000", alias: "Phone") }
}

@Test func clientIdentityNeverPrintsKeyMaterial() throws {
    let identity = try edgeIdentity.get()
    #expect(String(describing: identity) == "AnnexClientIdentity(<redacted>)")
    #expect(String(reflecting: identity) == "AnnexClientIdentity(<redacted>)")
}

// MARK: Discovery

private final class EdgeBrowser: NetServiceBrowser {
    override func searchForServices(ofType type: String, inDomain domain: String) {}
    override func stop() {}
}
private final class EdgeService: NetService {
    var stopped = false
    override var hostName: String? { "edge.local." }
    override var port: Int { 8443 }
    override func resolve(withTimeout timeout: TimeInterval) {}
    override func stop() { stopped = true }
}

@Test @MainActor func unresolvableServiceIsForgottenAndCannotLaterResolve() async throws {
    let browser = EdgeBrowser()
    let discovery = AnnexDiscovery(makeBrowser: { browser })
    discovery.start()
    let failing = EdgeService(domain: "local.", type: "_clubhouse-annex._tcp.", name: "Failing", port: 8443)
    let working = EdgeService(domain: "local.", type: "_clubhouse-annex._tcp.", name: "Working", port: 8443)
    discovery.netServiceBrowser(browser, didFind: failing, moreComing: true)
    discovery.netServiceBrowser(browser, didFind: working, moreComing: false)
    discovery.netServiceDidResolveAddress(working)
    #expect(discovery.discovered.map(\.name) == ["Working"])
    discovery.netService(failing, didNotResolve: [NetService.errorCode: NSNumber(value: -72003)])
    #expect(failing.stopped)
    // A late success for the failed service is ignored; the other host is untouched.
    discovery.netServiceDidResolveAddress(failing)
    #expect(discovery.discovered.map(\.name) == ["Working"])
    // A failure report for a service this browser never found changes nothing.
    let stranger = EdgeService(domain: "local.", type: "_clubhouse-annex._tcp.", name: "Stranger", port: 8443)
    discovery.netService(stranger, didNotResolve: [:])
    #expect(!stranger.stopped)
    #expect(discovery.discovered.count == 1)
    discovery.stop()
    #expect(discovery.discovered.isEmpty)
}

@Test @MainActor func defaultDiscoveryIsIdleUntilStarted() async {
    let discovery = AnnexDiscovery()
    var states = discovery.states().makeAsyncIterator()
    let initial = await states.next()
    #expect(initial?.isSearching == false)
    #expect(discovery.discovered.isEmpty)
}

// MARK: Diagnostics

@Test @MainActor func captureModeLabelsAndClearingRecords() throws {
    #expect(AnnexDiagnosticCaptureMode.allCases.map(\.label) == ["Off", "This session", "Always"])
    let suite = "annex-edge-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let telemetry = AnnexTelemetry()
    let settings = AnnexDiagnosticSettings(defaults: defaults, telemetry: telemetry)
    settings.select(.session)
    telemetry.record(.pairing)
    #expect(!telemetry.snapshot().records.isEmpty)
    let revision = settings.revision
    settings.clear()
    #expect(telemetry.snapshot().records.isEmpty)
    #expect(settings.revision != revision)
}

@Test func OTLPExportKeepsOnlyKnownMeasurementsAndIdentifiers() throws {
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let attempt = UUID()
    let span = telemetry.begin(.connection)
    span.number(.attempt, 3.5)
    span.number(.backoffMs, 5_000_000_000) // clamped
    span.number(.dnsMs, .infinity) // never recorded
    span.identifier(.connectionAttemptID, attempt)
    span.fail(.timeout)
    span.end()
    let object = try JSONDecoder().decode(AnnexJSON.self, from: AnnexOTLPJSON.encode(telemetry.snapshot().records))
    guard case .array(let resources) = object["resourceSpans"], case .array(let scopes) = resources.first?["scopeSpans"],
          case .array(let spans) = scopes.first?["spans"], case .array(let attributes) = spans.first?["attributes"] else {
        Issue.record("Invalid OTLP shape"); return
    }
    var values: [String: AnnexJSON] = [:]
    for attribute in attributes { if let key = attribute["key"]?.string { values[key] = attribute["value"] } }
    // Whole doubles come back from JSON as integers, so compare numerically.
    func double(_ key: String) -> Double? {
        switch values[key]?["doubleValue"] { case .number(let value): value; case .integer(let value): Double(value); default: nil }
    }
    #expect(double("attempt") == 3.5)
    #expect(double("backoffMs") == 1_000_000_000)
    #expect(values["dnsMs"] == nil)
    #expect(values["annex.connection.attempt.id"] == .object(["stringValue": .string(attempt.uuidString.lowercased())]))
    #expect(values["failure"] == .object(["stringValue": .string("timeout")]))
    #expect(spans.first?["status"]?["code"] == .integer(2))
}

@Test func terminalCapabilityHasUsableDefaults() {
    let terminal = AnnexCapabilities.Terminal(projectShell: true, agentShell: false, agentAttach: true)
    #expect(terminal.version == 1)
    #expect(terminal.maxShellsPerConnection == 8)
    #expect(terminal.maxInputLength == AnnexCapabilities.Terminal.defaultMaxInputLength)
    #expect(!terminal.agentShell)
}
