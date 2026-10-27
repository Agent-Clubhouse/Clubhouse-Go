import Testing
import Foundation
@testable import ClubhouseTransport

private actor UploadIO: AnnexIO {
    var requests: [URLRequest] = []
    var responses: [AnnexHTTPResponse]
    init(_ responses: [AnnexHTTPResponse]) { self.responses = responses }
    func perform(_ request: URLRequest) throws -> AnnexHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.networkConnectionLost) }
        return responses.removeFirst()
    }
    func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
    func count() -> Int { requests.count }
    func last() -> URLRequest? { requests.last }
}

private let attachmentsJSON = #""attachments":{"version":1,"imageTypes":["image/png","image/jpeg","image/gif","image/webp"],"maxImageBytes":3932160,"maxCount":10}"#
private func capabilities(_ extra: String = attachmentsJSON) -> AnnexHTTPResponse {
    let fields = extra.isEmpty ? "" : "," + extra
    return AnnexHTTPResponse(status: 200, data: Data(#"{"version":1,"epoch":"epoch1","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":["chat.send"],"idempotency":{"scope":"peer-and-epoch","maxEntries":2048,"ttlMs":3600000}\#(fields)}"#.utf8))
}
private func json(_ value: String, status: Int = 200, retryAfter: Int? = nil) -> AnnexHTTPResponse {
    AnnexHTTPResponse(status: status, data: Data(value.utf8), retryAfter: retryAfter)
}
private func transport(_ io: UploadIO) async throws -> AnnexTransport {
    let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 4321), verifiedHostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef",
                                   verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "ab", count: 32)))
    let credentials = MemoryAnnexCredentialStore()
    await credentials.save(try AnnexCredential(bearerToken: "fake-token"), for: host.hostID)
    return AnnexTransport(host: host, credentials: credentials, io: io)
}

@Test func chatSendNamesAttachmentIdsInOrderAndOmitsThemWhenEmpty() throws {
    let images = AnnexCommand(commandID: "c", epoch: "e", kind: .send(agentID: "a", sessionID: "s", text: "", attachmentIDs: ["id-2", "id-1"]))
    let value = try JSONDecoder().decode(AnnexJSON.self, from: images.encoded())
    #expect(value["attachmentIds"] == .array([.string("id-2"), .string("id-1")]))
    #expect(value["text"]?.string == "")
    #expect(images.attachmentCount == 2)
    let text = AnnexCommand(commandID: "c", epoch: "e", kind: .send(agentID: "a", sessionID: "s", text: "hi"))
    #expect(try JSONDecoder().decode(AnnexJSON.self, from: text.encoded())["attachmentIds"] == nil)
}

@Test func chatSendRefusesDuplicateOrTooManyAttachmentIds() {
    for ids in [["a", "a"], (0...10).map(String.init), [""]] {
        #expect(throws: AnnexTransportError.self) {
            try AnnexCommand(commandID: "c", epoch: "e", kind: .send(agentID: "a", sessionID: "s", text: "x", attachmentIDs: ids)).encoded()
        }
    }
}

