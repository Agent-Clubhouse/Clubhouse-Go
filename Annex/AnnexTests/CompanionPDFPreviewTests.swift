import XCTest
import SwiftUI
import PDFKit
@testable import ClubhouseGo

/// Issue 187 PDF previews. Every PDF here is synthetic, drawn in memory by the test; none is a desktop
/// capture or a committed fixture. The example.invalid URLs are never fetched.
@MainActor final class CompanionPDFPreviewTests: XCTestCase {
    private let web = URL(string: "https://example.invalid/never-fetched")!
    private let otherPDF = URL(string: "https://example.invalid/other.pdf")!

    /// Text pages, optionally encrypted. With `links`, PDFKit adds a URL link and a remote go-to link,
    /// then the document goes back through bytes, as a desktop response would arrive.
    private func synthetic(pages: Int = 2, links: Bool = false, password: String? = nil) throws -> Data {
        let format = UIGraphicsPDFRendererFormat()
        if let password {
            format.documentInfo = [kCGPDFContextUserPassword as String: password, kCGPDFContextOwnerPassword as String: password]
        }
        let drawn = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400), format: format).pdfData { context in
            for page in 0..<pages {
                context.beginPage()
                ("Synthetic page \(page + 1)" as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        guard links else { return drawn }
        let document = try XCTUnwrap(PDFDocument(data: drawn))
        let page = try XCTUnwrap(document.page(at: 0))
        let url = PDFAnnotation(bounds: CGRect(x: 0, y: 300, width: 300, height: 100), forType: .link, withProperties: nil)
        url.action = PDFActionURL(url: web)
        let remote = PDFAnnotation(bounds: CGRect(x: 0, y: 100, width: 300, height: 100), forType: .link, withProperties: nil)
        remote.action = PDFActionRemoteGoTo(pageIndex: 0, at: .zero, fileURL: otherPDF)
        page.addAnnotation(url)
        page.addAnnotation(remote)
        return try XCTUnwrap(document.dataRepresentation())
    }

    private func content(_ bytes: Data?, kind: String = "pdf", tooLarge: Bool = false) -> CompanionContent {
        CompanionContent(kind: kind, name: "out.pdf", mimeType: "application/pdf", bytes: bytes, tooLarge: tooLarge)
    }

    private func failure(_ bytes: Data) -> String? {
        do { _ = try CompanionPDFPreview.document(for: content(bytes)); return nil } catch {
            return (error as? CompanionServiceError)?.localizedDescription ?? "unexpected \(error)"
        }
    }

    private func pdfView(in view: UIView) -> PDFView? {
        if let view = view as? PDFView { return view }
        return view.subviews.lazy.compactMap { self.pdfView(in: $0) }.first
    }

    func testValidPDFOpensFromBytesWithReadableText() throws {
        let document = try XCTUnwrap(CompanionPDFPreview.document(for: content(synthetic(pages: 2))))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertNil(document.documentURL, "The preview is in memory; no file backs it")
        XCTAssertEqual(document.page(at: 1)?.string?.contains("Synthetic page 2"), true, "The parsed document retains extractable text; accessibility interaction is separate")
    }

    func testOnlyBoundedPDFResponsesReachPDFKit() throws {
        let bytes = try synthetic()
        for response in [content(bytes, kind: "other"), content(bytes, kind: "text"), content(bytes, tooLarge: true), content(nil), content(Data(count: 8 * 1024 * 1024 + 1))] {
            XCTAssertNil(try CompanionPDFPreview.document(for: response), "\(response.kind) tooLarge=\(response.tooLarge)")
        }
    }

    func testMalformedEmptyAndLockedPDFsFailWithoutAPasswordPrompt() throws {
        XCTAssertNotNil(failure(Data("%PDF-1.7\nsynthetic".utf8)), "A header alone is not a document")
        XCTAssertNotNil(failure(Data(repeating: 0x41, count: 4096)))
        XCTAssertNotNil(failure(try synthetic(pages: 0)))
        let locked = try synthetic(password: "synthetic-password")
        XCTAssertEqual(PDFDocument(data: locked)?.isLocked, true, "Control: the synthetic file needs its password")
        XCTAssertEqual(failure(locked), "This PDF is password-protected. Open it on your desktop.")
    }

    /// Control on this runtime's PDFKit: a URL action and a remote go-to action each reach their own
    /// delegate callback, the two the preview's guard replaces. If this fails, the guard's premise has gone.
    func testPDFKitRoutesURLAndRemoteGoToActionsToSeparateDelegateCallbacks() throws {
        let document = try XCTUnwrap(PDFDocument(data: synthetic(links: true)))
        let actions = try XCTUnwrap(document.page(at: 0)).annotations.compactMap(\.action)
        let url = try XCTUnwrap(actions.lazy.compactMap { $0 as? PDFActionURL }.first)
        let remote = try XCTUnwrap(actions.lazy.compactMap { $0 as? PDFActionRemoteGoTo }.first)
        XCTAssertEqual(url.url, web)
        XCTAssertEqual(remote.url, otherPDF)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let view = PDFView(frame: window.bounds)
        let recorder = Recorder()
        view.delegate = recorder
        view.document = document
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.perform(url)
        view.perform(remote)
        XCTAssertEqual(recorder.urls, [web])
        XCTAssertEqual(recorder.remoteURLs, [otherPDF])
        window.isHidden = true
    }

    func testHostedPreviewKeepsItsGuardThroughReplacementAndDismantlesDocumentFirst() throws {
        let first = try XCTUnwrap(CompanionPDFPreview.document(for: content(synthetic(links: true))))
        let second = try XCTUnwrap(CompanionPDFPreview.document(for: content(synthetic(pages: 3))))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIHostingController(rootView: AnyView(CompanionPDFPreview(document: first)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let view = try XCTUnwrap(pdfView(in: host.view))
        XCTAssertTrue(view.document === first)
        let linkGuard = try XCTUnwrap(view.delegate as? CompanionPDFPreview.LinkGuard)
        XCTAssertTrue(linkGuard.responds(to: #selector(PDFViewDelegate.pdfViewWillClick(onLink:with:))))
        XCTAssertTrue(linkGuard.responds(to: #selector(PDFViewDelegate.pdfViewOpenPDF(_:forRemoteGoToAction:))))
        // Native dispatch of the file's own actions goes to the installed guard and leaves the preview as it was.
        for action in try XCTUnwrap(first.page(at: 0)).annotations.compactMap(\.action) { view.perform(action) }
        XCTAssertTrue(view.document === first && view.delegate === linkGuard)

        host.rootView = AnyView(CompanionPDFPreview(document: second))
        host.view.layoutIfNeeded()
        XCTAssertTrue(view.document === second, "A replacement document reuses the view")
        XCTAssertTrue(view.delegate === linkGuard, "and keeps its guard")

        host.rootView = AnyView(Color.clear)
        host.view.layoutIfNeeded()
        XCTAssertNil(view.document, "Dismissal leaves nothing tappable")
        XCTAssertNil(view.delegate)
        window.isHidden = true
    }
}

@MainActor private final class Recorder: NSObject, @preconcurrency PDFViewDelegate {
    var urls: [URL] = []
    var remoteURLs: [URL] = []
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { urls.append(url) }
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) { remoteURLs.append(action.url) }
}
