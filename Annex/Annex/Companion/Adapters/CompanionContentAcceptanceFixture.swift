#if DEBUG && canImport(UIKit)
import UIKit
import CryptoKit
import UniformTypeIdentifiers

/// Opt-in synthetic service data only. No desktop filesystem, transport or URL is accessed.
@MainActor enum CompanionContentAcceptanceFixture {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--companion-preview") && arguments.contains("--companion-preview-content-acceptance")
    }
    static let homeText = "~/.clubhouse/scratch/home.txt"
    static let temporaryText = "/tmp/clubhouse-preview/scratch.txt"
    static let homePDF = "~/.clubhouse/scratch/acceptance.pdf"
    static let exportImage = "~/.clubhouse/scratch/original.png"
    static let exportImageBytes: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2400), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2400))
            ("Synthetic original image" as NSString).draw(at: CGPoint(x: 40, y: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.white])
        }
    }()
    static let linkHref = "Some%20Folder/notes.md#intro"
    static let folderHref = "Some%20Folder/"
    static let truncatedHref = "Big%20Folder/"
    static let missingLink = "missing.md"
    static let notAllowedLink = "/Users/river/private/keys.md"
    static let folderPath = "/Users/river/clubhouse/Some Folder"
    static let linkFile = folderPath + "/notes.md"
    static let codeSpanFile = "Some Folder/notes.md"
    static let codeSpanFolder = "Some Folder/"
    static let markdownText = "# Phone notes\r\n\r\n**Keep** trailing spaces  \r\nCaf\u{00e9} \u{1f680}\r\n\r\n- [x] Native preview\r\n\r\n![Blocked local image](./private.png)\r\n"
    static let markdownPath = "phone-notes.md"
    static var history: CompanionHistory {
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-artifact-export") {
            return .init(items: [
                .message(.init(id: "artifact-export-acceptance", role: .assistant,
                              text: "Synthetic original files: `\(homePDF)` and `\(exportImage)`."))
            ], contentRoots: .init(anyPath: true))
        }
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-markdown-files") {
            return .init(items: [
                .message(.init(id: "markdown-file-acceptance", role: .assistant,
                              text: "Markdown: `\(markdownPath)` and `phone-notes.markdown` and `phone-notes.mdx`. [Line](\(markdownPath):4)."))
            ], contentRoots: .init(anyPath: true))
        }
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-local-links") {
            return .init(items: [
                .message(.init(id: "local-links-acceptance", role: .assistant,
                              text: "Local links: [file](\(linkHref)), [missing](\(missingLink)), [folder](\(folderHref)), [big folder](\(truncatedHref)), [private](\(notAllowedLink)). Paths: `\(codeSpanFile)`, `\(codeSpanFolder)`."))
            ], contentRoots: .init(anyPath: true))
        }
        return .init(items: [
            .message(.init(id: "content-acceptance", role: .assistant,
                          text: "Synthetic scratch files: `\(homeText)`, `\(temporaryText)`, `\(homePDF)`."))
        ], contentRoots: .init(paths: ["/Users/river/clubhouse"], anyPath: true))
    }
    /// The desktop's chat-link answers for the links above and the entries of the folders it lists.
    static func resolve(_ href: String) -> CompanionLinkTarget {
        switch href {
        case markdownPath, "phone-notes.markdown", "phone-notes.mdx":
            return .file(path: href, name: href, kind: "text", size: markdownText.utf8.count)
        case linkHref, linkFile, folderPath + "/latest.md":
            return .file(path: linkFile, name: "notes.md", kind: "text", size: 1234)
        case folderHref:
            return .directory(.init(path: folderPath, name: "Some Folder", entries: [
                .init(name: "images", kind: .directory), .init(name: "latest.md", kind: .symlink),
                .init(name: "notes.md", kind: .file, size: 1234), .init(name: "socket", kind: .other)
            ], truncated: false))
        case folderPath + "/images":
            return .directory(.init(path: folderPath + "/images", name: "images", entries: [], truncated: false))
        case truncatedHref:
            return .directory(.init(path: "/Users/river/clubhouse/Big Folder", name: "Big Folder",
                                    entries: (1...12).map { .init(name: String(format: "file-%03d.txt", $0), kind: .file, size: $0 * 10) },
                                    truncated: true))
        case homeText, temporaryText:
            return .file(path: href, name: (href as NSString).lastPathComponent, kind: "text", size: nil)
        case homePDF:
            return .file(path: href, name: (href as NSString).lastPathComponent, kind: "pdf", size: nil)
        case exportImage:
            return .file(path: href, name: "original.png", kind: "image", size: exportImageBytes.count)
        case codeSpanFile: return resolve(linkFile)
        case codeSpanFolder: return resolve(folderHref)
        case notAllowedLink: return .notAllowed
        default: return .missing
        }
    }
    static func content(path: String) throws -> CompanionContent {
        let name = (path as NSString).lastPathComponent
        switch path {
        case markdownPath, "phone-notes.markdown", "phone-notes.mdx":
            return .init(kind: "text", name: name, text: markdownText, truncated: true)
        case linkFile:
            return .init(kind: "text", name: name, text: "Synthetic local link preview")
        case homeText, temporaryText:
            return .init(kind: "text", name: name, mimeType: "text/plain",
                         text: "Synthetic scratch preview\nRaw path: \(path)")
        case exportImage:
            return .init(kind: "image", name: name, mimeType: "image/png", bytes: exportImageBytes)
        case homePDF:
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
            let bytes = renderer.pdfData { context in
                for page in 1...2 {
                    context.beginPage()
                    ("Synthetic PDF page \(page)" as NSString).draw(at: CGPoint(x: 24, y: 24),
                        withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
                    if page == 1 {
                        let url = URL(string: "https://example.invalid/never-fetched")!
                        let rectangle = CGRect(x: 24, y: 70, width: 252, height: 44)
                        ("example.invalid/never-fetched" as NSString).draw(in: rectangle,
                            withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.blue])
                        // PDF link bounds use bottom-left PDF space; drawing uses top-left user space.
                        context.setURL(url, for: context.cgContext.convertToDeviceSpace(rectangle))
                    }

                }
            }
            return .init(kind: "pdf", name: name, mimeType: "application/pdf", bytes: bytes)
        default:
            throw CompanionContentError.unavailable(CompanionContentReference.unavailableLinkMessage(hostName: "Studio Mac"))
        }
    }

    static func recordExportContent(_ content: CompanionContent, path: String) {
        guard ProcessInfo.processInfo.arguments.contains("--companion-preview-artifact-export") else { return }
        guard let bytes = content.bytes else { preconditionFailure("Synthetic artifact export must carry complete file bytes") }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        print("ARTIFACT_EXPORT_FIXTURE_CONTENT path=\(path) bytes=\(bytes.count) sha256=\(hash)")
    }

    static func recordSavedExport(_ url: URL) throws {
        guard enabled, ProcessInfo.processInfo.arguments.contains("--companion-preview-artifact-export") else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = try Data(contentsOf: url)
        guard let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            throw CompanionContentError.unavailable("The saved synthetic file didn't report its content type.")
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        print("ARTIFACT_EXPORT_SAVED name=\(url.lastPathComponent) type=\(type.identifier) bytes=\(bytes.count) sha256=\(hash)")
    }
}
#endif
