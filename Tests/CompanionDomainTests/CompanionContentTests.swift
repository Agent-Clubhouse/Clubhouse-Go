import Foundation
import Testing
@testable import CompanionDomain
@testable import ClubhouseTransport

@Test func manualEndpointSupportsIPHostnameIPv6AndExplicitHTTPS() throws {
    for address in ["192.168.1.20:4321", "https://192.168.1.20:4321/"] {
        let endpoint = try AnnexEndpoint.manual(address: address, port: "")
        #expect(endpoint.host == "192.168.1.20" && endpoint.port == 4321)
    }
    #expect(try AnnexEndpoint.manual(address: "desktop.local", port: "4321").host == "desktop.local")
    #expect(try AnnexEndpoint.manual(address: "[fd00::1]:4321", port: "").host == "fd00::1")
    #expect(try AnnexEndpoint.manual(address: "desktop.tail.ts.net", port: "4321").route == .tailscale)
}
@Test func manualEndpointRejectsCredentialsPathsQueriesAndAmbiguousPorts() {
    for address in ["http://desktop:4321", "https://user:secret@desktop:4321", "desktop:4321/path", "desktop:4321?token=x", "desktop:4321#x", "desktop:0", "desktop:99999", "desktop", "", "desktop%2elocal:4321"] {
        #expect(throws: (any Error).self) { try AnnexEndpoint.manual(address: address, port: "") }
    }
    #expect(throws: (any Error).self) { try AnnexEndpoint.manual(address: "desktop:4321", port: "9876") }
    #expect(throws: (any Error).self) { try AnnexEndpoint.manual(address: "desktop:99999", port: "4321") }
}
@Test func discoveredNamesAndTXTDoNotCreateTrust() throws {
    let host = try AnnexDiscoveredHost(id: "hint", name: "Untrusted desktop", host: "desktop.local.", port: 4321,
                                     txt: ["fingerprint": Data("forged".utf8), "pairingPort": Data("9999".utf8)])
    #expect(host.endpoint.port == 4321)
    #expect(host.identityFingerprintHint == "forged")
    #expect(throws: (any Error).self) { try TrustedAnnexHost(endpoint: host.endpoint, verifiedHostID: host.identityFingerprintHint!, verifiedCertificatePin: .init(sha256: String(repeating: "a", count: 64))) }
}
@Test func contentCandidatesNeverTurnRemoteURLsIntoAutomaticLoads() {
    let files = CompanionContentReference.files(in: "`src/a.swift` [image](https://evil.test/x.png) `//evil/share` [file](src/b.txt) `src/a.swift`")
    #expect(files == [.file("src/a.swift"), .file("src/b.txt")])
    #expect(CompanionContentReference.files(in: "`README.md`") == [.file("README.md")])
    #expect(!CompanionContentReference.validMediaReference("../../secret.png"))
    #expect(CompanionContentReference.validMediaReference(String(repeating: "a", count: 64) + ".png"))
}
@Test func imageReferencesSurvivePartialToolUpdatesButRejectUntrustedPaths() {
    var projector = CompanionChatProjector()
    let ref = String(repeating: "a", count: 64) + ".png"
    func event(_ seq: Int64, _ data: [String: AnnexJSON]) -> AnnexJSON {
        .object(["sessionId": .string("session"), "seq": .integer(seq), "type": .string("tool_call_update"), "data": .object(data)])
    }
    projector.apply(event(1, ["toolCallId": .string("tool"), "media": .array([.object(["mediaRef": .string(ref)]), .object(["mediaRef": .string("/secret")]), .object(["uri": .string("https://example.test/pixel")])])]))
    projector.apply(event(2, ["toolCallId": .string("tool"), "status": .string("completed")]))
    guard case .tool(let tool) = projector.items.first else { Issue.record("Missing tool"); return }
    #expect(tool.images == [.image(ref)])
    #expect(tool.state == .completed)
}
