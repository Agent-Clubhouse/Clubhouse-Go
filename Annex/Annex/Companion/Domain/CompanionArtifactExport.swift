import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CompanionArtifactExport: Identifiable, Sendable {
    static let supportedContentTypes: [UTType] = {
        guard let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] else {
            preconditionFailure("ImageIO must report image type identifier strings")
        }
        let images = identifiers
            .compactMap { UTType($0) }
            .filter { $0.conforms(to: .image) && $0.preferredFilenameExtension != nil }
        return Set(images + [.pdf, .svg]).sorted { $0.identifier < $1.identifier }
    }()

    let id = UUID()
    let bytes: Data
    let contentType: UTType
    let filename: String
    init(content: CompanionContent) throws {
        guard !content.tooLarge, !content.truncated,
              let bytes = content.bytes, !bytes.isEmpty, bytes.count <= CompanionContent.maximumPreviewBytes,
              content.folder == nil else {
            throw CompanionContentError.unavailable("The complete file isn't available to save or share. Open it on your desktop.")
        }
        let type: UTType
        if content.kind == "pdf" {
            type = .pdf
        } else if content.kind == "image",
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let identifier = CGImageSourceGetType(source),
                  let imageType = UTType(identifier as String), imageType.conforms(to: .image) {
            type = imageType
        } else if content.kind == "image", content.mimeType == "image/svg+xml" {
            type = .svg
        } else {
            throw CompanionContentError.unavailable("This file can't be saved or shared from this preview.")
        }
        guard Self.supportedContentTypes.contains(type), let fileExtension = type.preferredFilenameExtension else {
            throw CompanionContentError.unavailable("This file's format isn't supported for saving or sharing.")
        }
        self.bytes = bytes
        contentType = type
        filename = Self.filename(content.name, extension: fileExtension, type: type)
    }

    private static func filename(_ name: String, extension fallback: String, type: UTType) -> String {
        let component = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let existing = (component as NSString).pathExtension.lowercased()
        let fileExtension = UTType(filenameExtension: existing) == type ? existing : fallback
        let forbidden = CharacterSet.controlCharacters.union(.illegalCharacters).union(CharacterSet(charactersIn: "/\\:"))
        let rawStem = (component as NSString).deletingPathExtension
        let clean = String(String.UnicodeScalarView(rawStem.unicodeScalars.filter { !forbidden.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var stem = ""
        for character in clean {
            guard stem.utf8.count + String(character).utf8.count <= 180 else { break }
            stem.append(character)
        }
        if stem.isEmpty { stem = type.conforms(to: .image) ? "image" : "document" }
        return stem + "." + fileExtension
    }
}
