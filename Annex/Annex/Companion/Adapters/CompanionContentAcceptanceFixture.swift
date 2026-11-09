#if DEBUG && canImport(UIKit)
import UIKit

/// Opt-in synthetic service data only. No desktop filesystem, transport or URL is accessed.
@MainActor enum CompanionContentAcceptanceFixture {
    static var enabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--companion-preview") && arguments.contains("--companion-preview-content-acceptance")
    }
    static let homeText = "~/.clubhouse/scratch/home.txt"
    static let temporaryText = "/tmp/clubhouse-preview/scratch.txt"
    static let homePDF = "~/.clubhouse/scratch/acceptance.pdf"
    static let linkHref = "Some%20Folder/notes.md#intro"
    static let folderHref = "Some%20Folder/"
    static let truncatedHref = "Big%20Folder/"
    static let missingLink = "missing.md"
    static let notAllowedLink = "/Users/river/private/keys.md"
    static let folderPath = "/Users/river/clubhouse/Some Folder"
    static let linkFile = folderPath + "/notes.md"
    static var history: CompanionHistory {
        if ProcessInfo.processInfo.arguments.contains("--companion-preview-local-links") {
            return .init(items: [
                .message(.init(id: "local-links-acceptance", role: .assistant,
                              text: "Local links: [file](\(linkHref)), [missing](\(missingLink)), [folder](\(folderHref)), [big folder](\(truncatedHref)), [private](\(notAllowedLink))."))
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
        case notAllowedLink: return .notAllowed
        default: return .missing
        }
    }
    static func content(path: String) throws -> CompanionContent {
        let name = (path as NSString).lastPathComponent
        switch path {
        case linkFile:
            return .init(kind: "text", name: name, text: "Synthetic local link preview")
        case homeText, temporaryText:
            return .init(kind: "text", name: name, mimeType: "text/plain",
                         text: "Synthetic scratch preview\nRaw path: \(path)")
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
}
#endif
