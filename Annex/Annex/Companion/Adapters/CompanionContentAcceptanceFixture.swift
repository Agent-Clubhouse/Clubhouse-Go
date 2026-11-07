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
    static var history: CompanionHistory {
        .init(items: [
            .message(.init(id: "content-acceptance", role: .assistant,
                          text: "Synthetic scratch files: `\(homeText)`, `\(temporaryText)`, `\(homePDF)`."))
        ], contentRoots: .init(paths: ["/Users/river/clubhouse"], anyPath: true))
    }
    static func content(path: String) throws -> CompanionContent {
        let name = (path as NSString).lastPathComponent
        switch path {
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
            throw CompanionServiceError.unavailable("Unknown synthetic content reference.")
        }
    }
}
#endif
