import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import ClubhouseGo

@MainActor final class CompanionArtifactExportTests: XCTestCase {
    private func image() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2400), format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2400))
        }
    }

    private func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            context.beginPage()
            ("Synthetic original PDF" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
    }

    private func bytes(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { bytes, error in
                if let error { continuation.resume(throwing: error) }
                else if let bytes { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: CompanionContentError.unavailable("Missing synthetic export bytes")) }
            }
        }
    }

    func testNativeShareProvidersDeliverOriginalPDFAndImageBytesNameAndType() async throws {
        for content in [
            CompanionContent(kind: "image", name: "original.png", mimeType: "image/png", bytes: image()),
            CompanionContent(kind: "pdf", name: "original.pdf", mimeType: "application/pdf", bytes: pdf())
        ] {
            let artifact = try CompanionArtifactExport(content: content)
            let provider = CompanionArtifactShareView.itemProvider(for: artifact)
            XCTAssertEqual(provider.suggestedName, content.name)
            XCTAssertEqual(provider.registeredTypeIdentifiers, [artifact.contentType.identifier])
            let delivered = try await bytes(provider, type: artifact.contentType)
            XCTAssertEqual(delivered, content.bytes, "Never encode the rendered image thumbnail or PDF preview")
        }
    }

    func testIndependentShareProvidersCannotLeakThePreviouslyOpenedFile() async throws {
        let first = try CompanionArtifactExport(content: .init(kind: "pdf", name: "first.pdf", bytes: pdf()))
        let second = try CompanionArtifactExport(content: .init(kind: "image", name: "second.png", bytes: image()))
        let firstProvider = CompanionArtifactShareView.itemProvider(for: first)
        let secondProvider = CompanionArtifactShareView.itemProvider(for: second)
        let secondBytes = try await bytes(secondProvider, type: .png)
        let firstBytes = try await bytes(firstProvider, type: .pdf)
        XCTAssertEqual(secondBytes, second.bytes)
        XCTAssertEqual(firstBytes, first.bytes)
        XCTAssertEqual(firstProvider.suggestedName, "first.pdf")
        XCTAssertEqual(secondProvider.suggestedName, "second.png")
    }

    func testSaveDocumentNegotiatesConcreteOriginalTypesAndRefusesConversion() throws {
        let jpeg = try XCTUnwrap(UIImage(data: image())?.jpegData(compressionQuality: 0.9))
        for content in [
            CompanionContent(kind: "pdf", name: "original.pdf", bytes: pdf()),
            CompanionContent(kind: "image", name: "original.png", bytes: image()),
            CompanionContent(kind: "image", name: "original.jpeg", bytes: jpeg),
            CompanionContent(kind: "image", name: "original.svg", mimeType: "image/svg+xml",
                             bytes: Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>".utf8))
        ] {
            let artifact = try CompanionArtifactExport(content: content)
            let document = CompanionArtifactDocument(artifact: artifact)
            XCTAssertTrue(CompanionArtifactDocument.writableContentTypes.contains(artifact.contentType))
            let saved = try document.fileWrapper(for: artifact.contentType)
            XCTAssertEqual(saved.regularFileContents, content.bytes, "Save must serialize original bytes, independently of Share's provider")
            XCTAssertEqual(artifact.filename, content.name)
            XCTAssertThrowsError(try document.fileWrapper(for: .data))
            XCTAssertThrowsError(try document.fileWrapper(for: artifact.contentType == .pdf ? .png : .pdf),
                                 "An alternate supported type must not relabel unchanged bytes")
        }
    }
}
