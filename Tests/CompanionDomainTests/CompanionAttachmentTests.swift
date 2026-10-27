import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

private let limits = CompanionAttachmentLimits(imageTypes: ["image/png", "image/jpeg", "image/gif", "image/webp"], maxImageBytes: 3_932_160, maxCount: 10)

/// Left half red, right half blue, so a rotation shows in the pixels as well as the size.
private func bitmap(width: Int, height: Int, alpha: Bool = false, noise: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    if noise, let pixels = context.data?.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height) {
        var seed: UInt32 = 7
        for index in 0..<(context.bytesPerRow * height) { seed = seed &* 1_664_525 &+ 1_013_904_223; pixels[index] = UInt8(truncatingIfNeeded: seed >> 24) }
    } else {
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    }
    return context.makeImage()!
}

private func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

private func properties(_ data: Data) -> [CFString: Any] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
}

private var cameraMetadata: [CFString: Any] { [
    kCGImagePropertyOrientation: 6,
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.03, kCGImagePropertyGPSLongitudeRef: "W"],
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:26 09:41:00", kCGImagePropertyExifUserComment: "secret"],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretCam", kCGImagePropertyTIFFOrientation: 6]
] }

@Suite struct CompanionImageProcessorTests {
    @Test func appliesOrientationAndStripsLocationAndCameraMetadata() throws {
        let photo = try #require(encode(bitmap(width: 400, height: 200), type: .jpeg, properties: cameraMetadata))
        #expect(properties(photo)[kCGImagePropertyGPSDictionary] != nil, "Fixture carries GPS")
        let result = try CompanionImageProcessor.process(photo, limits: limits)
        #expect(result.mimeType == "image/jpeg")
        #expect((result.width, result.height) == (200, 400), "EXIF orientation 6 is applied to the pixels")
        let output = properties(result.bytes.data)
        #expect(output[kCGImagePropertyGPSDictionary] == nil)
        #expect((output[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] == nil)
        let exif = output[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil && exif?[kCGImagePropertyExifUserComment] == nil)
        #expect((output[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "Upright pixels need no orientation tag")
        #expect(output[kCGImagePropertyPixelWidth] as? Int == 200)
    }

    @Test func capsTheLongEdgeAt2048() throws {
        let large = try #require(encode(bitmap(width: 4000, height: 3000), type: .jpeg))
        let result = try CompanionImageProcessor.process(large, limits: limits)
        #expect((result.width, result.height) == (2048, 1536))
        let small = try #require(encode(bitmap(width: 300, height: 200), type: .jpeg))
        #expect(try CompanionImageProcessor.process(small, limits: limits).width == 300, "Small images are never enlarged")
    }

    @Test func screenshotsAndTransparentImagesStayPNG() throws {
        let screenshot = try #require(encode(bitmap(width: 300, height: 600), type: .png))
        #expect(try CompanionImageProcessor.process(screenshot, limits: limits).mimeType == "image/png")
        let transparent = try #require(encode(bitmap(width: 100, height: 100, alpha: true), type: .png))
        let result = try CompanionImageProcessor.process(transparent, limits: limits)
        #expect(result.mimeType == "image/png")
        #expect(properties(result.bytes.data)[kCGImagePropertyHasAlpha] as? Bool == true)
    }

    @Test func heicBecomesJPEG() throws {
        // Encoding HEIC needs a hardware encoder; a machine without one can't make the fixture.
        guard let heic = encode(bitmap(width: 640, height: 480), type: .heic, properties: cameraMetadata) else { return }
        let result = try CompanionImageProcessor.process(heic, limits: limits)
        #expect(result.mimeType == "image/jpeg")
        #expect((result.width, result.height) == (480, 640))
        #expect(CGImageSourceGetType(CGImageSourceCreateWithData(result.bytes.data as CFData, nil)!) as String? == UTType.jpeg.identifier)
        #expect(properties(result.bytes.data)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func recompressesToFitTheDesktopLimit() throws {
        let noisy = try #require(encode(bitmap(width: 1800, height: 1800, noise: true), type: .png))
        let tight = CompanionAttachmentLimits(imageTypes: limits.imageTypes, maxImageBytes: 250_000, maxCount: 10)
        #expect(noisy.count > tight.maxImageBytes)
        let result = try CompanionImageProcessor.process(noisy, limits: tight)
        #expect(result.bytes.data.count <= tight.maxImageBytes)
    }

