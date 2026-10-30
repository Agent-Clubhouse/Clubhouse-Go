import Foundation
import Testing
@testable import ClubhouseTransport

/// The desktop's canonical Annex mobile fixtures, vendored in `Tests/Fixtures/AnnexContract/` by
/// `scripts/sync-annex-fixtures.sh`. The desktop writes them from its real annex-server code, so these tests check
/// the phone against what the desktop actually sends and accepts, not against the phone's own fakes.
enum AnnexContract {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/AnnexContract", directoryHint: .isDirectory)

    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appending(path: name)) }
    static func json(_ name: String) throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: data(name)) }
    /// Every fixture the desktop wrote, from its index.
    static func files() throws -> [String] { try json("index.json")["files"].list.compactMap(\.string) }
    /// The `cases` of a fixture file.
    static func cases(_ name: String) throws -> [AnnexJSON] { try json(name)["cases"].list }
    static func encode(_ value: AnnexJSON) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    /// The HTTP response a fixture recorded, as the transport's IO returns it.
    static func response(_ value: AnnexJSON?, retryAfter: Int? = nil) throws -> AnnexHTTPResponse {
        let status = Int(value?["status"]?.integer ?? 0)
        let body = value?["body"] ?? .null
        return AnnexHTTPResponse(status: status, data: body == .null ? Data() : try encode(body), retryAfter: retryAfter)
    }
}

extension Optional where Wrapped == AnnexJSON {
    var list: [AnnexJSON] { if case .array(let values)? = self { values } else { [] } }
    var keys: Set<String> { if case .object(let values)? = self { Set(values.keys) } else { [] } }
}

/// Serves recorded responses in order; every request is kept for inspection.
actor AnnexContractIO: AnnexIO {
    private var responses: [AnnexHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [AnnexHTTPResponse]) { self.responses = responses }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.networkConnectionLost) }
        return responses.removeFirst()
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}

func annexContractTransport(_ io: AnnexContractIO) async throws -> AnnexTransport {
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 7432), verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef",
                                   verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fixture-token"), for: host.hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io)
}
