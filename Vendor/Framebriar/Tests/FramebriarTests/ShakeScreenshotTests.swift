import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Framebriar
import FramebriarUI

private func image(width: Int, height: Int, noise: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
        // Deterministic incompressible pixels, so PNG size scales with area.
        var state: UInt32 = 0x9E37_79B9
        for i in 0..<(context.bytesPerRow * height) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            pixels[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state)
        }
    } else {
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    return context.makeImage()!
}

private func pixelSize(_ png: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

private func jpeg(_ image: CGImage) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    _ = CGImageDestinationFinalize(destination)
    return output as Data
}

@Test func captureIsSkippedWhenDisabledOrSecureFieldIsFocused() {
    #expect(ShakeScreenshot.shouldCapture(captureScreen: true, secureFieldActive: false))
    #expect(!ShakeScreenshot.shouldCapture(captureScreen: true, secureFieldActive: true))
    #expect(!ShakeScreenshot.shouldCapture(captureScreen: false, secureFieldActive: false))
    #expect(!ShakeScreenshot.shouldCapture(captureScreen: false, secureFieldActive: true))
}

@Test func fittedSizeKeepsPhoneScreensAndCapsPixelsAndDimensions() {
    #expect(ShakeScreenshot.fittedPixelSize(width: 1179, height: 2556)! == (1179, 2556))
    let large = ShakeScreenshot.fittedPixelSize(width: 6000, height: 5000)!
    #expect(large.width * large.height <= ShakeScreenshot.maxPixels)
    #expect(abs(Double(large.width) / Double(large.height) - 1.2) < 0.01)
    let wide = ShakeScreenshot.fittedPixelSize(width: 20_000, height: 100)!
    #expect(wide.width <= ShakeScreenshot.maxDimension && wide.height >= 1)
    #expect(ShakeScreenshot.fittedPixelSize(width: 0, height: 10) == nil)
    #expect(ShakeScreenshot.fittedPixelSize(width: 10, height: -1) == nil)
}

@Test func encodedCaptureIsPNGWithinPixelCap() throws {
    let png = try #require(ShakeScreenshot.encodePNG(image(width: 6000, height: 5000)))
    #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
    #expect(png.count <= ShakeScreenshot.maxPNGBytes)
    let (width, height) = try #require(pixelSize(png))
    #expect(width * height <= ShakeScreenshot.maxPixels)
    #expect(ShakeScreenshot.validatedAttachment(png) == png)
}

@Test func encodedCaptureDownscalesUntilWithinByteCap() throws {
    let source = image(width: 400, height: 400, noise: true)
    let full = try #require(ShakeScreenshot.encodePNG(source))
    #expect(pixelSize(full)! == (400, 400))
    let cap = full.count / 3
    let png = try #require(ShakeScreenshot.encodePNG(source, maxBytes: cap))
    #expect(png.count <= cap)
    #expect(pixelSize(png)!.0 < 400)
    #expect(ShakeScreenshot.encodePNG(source, maxBytes: 1) == nil)
}

@Test func prefillAcceptsOnlyValidPNGWithinCaps() throws {
    #expect(ShakeScreenshot.validatedAttachment(nil) == nil)
    #expect(ShakeScreenshot.validatedAttachment(Data()) == nil)
    #expect(ShakeScreenshot.validatedAttachment(Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0])) == nil)
    #expect(ShakeScreenshot.validatedAttachment(jpeg(image(width: 20, height: 20))) == nil)
    #expect(ShakeScreenshot.validatedAttachment(Data(count: ShakeScreenshot.maxPNGBytes + 1)) == nil)
    let png = try #require(ShakeScreenshot.encodePNG(image(width: 30, height: 60)))
    #expect(ShakeScreenshot.validatedAttachment(png) == png)
}

@Test func prefilledCaptureIsTheExactReviewedAttachment() throws {
    let png = try #require(ShakeScreenshot.validatedAttachment(ShakeScreenshot.encodePNG(image(width: 30, height: 60))))
    let config = try Configuration(gameID: "test-app", buildSHA: "abcdef0")
    let reviewed = try ReviewedFeedback(configuration: config, notes: "", reviewedScreenshotPNG: png)
    #expect(reviewed.screenshotPNG == png)
}