    @Test func refusesUnreadableAndUnsupportedImages() throws {
        #expect(throws: CompanionImageProcessor.Failure.unreadable) { try CompanionImageProcessor.process(Data("not an image".utf8), limits: limits) }
        let photo = try #require(encode(bitmap(width: 20, height: 20), type: .jpeg))
        let webpOnly = CompanionAttachmentLimits(imageTypes: ["image/webp"], maxImageBytes: 1_000_000, maxCount: 1)
        #expect(throws: CompanionImageProcessor.Failure.unsupported) { try CompanionImageProcessor.process(photo, limits: webpOnly) }
    }
}

@Suite struct CompanionUserImageProjectionTests {
    private let reference = String(repeating: "a", count: 64) + ".png"

    @Test func echoedImageBlocksBecomeImagesWithFileNamesOnly() {
        var projector = CompanionChatProjector()
        projector.apply(.object(["sessionId": .string("s"), "seq": .integer(1), "type": .string("session_started"),
                                 "data": .object(["capabilities": .object(["images": .bool(true)])])]))
        #expect(projector.capabilities.contains(.images))
        projector.apply(.object(["sessionId": .string("s"), "seq": .integer(2), "type": .string("user_message"), "data": .object([
            "messageId": .string("m1"), "clientCommandId": .string("cmd"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("Look at these")]),
                .object(["type": .string("image"), "mimeType": .string("image/png"), "mediaRef": .string(reference), "path": .string("/Users/me/Desktop/shot.png"), "width": .integer(1179), "height": .integer(2556)]),
                .object(["type": .string("image"), "mimeType": .string("image/jpeg"), "path": .string(#"C:\Users\me\photo.jpg"#)]),
                .object(["type": .string("image"), "mediaRef": .string("../../etc/passwd")])
            ])])]))
        guard case .message(let message)? = projector.items.last else { Issue.record("No message"); return }
        #expect(message.text == "Look at these", "Images are not text")
        #expect(message.clientCommandID == "cmd")
        #expect(message.images.map(\.mediaRef) == [reference, nil, nil], "Older or invalid references show as placeholders")
        #expect(message.images.map(\.name) == ["shot.png", "photo.jpg", nil])
        #expect(message.images.first?.width == 1179)
        #expect(Set(message.images.map(\.id)).count == 3)
    }

    @Test func imageCapabilityFollowsTheSession() {
        var projector = CompanionChatProjector()
        projector.updateCapabilities(.object(["images": .bool(true)]))
        projector.updateCapabilities(.object(["steer": .bool(true)]))
        #expect(projector.capabilities.contains(.images), "Absent keys keep their earlier value")
        projector.updateCapabilities(.object(["images": .bool(false)]))
        #expect(!projector.capabilities.contains(.images))
    }
}

@MainActor private final class AttachmentService: CompanionService {
    enum Outcome { case accept, reject(Error) }
    var uploads: [CompanionImageAttachment] = []
    var uploadOutcomes: [Outcome] = []
    var sent: [CompanionSendRequest] = []
    var sendOutcomes: [Outcome] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func upload(_ image: CompanionImageAttachment, target: CompanionTarget) async throws -> String {
        uploads.append(image)
        if !uploadOutcomes.isEmpty, case .reject(let error) = uploadOutcomes.removeFirst() { throw error }
        return "upload-\(uploads.count)"
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        sent.append(request)
        if !sendOutcomes.isEmpty, case .reject(let error) = sendOutcomes.removeFirst() { throw error }
        return .init(clientCommandID: request.clientCommandID)
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
}

@Suite @MainActor struct CompanionAttachmentStoreTests {
    private let target = CompanionTarget(hostID: "host", projectID: "project", agentID: "agent")
    private func store(attachments: CompanionAttachmentLimits? = limits, capabilities: CompanionCapabilities = [.chat, .images]) -> (CompanionStore, AttachmentService) {
        let service = AttachmentService()
        let store = CompanionStore(service: service)
        store.apply(.hosts([.init(id: "host", name: "Desk", endpoint: "desk.local", connection: .connected, projects: [
            .init(id: "project", name: "Project", agents: [.init(id: target, name: "Agent", subtitle: "", status: .idle, capabilities: capabilities)])
        ], attachments: attachments)]))
        return (store, service)
    }
    private func image(_ index: Int = 0) -> CompanionImageAttachment {
        .init(bytes: .init(Data([0x89, 0x50, UInt8(index)])), mimeType: "image/png", width: 10, height: 10)
    }
    private var lastMessage: (CompanionStore) -> CompanionMessage? {
        { store in
            guard case .message(let message)? = store.conversation(for: target).items.last else { return nil }
            return message
        }
    }

