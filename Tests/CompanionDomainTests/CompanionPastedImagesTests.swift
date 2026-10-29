import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

private let limits = CompanionAttachmentLimits(imageTypes: ["image/png", "image/jpeg"], maxImageBytes: 3_932_160, maxCount: 3)

private func image(_ type: UTType, width: Int = 120, height: Int = 80) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(red: 0, green: 0.6, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func provider(_ representations: [(UTType, Data)]) -> NSItemProvider {
    let provider = NSItemProvider()
    for (type, data) in representations {
        provider.registerDataRepresentation(for: type) { completion in completion(data, nil); return nil }
    }
    return provider
}

private func text(_ string: String) -> NSItemProvider { NSItemProvider(object: string as NSString) }

private func file(named name: String, contents: Data) throws -> NSItemProvider {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url)
    return provider([(.fileURL, url.dataRepresentation)])
}

@Suite struct CompanionPastedImagesTests {
    @Test func picksTheFirstImageRepresentationAndLeavesRichTextAlone() {
        #expect(CompanionPastedImages.imageType(in: [UTType.png.identifier, UTType.tiff.identifier]) == .png)
        #expect(CompanionPastedImages.imageType(in: ["public.url", UTType.jpeg.identifier]) == .jpeg)
        #expect(CompanionPastedImages.imageType(in: ["com.compuserve.gif", "org.webmproject.webp"]) == .gif)
        #expect(CompanionPastedImages.imageType(in: [UTType.heic.identifier]) == .heic)
        // Rich text with an inline picture still pastes as text.
        #expect(CompanionPastedImages.imageType(in: [UTType.utf8PlainText.identifier, UTType.png.identifier]) == nil)
        #expect(CompanionPastedImages.imageType(in: [UTType.utf8PlainText.identifier]) == nil)
        #expect(CompanionPastedImages.imageType(in: []) == nil)
    }

    @Test func loadsImageDataImageFilesAndLeavesTextAndOtherFiles() async throws {
        let png = image(.png)
        #expect(await CompanionPastedImages.load(provider([(.png, png)])) == .image(png))
        #expect(await CompanionPastedImages.load(text("hello")) == .notImage)
        let jpeg = image(.jpeg)
        #expect(await CompanionPastedImages.load(try file(named: "Photo.JPG", contents: jpeg)) == .image(jpeg))
        #expect(await CompanionPastedImages.load(try file(named: "notes.pdf", contents: Data("%PDF".utf8))) == .notImage)
        let missing = provider([(.fileURL, URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png").dataRepresentation)])
        #expect(await CompanionPastedImages.load(missing) == .unreadable)
    }

    @Test func pastedImagesBecomeAttachmentsAndTextIsLeftForTheField() async {
        let batch = await CompanionPastedImages.attachments(
            from: [provider([(.png, image(.png))]), text("caption"), provider([(.jpeg, image(.jpeg, width: 4000, height: 3000))])],
            limits: limits, remaining: 3)
        #expect(batch.tookItem == [true, false, true])
        #expect(batch.images.map(\.mimeType) == ["image/png", "image/jpeg"])
        #expect(batch.images.last.map { ($0.width, $0.height) } ?? (0, 0) == (2048, 1536), "Pasted photos get the same 2048 px cap")
        #expect(batch.problem == nil)
    }

    @Test func onlyTextLeavesNothingToDo() async {
        let batch = await CompanionPastedImages.attachments(from: [text("just words")], limits: limits, remaining: 3)
        #expect(batch == .init(images: [], tookItem: [false], problem: nil))
    }

    @Test func refusesImagesWhenTheAgentCantTakeThem() async {
        let batch = await CompanionPastedImages.attachments(from: [provider([(.png, image(.png))]), text("still pastes")], limits: nil, remaining: 3)
        #expect(batch.tookItem == [true, false], "The image is held back, the text still pastes")
        #expect(batch.images.isEmpty)
        #expect(batch.problem == "This agent can't take images. Send your message as text.")
    }

    @Test func stopsAtTheAttachmentLimit() async {
        let pngs = (0..<3).map { _ in CompanionPastedImages.Content.image(image(.png)) }
        let batch = await CompanionPastedImages.attachments(from: pngs, limits: limits, remaining: 2)
        #expect(batch.images.count == 2)
        #expect(batch.tookItem == [true, true, true], "The extra image isn't pasted as anything else")
        #expect(batch.problem == "You can attach up to 3 images.")
        let full = await CompanionPastedImages.attachments(from: [pngs[0]], limits: limits, remaining: 0)
        #expect(full.images.isEmpty && full.problem == "You can attach up to 3 images.")
    }

    @Test func reportsImagesThatCouldNotBeRead() async {
        let batch = await CompanionPastedImages.attachments(from: [.image(image(.png)), .unreadable, .image(Data("not an image".utf8))],
                                                            limits: limits, remaining: 3)
        #expect(batch.images.count == 1)
        #expect(batch.problem == "2 images couldn't be added. That image couldn't be read.")
    }
}
