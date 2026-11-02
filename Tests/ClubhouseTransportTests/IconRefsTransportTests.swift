import Foundation
import Testing
@testable import ClubhouseTransport

private actor IconSocket: AnnexWebSocket {
    var initial = true
    var pending: CheckedContinuation<Data, Error>?
    var sent: [Data] = []
    func receive() async throws -> Data {
        if initial { initial = false; return Data(#"{"type":"snapshot","epoch":"epoch","payload":{"lastSeq":0}}"#.utf8) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) { sent.append(data) }
    func ping() {}
    func close() { pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil }
}
private actor IconTransportIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    var enabled = true
    var sockets: [IconSocket] = []
    var opens: [URLRequest] = [], requests: [URLRequest] = [], limits: [Int] = []
    func setEnabled(_ value: Bool) { enabled = value }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        let value: AnnexJSON
        if request.url!.path.hasSuffix("/identity") {
            value = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if request.url!.path.contains("/icons/") {
            let etag = "\"" + String(repeating: "a", count: 64) + "\""
            return .init(status: request.value(forHTTPHeaderField: "If-None-Match") == etag ? 304 : 200, data: Data(), contentType: "image/png", etag: etag)
        } else {
            var fields: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true), "commands": .array([]), "idempotency": .object(["scope": .string("peer"), "maxEntries": .integer(10), "ttlMs": .integer(3600000)])]
            if enabled { fields["iconRefs"] = .object(["version": .integer(1)]) }
            value = .object(fields)
        }
        return try .init(status: 200, data: JSONEncoder().encode(value))
    }
    func perform(_ request: URLRequest, maximumBytes: Int) throws -> AnnexHTTPResponse { limits.append(maximumBytes); return try perform(request) }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket { opens.append(request); let socket = IconSocket(); sockets.append(socket); return socket }
}
private actor IconBindings {
    var values: [Bool] = []
    func add(_ value: Bool) { values.append(value) }
}
@Test func iconOptInIsRebuiltEveryConnectionIndependentOfTelemetry() async throws {
    let io = IconTransportIO(), id = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: id, verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore(); await credentials.save(try AnnexCredential(bearerToken: "test-only"), for: id)
    let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry())
    let bindings = IconBindings(), events = await transport.events()
    let observer = Task { for try await event in events { if case .message(let frame) = event, let value = frame.iconReferencesEnabled { await bindings.add(value) } } }
    for index in 0..<3 {
        if index == 2 { await io.setEnabled(false) }
        try await transport.connect()
        for _ in 0..<2000 { if await bindings.values.count == index + 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await bindings.values.last == (index < 2))
        let request = try #require(await io.opens.last)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "client", value: "mobile")))
        #expect(query.contains(.init(name: "iconRefs", value: "1")) == (index < 2))
        if index < 2 {
            let version = String(repeating: "a", count: 64)
            let response = try await transport.icon(kind: "agent", id: "a/b?", version: version, ifNoneMatch: "\"" + version + "\"")
            #expect(response.status == 304); #expect(response.etag == "\"" + version + "\"")
            #expect(await io.limits.last == 73728)
            #expect(await io.requests.last?.url?.absoluteString.contains("a%2Fb%3F?v=") == true)
        }
        let messages = await io.sockets.last!.sent.compactMap { try? JSONDecoder().decode(AnnexJSON.self, from: $0) }
        #expect(!messages.contains { $0["type"]?.string == "telemetry:hello" })
        await transport.disconnect()
    }
    observer.cancel()
    let hostile = try JSONDecoder().decode(AnnexEnvelope.self, from: Data(#"{"type":"snapshot","iconReferencesEnabled":true}"#.utf8))
    #expect(hostile.iconReferencesEnabled == nil)
}