    @Test func attachingNeedsTheDesktopCapabilityAndAnImageSession() {
        #expect(store().0.attachmentLimits(for: target) == limits)
        #expect(store(attachments: nil).0.attachmentLimits(for: target) == nil, "An older desktop sends text only")
        #expect(store(capabilities: [.chat]).0.attachmentLimits(for: target) == nil, "The session must report images: true")
        #expect(store(capabilities: [.chat, .wake]).0.attachmentLimits(for: target) == nil, "A sleeping agent is woken with text")
    }

    @Test func attachmentsStopAtTheAdvertisedCount() {
        let (store, _) = store(attachments: .init(imageTypes: ["image/png"], maxImageBytes: 100, maxCount: 2))
        store.addAttachments([image(0), image(1), image(2)], to: target)
        #expect(store.attachmentDrafts[target]?.count == 2)
        store.removeAttachment(store.attachmentDrafts[target]![0].id, from: target)
        #expect(store.attachmentDrafts[target]?.count == 1)
    }

    @Test func uploadsEveryImageThenSendsOnceWithTheirIds() async {
        let (store, service) = store()
        store.addAttachments([image(0), image(1)], to: target)
        store.drafts[target] = "  Here they are "
        await store.sendDraft(to: target)
        #expect(service.uploads.count == 2)
        #expect(service.sent.count == 1)
        #expect(service.sent.first?.attachmentIDs == ["upload-1", "upload-2"])
        #expect(service.sent.first?.text == "Here they are")
        #expect(store.attachmentDrafts[target] == nil && store.drafts[target] == "")
        let message = lastMessage(store)
        #expect(message?.delivery == .accepted)
        #expect(message?.images.count == 2 && message?.images.allSatisfy { $0.local != nil } == true, "The bubble keeps the phone's copies")
    }

    @Test func imagesAloneCanBeSent() async {
        let (store, service) = store()
        store.addAttachments([image()], to: target)
        await store.sendDraft(to: target)
        #expect(service.sent.first?.text == "")
        #expect(service.sent.first?.attachmentIDs == ["upload-1"])
        store.drafts[target] = "   "
        await store.sendDraft(to: target)
        #expect(service.sent.count == 1, "Nothing to send without text or images")
    }

    @Test func expiredIdsAreUploadedAgainAndSentAsANewCommand() async {
        let (store, service) = store()
        service.sendOutcomes = [.reject(CompanionAttachmentError.attachmentUnavailable), .accept]
        store.addAttachments([image(0), image(1)], to: target)
        await store.sendDraft(to: target)
        #expect(service.uploads.count == 4)
        #expect(service.sent.map(\.attachmentIDs) == [["upload-1", "upload-2"], ["upload-3", "upload-4"]])
        #expect(service.sent[0].clientCommandID != service.sent[1].clientCommandID)
        let message = lastMessage(store)
        #expect(message?.clientCommandID == service.sent[1].clientCommandID)
        #expect(message?.delivery == .accepted)
        #expect(store.conversation(for: target).items.count == 1)
    }

    @Test func aRetryReusesUploadedIdsUnderANewCommandId() async throws {
        let (store, service) = store()
        service.sendOutcomes = [.reject(CompanionServiceError.rejected("Busy")), .accept]
        store.addAttachments([image()], to: target)
        await store.sendDraft(to: target)
        let failed = try #require(lastMessage(store))
        #expect(failed.delivery == .failed("Busy"))
        await store.retry(messageID: failed.id, target: target)
        #expect(service.uploads.count == 1, "Ids live for a day; the images aren't uploaded again")
        #expect(service.sent.map(\.attachmentIDs) == [["upload-1"], ["upload-1"]])
        #expect(service.sent[0].clientCommandID != service.sent[1].clientCommandID)
        #expect(lastMessage(store)?.delivery == .accepted)
    }

