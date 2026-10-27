import Testing
import Foundation
@testable import ClubhouseTransport

// The project root's read-only Changes (#158): the desktop's existing `git/info` and `git/diff` routes.

private actor RouteIO: AnnexIO {
    var requests: [URLRequest] = []
    var responses: [AnnexHTTPResponse]
    init(_ responses: [String]) { self.responses = responses.map { AnnexHTTPResponse(status: 200, data: Data($0.utf8)) } }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AnnexTransportError.malformedResponse }
        return responses.removeFirst()
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
}

private func transport(_ io: RouteIO) async throws -> AnnexTransport {
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef",
                                    verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-token"), for: host.hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io)
}

@Test func gitStatusAndDiffUseTheProjectRoutesWithEncodedIDsAndPaths() async throws {
    let io = RouteIO(["{}", "{}", "{}"])
    let transport = try await transport(io)
    _ = try await transport.read(.gitStatus(projectID: "proj/1"))
    _ = try await transport.read(.gitDiff(projectID: "proj/1", filePath: "src/a b&c=d.ts", staged: false))
    _ = try await transport.read(.gitDiff(projectID: "p", filePath: "notes/c++.md", staged: true))
    let urls = await io.requests.compactMap(\.url?.absoluteString)
    #expect(urls == ["https://127.0.0.1:4321/api/v1/projects/proj%2F1/git/info",
                     "https://127.0.0.1:4321/api/v1/projects/proj%2F1/git/diff?file=src/a%20b%26c%3Dd.ts&staged=false",
                     // A literal "+" would reach the desktop's URLSearchParams as a space.
                     "https://127.0.0.1:4321/api/v1/projects/p/git/diff?file=notes/c%2B%2B.md&staged=true"])
    #expect(await io.requests.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token" })
}

@Test func changesReadsAreMeasuredAsChanges() {
    #expect(AnnexReadRoute.gitStatus(projectID: "p").diagnosticOperation == .changes)
    #expect(AnnexReadRoute.gitDiff(projectID: "p", filePath: "a", staged: false).diagnosticOperation == .changes)
}
