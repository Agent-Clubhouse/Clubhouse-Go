#if os(macOS)
import Testing
import Foundation
@testable import ClubhouseTransport

@Test func actualTLSRequiresExactPinPresentsBoundClientAndRejectsRedirects() async throws {
    let process = try FixtureProcess(arguments: [
        "node", try #require(Bundle.module.url(forResource: "tls-server", withExtension: "mjs", subdirectory: "Fixtures")).path
    ])
    defer { process.stop() }
    var line = Data()
    while let byte = try process.output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
        line.append(byte)
        guard line.count < 4096 else { throw AnnexTransportError.malformedResponse }
    }
    struct Fixture: Decodable { let port: UInt16; let pin: String }
    let fixture = try JSONDecoder().decode(Fixture.self, from: line)
    let endpoint = try AnnexEndpoint(host: "127.0.0.1", port: fixture.port)
    let hostID = "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef"
    let host = try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: hostID, verifiedCertificatePin: AnnexCertificatePin(sha256: fixture.pin))
    let observed = try await AnnexTrustProbe.inspect(endpoint: endpoint)
    #expect(observed == host.certificatePin)
    let client = try AnnexClientIdentity.ephemeral()
    let telemetry = AnnexTelemetry(); telemetry.setEnabled(true)
    let io = PinnedAnnexIO(host: host, clientIdentity: client, maximumResponseBytes: 1024, telemetry: telemetry)
    var request = URLRequest(url: try endpoint.url(path: ["identity"]))
    request.setValue("Bearer fake-only", forHTTPHeaderField: "Authorization")
    let response = try await io.perform(request)
    let body = try JSONDecoder().decode(AnnexJSON.self, from: response.data)
    #expect(response.status == 200)
    #expect(body["clientCN"]?.string == (try client.fingerprint))
    #expect(body["authorized"] == .bool(true))
    let propagated = try #require(body["traceparent"]?.string)
    #expect(AnnexTraceContext(traceparent: propagated) != nil)
    #expect(body["baggage"] == .null)
    #expect(body["tracestate"] == .null)
    #expect(telemetry.snapshot().records.contains { $0.operation == .http && $0.failure == .none })
    #expect(try AnnexCertificatePin(sha256: body["certificateFingerprint"]!.string!).sha256 == client.certificateFingerprint)
    let redirect = try await io.perform(URLRequest(url: endpoint.url(path: ["redirect"])))
    #expect(redirect.status == 302)
    let next = try await io.perform(request)
    #expect(try JSONDecoder().decode(AnnexJSON.self, from: next.data)["received"]?.integer == 3)
    await #expect(throws: AnnexTransportError.responseTooLarge) {
        try await io.perform(URLRequest(url: endpoint.url(path: ["large"])))
    }
    let wrongHost = try TrustedAnnexHost(endpoint: endpoint, verifiedHostID: hostID, verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "00", count: 32)))
    let wrongPin = PinnedAnnexIO(host: wrongHost, clientIdentity: client)
    await #expect(throws: Error.self) { try await wrongPin.perform(request) }
    let afterFailure = try await io.perform(request)
    #expect(try JSONDecoder().decode(AnnexJSON.self, from: afterFailure.data)["received"]?.integer == 5)
    // Both ways of framing an HTTP body enforce the same cap, without a retry.
    for chunked in [false, true] {
        func sized(_ count: Int) throws -> URLRequest {
            var query = [URLQueryItem(name: "bytes", value: String(count))]
            if chunked { query.append(.init(name: "chunked", value: "1")) }
            return URLRequest(url: try endpoint.url(path: ["sized"], query: query))
        }
        let boundary = try await io.perform(sized(1024))
        #expect(boundary.data.count == 1024)
        await #expect(throws: AnnexTransportError.responseTooLarge) { try await io.perform(sized(1025)) }
    }
    let iconIO = PinnedAnnexIO(host: host, clientIdentity: client, telemetry: AnnexTelemetry())
    for chunked in [false, true] {
        func iconSized(_ count: Int) throws -> URLRequest {
            URLRequest(url: try endpoint.url(path: ["sized"], query: [.init(name: "bytes", value: String(count))] + (chunked ? [.init(name: "chunked", value: "1")] : [])))
        }
        let exact = try await iconIO.perform(iconSized(73728), maximumBytes: 73728)
        #expect(exact.data.count == 73728)
        await #expect(throws: AnnexTransportError.responseTooLarge) { try await iconIO.perform(iconSized(73729), maximumBytes: 73728) }
        // The ordinary REST cap remains distinct and larger.
        #expect(try await iconIO.perform(iconSized(73729)).data.count == 73729)
    }
    // Full-event HTTP has its own cap; ordinary HTTP and WebSockets retain their configured limit.
    for chunked in [false, true] {
        let wholeRequest = URLRequest(url: try endpoint.url(path: ["sized"], query: [.init(name: "bytes", value: "2048")] + (chunked ? [.init(name: "chunked", value: "1")] : [])))
        #expect(try await io.performFullEvent(wholeRequest, maximumBytes: 2048).data.count == 2048)
        await #expect(throws: AnnexTransportError.responseTooLarge) { try await io.perform(wholeRequest) }
        await #expect(throws: AnnexTransportError.responseTooLarge) { try await io.performFullEvent(wholeRequest, maximumBytes: 2047) }
    }
    let fullIdentity = try await io.performFullEvent(request, maximumBytes: 4096)
    #expect(try JSONDecoder().decode(AnnexJSON.self, from: fullIdentity.data)["clientCN"]?.string == client.fingerprint)
    #expect(try await io.performFullEvent(URLRequest(url: endpoint.url(path: ["redirect"])), maximumBytes: 4096).status == 302)
    await #expect(throws: Error.self) { try await wrongPin.performFullEvent(request, maximumBytes: 4096) }
    let aboveSocketCap = URLRequest(url: try endpoint.url(path: ["sized"], query: [.init(name: "bytes", value: String(17 * 1024 * 1024))]))
    #expect(try await io.performFullEvent(aboveSocketCap, maximumBytes: AnnexFullEvent.maximumBytes).data.count == 17 * 1024 * 1024)
    let cancelled = Task { [request] in try await io.performFullEvent(request, maximumBytes: 4096) }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let overFullCap = URLRequest(url: try endpoint.url(path: ["sized"], query: [.init(name: "bytes", value: String(AnnexFullEvent.maximumBytes + 1))]))
    await #expect(throws: AnnexTransportError.responseTooLarge) { try await io.performFullEvent(overFullCap, maximumBytes: Int.max) }
    telemetry.setEnabled(false)
    request.setValue("injected-secret", forHTTPHeaderField: "baggage")
    request.setValue(propagated, forHTTPHeaderField: "traceparent")
    let disabled = try await io.perform(request)
    let disabledBody = try JSONDecoder().decode(AnnexJSON.self, from: disabled.data)
    #expect(disabledBody["traceparent"] == .null)
    #expect(disabledBody["baggage"] == .null)
    var plaintext = request
    plaintext.url = URL(string: "http://127.0.0.1:\(fixture.port)/identity")
    await #expect(throws: AnnexTransportError.invalidEndpoint) { try await io.perform(plaintext) }
}
#endif
