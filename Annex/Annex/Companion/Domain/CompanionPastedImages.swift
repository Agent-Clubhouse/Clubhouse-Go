import Foundation
import UniformTypeIdentifiers

/// Turns pasted or dropped items into attachments. An item that carries an image, as data or as an image file,
/// is processed like a picked photo; text, links and other files are left for the text field to paste as usual.
enum CompanionPastedImages {
    /// What the composer accepts besides text, so the field offers Paste and takes drops when only an image is on the pasteboard.
    static let acceptedTypes: [UTType] = [.image, .fileURL]

    enum Content: Equatable, Sendable {
        /// Text, a link or a file that isn't an image: the field pastes it.
        case notImage
        case image(Data)
        /// It claimed to be an image but its bytes couldn't be loaded.
        case unreadable
    }

    /// The image representation to load, best first. Items that also carry plain text, such as copied rich text, paste as text.
    static func imageType(in typeIdentifiers: [String]) -> UTType? {
        let types = typeIdentifiers.compactMap(UTType.init)
        guard !types.contains(where: { $0.conforms(to: .plainText) }) else { return nil }
        return types.first { $0.conforms(to: .image) }
    }

    static func load(_ provider: NSItemProvider) async -> Content {
        let identifiers = provider.registeredTypeIdentifiers
        if let type = imageType(in: identifiers) {
            return await data(from: provider, type: type).map(Content.image) ?? .unreadable
        }
        guard identifiers.contains(where: { UTType($0)?.conforms(to: .fileURL) == true }),
              let reference = await data(from: provider, type: .fileURL),
              let url = URL(dataRepresentation: reference, relativeTo: nil), url.isFileURL else { return .notImage }
        return content(ofFile: url)
    }

    /// An image file named by a pasted file URL. Other files paste as their URL.
    static func content(ofFile url: URL) -> Content {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return .notImage }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= CompanionImageProcessor.maximumInputBytes, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .unreadable }
        return .image(data)
    }

    /// The outcome of one paste or drop.
    struct Batch: Equatable, Sendable {
        var images: [CompanionImageAttachment] = []
        /// For each item, whether it was an image, so the field pastes only the others.
        var tookItem: [Bool] = []
        /// A note for the conversation, or nil when every image was added.
        var problem: String?
    }

    /// Loads and processes every image among `providers`. `limits` is nil when the host or session can't take images,
    /// and `remaining` is how many more the draft can hold.
    static func attachments(from providers: [NSItemProvider], limits: CompanionAttachmentLimits?, remaining: Int) async -> Batch {
        var contents: [Content] = []
        for provider in providers { contents.append(await load(provider)) }
        return await attachments(from: contents, limits: limits, remaining: remaining)
    }

    static func attachments(from contents: [Content], limits: CompanionAttachmentLimits?, remaining: Int) async -> Batch {
        var batch = Batch(tookItem: contents.map { $0 != .notImage })
        let images = contents.filter { $0 != .notImage }
        guard !images.isEmpty else { return batch }
        guard let limits else {
            batch.problem = CompanionAttachmentError.imagesNotSupported.localizedDescription
            return batch
        }
        let room = max(0, remaining)
        let accepted = images.prefix(room)
        var sources: [Data] = []
        var unreadable = 0
        for content in accepted {
            if case .image(let data) = content { sources.append(data) } else { unreadable += 1 }
        }
        let processed = await CompanionImageProcessor.processAll(sources, limits: limits, alreadyFailed: unreadable)
        batch.images = processed.images
        batch.problem = processed.problem
        if images.count > room {
            let full = "You can attach up to \(limits.maxCount) images."
            batch.problem = batch.problem.map { "\($0) \(full)" } ?? full
        }
        return batch
    }

    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
    }
}
