import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CompanionDomain

@Suite struct CompanionArtifactExportTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6hx8AAAAASUVORK5CYII=")!

    @Test func originalImageBytesAndDetectedTypeSurviveMisleadingMetadata() throws {
        let content = CompanionContent(kind: "image", name: "C:\\private\\report.jpg", mimeType: "image/jpeg", bytes: png)
        let artifact = try CompanionArtifactExport(content: content)
        #expect(artifact.bytes == png)
        #expect(artifact.contentType == .png)
        #expect(artifact.filename == "report.png")
    }

    @Test func exportRefusesIncompleteOversizedAndNonArtifactPayloads() {
        let valid = CompanionContent(kind: "image", name: "a.png", bytes: png)
        var partial = valid; partial.truncated = true
        var limited = valid; limited.tooLarge = true
        var missing = valid; missing.bytes = nil
        var oversized = valid; oversized.bytes = Data(count: CompanionContent.maximumPreviewBytes + 1)
        var malformed = valid; malformed.bytes = Data("not an image".utf8)
        var text = valid; text.kind = "text"
        for content in [partial, limited, missing, oversized, malformed, text] {
            #expect(throws: CompanionContentError.self) { _ = try CompanionArtifactExport(content: content) }
        }
    }

    @Test func exportNamesCannotEscapeOrExceedAFileComponent() throws {
        for name in ["../../\n:\0.png", "C:\\private\\a/b.png", String(repeating: "\u{1F4C4}", count: 300) + ".exe"] {
            let artifact = try CompanionArtifactExport(content: .init(kind: "image", name: name, bytes: png))
            #expect(artifact.filename.utf8.count <= 200)
            #expect(artifact.filename.hasSuffix(".png"))
            #expect(!artifact.filename.contains("/") && !artifact.filename.contains("\\"))
            #expect(!artifact.filename.contains(":") && !artifact.filename.contains("\n") && !artifact.filename.contains("\0"))
        }
    }
}