    @Test func aSessionThatRefusesImagesHidesTheAttachButton() async {
        let (store, service) = store()
        service.sendOutcomes = [.reject(CompanionAttachmentError.imagesNotSupported)]
        store.addAttachments([image()], to: target)
        await store.sendDraft(to: target)
        #expect(lastMessage(store)?.delivery == .failed(CompanionAttachmentError.imagesNotSupported.localizedDescription))
        #expect(store.attachmentLimits(for: target) == nil)
    }

    @Test func uploadFailuresShowOnTheBubbleWithoutSending() async {
        let (store, service) = store()
        service.uploadOutcomes = [.reject(CompanionServiceError.rejected("This image is too large for the desktop."))]
        store.addAttachments([image()], to: target)
        store.drafts[target] = "caption"
        await store.sendDraft(to: target)
        #expect(service.sent.isEmpty)
        #expect(lastMessage(store)?.delivery == .failed("This image is too large for the desktop."))
    }

    @Test func aShortRetryAfterIsWaitedOut() async {
        let (store, service) = store()
        service.uploadOutcomes = [.reject(CompanionAttachmentError.rateLimited(retryAfter: 1)), .accept]
        store.addAttachments([image()], to: target)
        let started = ContinuousClock.now
        await store.sendDraft(to: target)
        #expect(ContinuousClock.now - started >= .seconds(1))
        #expect(service.uploads.count == 2)
        #expect(service.sent.first?.attachmentIDs == ["upload-2"])
        let (limited, limitedService) = self.store()
        limitedService.uploadOutcomes = [.reject(CompanionAttachmentError.rateLimited(retryAfter: 600))]
        limited.addAttachments([image()], to: target)
        await limited.sendDraft(to: target)
        #expect(limitedService.uploads.count == 1, "A long wait is left to the user")
        #expect(lastMessage(limited)?.delivery == .failed(CompanionAttachmentError.rateLimited(retryAfter: 600).localizedDescription))
    }