/// The ids are part of the desktop's idempotency fingerprint, and of the transport's.
@Test func retryingACommandIdWithOtherAttachmentIdsConflicts() async throws {
    let io = UploadIO([capabilities(), json(#"{"version":1,"commandId":"cmd","epoch":"epoch1","status":"completed","result":{}}"#)])
    let transport = try await transport(io)
    _ = try await transport.read(.capabilities)
    let first = AnnexCommand(commandID: "cmd", epoch: "epoch1", kind: .send(agentID: "a", sessionID: "s", text: "", attachmentIDs: ["1", "2"]))
    _ = try await transport.execute(first)
    _ = try await transport.execute(first)
    #expect(await io.count() == 2, "The same command and ids replay the cached receipt")
    await #expect(throws: AnnexTransportError.duplicateCommandConflict) {
        try await transport.execute(AnnexCommand(commandID: "cmd", epoch: "epoch1", kind: .send(agentID: "a", sessionID: "s", text: "", attachmentIDs: ["2", "1"])))
    }
}

@Test func capabilitiesDecodeAttachmentsAndSurviveAMalformedBlock() throws {
    let caps = try JSONDecoder().decode(AnnexCapabilities.self, from: capabilities().data)
    #expect(caps.attachments == .init(imageTypes: ["image/png", "image/jpeg", "image/gif", "image/webp"], maxImageBytes: 3_932_160, maxCount: 10))
    #expect(caps.attachments?.isUsable == true)
    #expect(try JSONDecoder().decode(AnnexCapabilities.self, from: capabilities("").data).attachments == nil)
    let malformed = try JSONDecoder().decode(AnnexCapabilities.self, from: capabilities(#""attachments":{"version":"one","maxCount":99}"#).data)
    #expect(malformed.attachments?.isUsable == false)
}

@Test func uploadPostsRawBytesWithTheImageTypeAndReturnsTheId() async throws {
    let io = UploadIO([capabilities(), json(#"{"version":1,"attachmentId":"att-1","mimeType":"image/jpeg","bytes":4,"width":2,"height":1}"#)])
    let transport = try await transport(io)
    _ = try await transport.read(.capabilities)
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let receipt = try await transport.upload(agentID: "agent/1", data: bytes, mimeType: "image/jpeg")
    #expect(receipt.attachmentId == "att-1")
    #expect(receipt.width == 2)
    let request = try #require(await io.last())
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path(percentEncoded: true) == "/api/v1/mobile/agents/agent%2F1/attachments")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    #expect(request.httpBody == bytes, "No JSON wrapper or base64")
    #expect(request.timeoutInterval >= 60)
}

@Test func uploadIsRefusedLocallyWithoutTheCapabilityOrWithinItsLimits() async throws {
    let old = UploadIO([capabilities("")])
    let oldTransport = try await transport(old)
    _ = try await oldTransport.read(.capabilities)
    await #expect(throws: AnnexTransportError.unsupportedCapability("attachments")) {
        try await oldTransport.upload(agentID: "a", data: Data([1]), mimeType: "image/png")
    }
    let io = UploadIO([capabilities()])
    let transport = try await transport(io)
    _ = try await transport.read(.capabilities)
    await #expect(throws: AnnexTransportError.rejected(status: 415, code: "unsupported_media_type")) {
        try await transport.upload(agentID: "a", data: Data([1]), mimeType: "image/heic")
    }
    await #expect(throws: AnnexTransportError.rejected(status: 413, code: "too_large")) {
        try await transport.upload(agentID: "a", data: Data(count: 3_932_161), mimeType: "image/png")
    }
    let sent = (await old.count(), await io.count())
    #expect(sent == (1, 1), "Nothing is sent when the upload can't succeed")
}

@Test func uploadErrorsKeepTheirCodesAndRetryAfter() async throws {
    let io = UploadIO([capabilities(),
                       json(#"{"version":1,"error":"rate_limited"}"#, status: 429, retryAfter: 12),
                       json(#"{"version":1,"error":"images_not_supported"}"#, status: 409),
                       json(#"{"version":1,"error":"client_certificate_required"}"#, status: 403),
                       json(#"{"version":1}"#)])
    let transport = try await transport(io)
    _ = try await transport.read(.capabilities)
    let png = Data([0x89, 0x50])
    await #expect(throws: AnnexTransportError.rateLimited(code: "rate_limited", retryAfterSeconds: 12)) {
        try await transport.upload(agentID: "a", data: png, mimeType: "image/png")
    }
    await #expect(throws: AnnexTransportError.rejected(status: 409, code: "images_not_supported")) {
        try await transport.upload(agentID: "a", data: png, mimeType: "image/png")
    }
    await #expect(throws: AnnexTransportError.forbidden) {
        try await transport.upload(agentID: "a", data: png, mimeType: "image/png")
    }
    await #expect(throws: AnnexTransportError.malformedResponse) {
        try await transport.upload(agentID: "a", data: png, mimeType: "image/png")
    }
}
