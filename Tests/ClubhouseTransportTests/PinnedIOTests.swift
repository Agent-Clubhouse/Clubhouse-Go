#if os(macOS)
import Testing
import Foundation
@testable import ClubhouseTransport

@Test func actualTLSRequiresExactPinPresentsBoundClientAndRejectsRedirects() async throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", try #require(Bundle.module.url(forResource: "tls-server", withExtension: "mjs", subdirectory: "Fixtures")).path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) {
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
    let io = PinnedAnnexIO(host: host, clientIdentity: client, maximumResponseBytes: 1024)
    var request = URLRequest(url: try endpoint.url(path: ["identity"]))
    request.setValue("Bearer fake-only", forHTTPHeaderField: "Authorization")
    let response = try await io.perform(request)
    let body = try JSONDecoder().decode(AnnexJSON.self, from: response.data)
    #expect(response.status == 200)
    #expect(body["clientCN"]?.string == (try client.fingerprint))
    #expect(body["authorized"] == .bool(true))
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
    var plaintext = request
    plaintext.url = URL(string: "http://127.0.0.1:\(fixture.port)/identity")
    await #expect(throws: AnnexTransportError.invalidEndpoint) { try await io.perform(plaintext) }
}
#endif