    @Test func theEchoKeepsThePhonesCopyOfEachImage() async throws {
        let (store, service) = store()
        store.addAttachments([image()], to: target)
        await store.sendDraft(to: target)
        let commandID = try #require(service.sent.first?.clientCommandID)
        let reference = String(repeating: "b", count: 64) + ".png"
        store.apply(.upsert(target, .message(.init(id: "m1", role: .user, text: "", clientCommandID: commandID,
                                                   images: [.init(id: "m1-image-0", mimeType: "image/png", mediaRef: reference)])), sequence: 3))
        let items = store.conversation(for: target).items
        #expect(items.count == 1, "The echo replaces the optimistic bubble")
        let echoed = try #require(lastMessage(store))
        #expect(echoed.id == "m1")
        #expect(echoed.images.first?.mediaRef == reference)
        #expect(echoed.images.first?.local != nil, "Shown from the phone even with Rich chat content off")
        let content = try await store.content(.localImage("m1-image-0"), target: target)
        #expect(content.bytes == Data([0x89, 0x50, 0]))
        // A full timeline from the desktop keeps it too.
        store.apply(.timeline(target, items: [.message(.init(id: "m1", role: .user, text: "", clientCommandID: commandID,
                                                             images: [.init(id: "m1-image-0", mediaRef: reference)]))], sequence: 4, reset: false))
        #expect(lastMessage(store)?.images.first?.local != nil)
    }
}

private actor AttachmentTransport: AnnexTransporting {
    private var continuation: AsyncThrowingStream<AnnexTransportEvent, Error>.Continuation?
    private(set) var commands: [AnnexCommand] = []
    private(set) var uploads: [(agent: String, mime: String)] = []
    func events() -> AsyncThrowingStream<AnnexTransportEvent, Error> {
        let pair = AsyncThrowingStream<AnnexTransportEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func connect() { continuation?.yield(.connection(.connected)) }
    func disconnect() {}
    func read(_ route: AnnexReadRoute) throws -> AnnexJSON {
        switch route {
        case .capabilities:
            return .object(["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"), "controlAvailable": .bool(true),
                            "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(256), "ttlMs": .integer(60000)]),
                            "commands": .array([.string("chat.send")]),
                            "attachments": .object(["version": .integer(1), "imageTypes": .array([.string("image/png"), .string("image/jpeg")]),
                                                    "maxImageBytes": .integer(3_932_160), "maxCount": .integer(10)])])
        case .projects: return .array([.object(["id": .string("project"), "name": .string("Project")])])
        case .agents: return .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("running"), "executionMode": .string("chat")])])
        case .chat:
            return .object(["sessionId": .string("session"), "state": .string("idle"), "events": .array([]),
                            "capabilities": .object(["images": .bool(true)])])
        default: throw AnnexTransportError.unsupportedCapability("fixture")
        }
    }
    func upload(agentID: String, data: Data, mimeType: String) throws -> AnnexAttachmentUpload {
        uploads.append((agentID, mimeType))
        if uploads.count > 1 { throw AnnexTransportError.rateLimited(code: "rate_limited", retryAfterSeconds: 7) }
        return try JSONDecoder().decode(AnnexAttachmentUpload.self, from: Data(#"{"version":1,"attachmentId":"att-1","mimeType":"image/png","bytes":3}"#.utf8))
    }
    func execute(_ command: AnnexCommand) throws -> AnnexCommandReceipt {
        commands.append(command)
        return try JSONDecoder().decode(AnnexCommandReceipt.self, from: Data(#"{"version":1,"commandId":"\#(command.commandID)","epoch":"epoch","status":"rejected","error":{"code":"attachment_unavailable","message":"gone"}}"#.utf8))
    }
}

@Suite @MainActor struct CompanionLiveAttachmentTests {
    private let target = CompanionTarget(hostID: "01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef", projectID: "project", agentID: "agent")

    @Test func liveServiceGatesUploadsAndMapsTheDesktopsAnswers() async throws {
        let transport = AttachmentTransport()
        let host = try TrustedAnnexHost(endpoint: AnnexEndpoint(host: "127.0.0.1", port: 8443), verifiedHostID: target.hostID,
                                       verifiedCertificatePin: AnnexCertificatePin(sha256: String(repeating: "01", count: 32)))
        let service = CompanionLiveService()
        let store = CompanionStore(service: service)
        store.start()
        defer { store.stop(); service.remove(hostID: target.hostID) }
        await service.register(.init(host: host, alias: "Fixture", transport: transport))
        for _ in 0..<200 where store.hosts.first?.connection != .connected { try await Task.sleep(for: .milliseconds(5)) }
        await store.load(target)
        for _ in 0..<200 where store.attachmentLimits(for: target) == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(store.attachmentLimits(for: target)?.imageTypes == ["image/png", "image/jpeg"])

        let image = CompanionImageAttachment(bytes: .init(Data([1, 2, 3])), mimeType: "image/png", width: 1, height: 1)
        #expect(try await service.upload(image, target: target) == "att-1")
        await #expect(throws: CompanionAttachmentError.rateLimited(retryAfter: 7)) { try await service.upload(image, target: target) }
        await #expect(throws: CompanionAttachmentError.attachmentUnavailable) {
            try await service.send(.init(target: target, text: "", clientCommandID: "cmd", isSteering: false, attachmentIDs: ["att-1"]))
        }
        let command = try #require(await transport.commands.first)
        #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())["attachmentIds"] == .array([.string("att-1")]))
    }

    @Test func uploadErrorsMapToWhatThePhoneCanDo() {
        func mapped(_ error: AnnexTransportError) -> String { CompanionLiveService.uploadError(error).localizedDescription }
        #expect(CompanionLiveService.uploadError(AnnexTransportError.rejected(status: 409, code: "images_not_supported")) as? CompanionAttachmentError == .imagesNotSupported)
        #expect(mapped(.rejected(status: 409, code: "not_chat")) == CompanionLiveService.notChatMessage)
        #expect(mapped(.rejected(status: 413, code: "too_large")).contains("too large"))
        #expect(mapped(.rejected(status: 415, code: "unsupported_image")).contains("can't read"))
        #expect(CompanionLiveService.uploadError(AnnexTransportError.rateLimited(code: "quota_exceeded", retryAfterSeconds: 60)) as? CompanionAttachmentError == .rateLimited(retryAfter: 60))
        #expect(CompanionLiveService.uploadError(URLError(.timedOut)) is CompanionServiceError, "A lost upload can simply be tried again")
    }
}
