import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
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
        let count = imageIO.map(CGImageSourceGetCount) ?? 0
        let thumbnail = imageIO.flatMap { source -> CGImage? in
            guard count > 0 else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        }
        let imageType = imageIO.flatMap { CGImageSourceGetType($0) as String? } ?? "none"
        print("ICON_SVG_AUDIT uiImage=\(uiImage != nil) imageIO=\(imageIO != nil) imageType=\(imageType) imageCount=\(count) thumbnail=\(thumbnail != nil) thumbnailWidth=\(thumbnail?.width ?? 0) thumbnailHeight=\(thumbnail?.height ?? 0)")
        XCTAssertNil(uiImage, "Build 147's UIImage(data:) cannot render this SVG on the audited runtime")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-svg-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        let result = await store.ingest(dataURL: dataURL, host: "fixture", kind: .agent, id: "svg")
        XCTAssertNil(result, "SVG always uses initials or a server raster; never render arbitrary vectors")
    }
    @MainActor func testAnimatedGIFDataURLUsesItsFirstRasterFrame() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                              bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            context.setFillColor(color); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = bytes as Data
        let dataURL = "data:image/gif;base64," + data.base64EncodedString()
        let decoded = try XCTUnwrap(CompanionIdentityColor.data(fromDataURL: dataURL))
        XCTAssertEqual(decoded, data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let image = try XCTUnwrap(UIImage(data: decoded))
        XCTAssertGreaterThan(image.size.width, 0); XCTAssertGreaterThan(image.size.height, 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-gif-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        let ingested = await store.ingest(dataURL: dataURL, host: "fixture", kind: .agent, id: "gif")
        let key = try XCTUnwrap(ingested)
        let loaded = await store.image(for: key, points: 32)
        let thumbnail = try XCTUnwrap(loaded)
        XCTAssertGreaterThan(thumbnail.cgImage.width, 0); XCTAssertGreaterThan(thumbnail.cgImage.height, 0)
        func firstPixelIsRed(_ image: CGImage) throws -> Bool {
            let canvas = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let pixel = try XCTUnwrap(canvas.data).assumingMemoryBound(to: UInt8.self)
            return pixel[0] > 200 && pixel[2] < 50
        }
        XCTAssertTrue(try firstPixelIsRed(XCTUnwrap(image.cgImage)))
        XCTAssertTrue(try firstPixelIsRed(thumbnail.cgImage))
        print("ICON_GIF_AUDIT frames=2 uiImage=true uiWidth=\(image.size.width) uiHeight=\(image.size.height) store=true storeWidth=\(thumbnail.cgImage.width) storeHeight=\(thumbnail.cgImage.height) firstFrameRed=true")
    }

}
