import XCTest
import UIKit

/// The editor pinch runs in its own class, after FeedbackDiagnosticsWireUITests in the same lane.
/// Hosted #620 run 44738003005 lost synthesized scrolling from this method's first attempt
/// onward, and the stall then failed the reveal-dependent wire methods that ran after it.
/// The method, its fixture and every assertion are unchanged.
final class FeedbackEditorPinchUITests: ReliableUITestCase, FeedbackWireUITesting {
    @MainActor func testEditorPinchZoomOnHostCapturedScreen() throws {
        let app = launch()
        menu(app)
        let canvas = editor(app)
        func capture(_ name: String) throws -> (Int, Int, [UInt8]) {
            let shot = canvas.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let cg = try XCTUnwrap(UIImage(data: shot.pngRepresentation)?.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return (cg.width, cg.height, pixels)
        }
        let beforeAX = canvas.value as? String ?? "", before = try capture("before-pinch")
        XCTAssertTrue(beforeAX.hasSuffix("100% zoom"))
        canvas.pinch(withScale: 2, velocity: 2)
        let after = try capture("after-pinch"), afterAX = canvas.value as? String ?? ""
        XCTAssertEqual(before.0, after.0); XCTAssertEqual(before.1, after.1)
        let changed = zip(before.2, after.2).filter { $0 != $1 }.count
        let evidence: [String: Any] = ["beforeAX": beforeAX, "afterAX": afterAX,
            "width": before.0, "height": before.1, "changedChannels": changed, "channels": before.2.count]
        print("PINCH_EVIDENCE \(evidence)")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "pinch-pixel-evidence"; attachment.lifetime = .keepAlways; add(attachment)
        expectation(for: NSPredicate(format: "NOT value ENDSWITH ' 100% zoom'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(changed, 0, "Zoom must change rendered pixels independently of the AX value")
        canvas.doubleTap()
        expectation(for: NSPredicate(format: "value ENDSWITH '100% zoom'"), evaluatedWith: canvas)
        waitForExpectations(timeout: 5)
        app.buttons["framebriar-editor-cancel"].tap()
        app.buttons["Cancel"].tap()
        XCTAssertEqual((try wire(app)["reports"] as? [Any])?.count, 0)
    }
}
