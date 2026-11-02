import XCTest
import UIKit
import ImageIO
@testable import ClubhouseGo

final class CompanionIconDecoderTests: XCTestCase {
    /// Audit the build-147 UIImage(data:) behavior separately from the store's ImageIO policy.
    @MainActor func testRealSVGDataURLDecoderAudit() async throws {
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><rect width="32" height="32" fill="#6366f1"/><circle cx="16" cy="16" r="8" fill="white"/></svg>"##
        let bytes = Data(svg.utf8)
        let dataURL = "data:image/svg+xml;base64," + bytes.base64EncodedString()
        let decoded = try XCTUnwrap(CompanionIdentityColor.data(fromDataURL: dataURL))
        XCTAssertEqual(decoded, bytes)
        let uiImage = UIImage(data: decoded)
        let imageIO = CGImageSourceCreateWithData(decoded as CFData, nil)
        let thumbnail = imageIO.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) }
        let imageType = imageIO.flatMap { CGImageSourceGetType($0) as String? } ?? "none"
        print("ICON_SVG_AUDIT uiImage=\(uiImage != nil) imageIO=\(imageIO != nil) imageType=\(imageType) imageCount=\(imageIO.map(CGImageSourceGetCount) ?? 0) thumbnail=\(thumbnail != nil) thumbnailWidth=\(thumbnail?.width ?? 0) thumbnailHeight=\(thumbnail?.height ?? 0)")
        XCTAssertNil(uiImage, "Build 147's UIImage(data:) cannot render this SVG on the audited runtime")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-svg-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        let result = await store.ingest(dataURL: dataURL, host: "fixture", kind: .agent, id: "svg")
        XCTAssertNil(result, "SVG always uses initials or a server raster; never render arbitrary vectors")
    }
}
