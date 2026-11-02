import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Real AnnexTransport + live service, with only the network replaced. Counts sockets and HTTP reads
/// rather than equating service.connect() calls with socket opens.
private actor ForegroundSocket: AnnexWebSocket {
    private var initial = true
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var closeCount = 0
    func receive() async throws -> Data {
        if initial {
            initial = false
            return Data(#"{"type":"snapshot","payload":{"lastSeq":0,"projects":[],"agents":{}}}"#.utf8)
        }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func send(_ data: Data) {}
    func ping() {}
    func close() {
        guard closeCount == 0 else { return }
        closeCount = 1; pending?.resume(throwing: AnnexTransportError.disconnected); pending = nil
    }
}

private actor ForegroundIO: AnnexIO {
    let identity = AnnexPairingIdentity()
    private(set) var paths: [String] = []
    private(set) var sockets: [ForegroundSocket] = []
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        let path = request.url!.path
        paths.append(path)
        let value: AnnexJSON
        if path.hasSuffix("/identity") {
            value = try .object(["publicKey": .string(identity.publicKeyBase64), "fingerprint": .string(AnnexPairingIdentity.fingerprint(publicKeyBase64: identity.publicKeyBase64))])
        } else if path.hasSuffix("/capabilities") {
            value = .object(["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true), "commands": .array([]),
                             "idempotency": .object(["scope": .string("s"), "maxEntries": .integer(1), "ttlMs": .integer(1)])])
        } else if path.hasSuffix("/projects") {
            value = .array((1...13).map { .object(["id": .string("p\($0)"), "name": .string("Project \($0)")]) })
        } else { value = .array([]) }
        return try AnnexHTTPResponse(status: 200, data: JSONEncoder().encode(value))
    }
    func openWebSocket(_ request: URLRequest) -> any AnnexWebSocket {
        let socket = ForegroundSocket(); sockets.append(socket); return socket
    }
}

@MainActor @Suite(.serialized) struct CompanionForegroundConnectionTests {
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for foreground connection"); throw AnnexTransportError.disconnected
    }

    @Test(arguments: [false, true]) func oneForegroundOpensOneSocket(relocate: Bool) async throws {
        let io = ForegroundIO()
        let hostID = try AnnexPairingIdentity.fingerprint(publicKeyBase64: io.identity.publicKeyBase64)
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let credentials = MemoryAnnexCredentialStore()
        await credentials.save(try AnnexCredential(bearerToken: "fixture-only"), for: hostID)
        let transport = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry())
        let service = CompanionLiveService()
        let store = CompanionStore(service: service); store.start()
        await service.register(.init(host: host, alias: "Fixture", transport: transport))
        try await wait { store.hosts.first?.connection == .connected }
        await service.suspend()
        let before = await io.paths.count
        if relocate {
            // Registry.relocate creates a replacement transport after disconnecting the old one.
            let replacement = AnnexTransport(host: host, credentials: credentials, io: io, telemetry: AnnexTelemetry())
            service.prepareResume = {
                await service.register(.init(host: host, alias: "Moved", transport: replacement))
                return [hostID]
            }
        }
        await service.resume()
        try await wait { store.hosts.first?.connection == .connected }
        let paths = Array(await io.paths.dropFirst(before))
        let sockets = await io.sockets
        #expect(sockets.count == 2, "Exactly one initial socket and one foreground socket")
        #expect(await sockets[0].closeCount == 1)
        #expect(await sockets[1].closeCount == 0)
        #expect(paths.filter { $0.hasSuffix("/identity") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/capabilities") }.count == 2, "One transport negotiation plus one service catalog read")
        #expect(paths.filter { $0.hasSuffix("/projects") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/agents") }.count == 13)
        #expect(paths.count == 17)
        store.stop(); await service.suspend(); service.remove(hostID: hostID)
    }
}
