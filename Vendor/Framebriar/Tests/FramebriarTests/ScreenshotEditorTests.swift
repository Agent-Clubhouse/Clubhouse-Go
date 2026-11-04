import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FramebriarUI

private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

/// Top-left origin. `paint` chooses each pixel, so a test knows exactly what the source held.
private func source(width: Int, height: Int, alpha: UInt8 = 255, paint: (Int, Int) -> RGB) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let c = paint(x, y), i = (y * width + x) * 4
            pixels[i] = UInt8(Int(c.r) * Int(alpha) / 255); pixels[i + 1] = UInt8(Int(c.g) * Int(alpha) / 255)
            pixels[i + 2] = UInt8(Int(c.b) * Int(alpha) / 255); pixels[i + 3] = alpha
        }
    }
    return context.makeImage()!
}
private func encoded(_ image: CGImage, properties: [CFString: Any]? = nil, type: UTType = .png) -> Data {
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
/// Exact decoded pixels. Asserts first that the file itself has no alpha.
private struct Decoded {
    let width: Int, height: Int, bytes: [UInt8]
    init(_ png: Data) throws {
        #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect([.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo), "No alpha in the file")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyHasAlpha] as? Bool != true)
        width = image.width; height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = data
    }
    func at(_ x: Int, _ y: Int) -> RGB { let i = (y * width + x) * 4; return (bytes[i], bytes[i + 1], bytes[i + 2]) }
}
/// Chunk types in file order, and whether anything follows IEND.
private func chunks(_ png: Data) -> (types: [String], trailing: Int) {
    var types: [String] = [], offset = png.startIndex + 8
    while offset + 8 <= png.endIndex {
        let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
        types.append(type); offset += 12 + length
        if type == "IEND" { break }
    }
    return (types, png.endIndex - offset)
}
private let allowedChunks: Set<String> = ["IHDR", "IDAT", "IEND", "sRGB", "gAMA", "cHRM", "iCCP"]
private func expectNoMetadata(_ png: Data) throws {
    let found = chunks(png)
    #expect(Set(found.types).isSubset(of: allowedChunks), "Unexpected chunks: \(found.types)")
    #expect(found.trailing == 0)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyExifDictionary] == nil && properties[kCGImagePropertyGPSDictionary] == nil && properties[kCGImagePropertyOrientation] == nil)
    #expect(CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCopyTags($0) as? [Any] }?.isEmpty ?? true)
}
private func noise(_ seed: inout UInt32) -> UInt8 {
    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
    return UInt8(truncatingIfNeeded: seed)
}

private func crc32(_ data: Data) -> UInt32 {
    data.reduce(UInt32.max) { crc, byte in
        (0..<8).reduce(crc ^ UInt32(byte)) { value, _ in value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
    } ^ UInt32.max
}

private let secret: RGB = (255, 0, 255)

// MARK: source resolution

@Test func redactionIsExactlyTheFillAtSourceResolution() throws {
    let input = encoded(source(width: 400, height: 900) { x, y in (x >= 100 && x < 300 && y >= 200 && y < 500) ? secret : (255, 255, 255) })
    // Fractional edges expand outward, so a partly covered pixel is fully covered.
    let png = try #require(ScreenshotFlattener.flatten(input, marks: [.redaction(CGRect(x: 99.5, y: 199.5, width: 201, height: 301))]))
    let out = try Decoded(png)
    #expect(out.width == 400 && out.height == 900)
    for y in 0..<900 {
        for x in 0..<400 {
            let inside = x >= 99 && x < 301 && y >= 199 && y < 501, c = out.at(x, y)
            if inside { #expect(c == (0, 0, 0), "\(x),\(y)") }
            else { #expect(c == (255, 255, 255), "\(x),\(y)") }
        }
    }
    try expectNoMetadata(png)
}

@Test func aRedactionTouchingTheEdgesCoversThemAndOneOutsideTheImageChangesNothing() throws {
    let input = encoded(source(width: 50, height: 50) { _, _ in secret })
    let out = try Decoded(#require(ScreenshotFlattener.flatten(input, marks: [.redaction(CGRect(x: -10, y: -10, width: 20, height: 100)), .redaction(CGRect(x: 60, y: 0, width: 5, height: 5))])))
    for y in 0..<50 {
        #expect((0..<10).allSatisfy { out.at($0, y) == (0, 0, 0) })
        #expect((10..<50).allSatisfy { out.at($0, y) == secret })
    }
}

@Test func aPenStrokeIsDrawnButNeverOverARedaction() throws {
    let input = encoded(source(width: 200, height: 200) { _, _ in (255, 255, 255) })
    let redaction = CGRect(x: 50, y: 50, width: 100, height: 100)
    // The stroke comes after the redaction and crosses it.
    let marks: [ScreenshotMark] = [.redaction(redaction), .pen(points: [CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)], width: 10)]
    let out = try Decoded(#require(ScreenshotFlattener.flatten(input, marks: marks)))
    #expect(out.at(20, 100) == (255, 0, 0), "The stroke is visible outside")
    #expect(out.at(20, 80) == (255, 255, 255))
    for y in 50..<150 { #expect((50..<150).allSatisfy { out.at($0, y) == (0, 0, 0) }) }
}

@Test func aSinglePointPenMarkDrawsADot() throws {
    let input = encoded(source(width: 40, height: 40) { _, _ in (255, 255, 255) })
    let out = try Decoded(#require(ScreenshotFlattener.flatten(input, marks: [.pen(points: [CGPoint(x: 10, y: 30)], width: 8)])))
    #expect(out.at(10, 30) == (255, 0, 0), "Top-left origin")
    #expect(out.at(10, 10) == (255, 255, 255))
}

// MARK: fit-down

/// Gray noise everywhere, the secret inside. Any magenta tint anywhere in the output is a leak: gray
/// resampled with black stays gray, and only the source's secret pixels have R and B above G.
private func expectNoLeak(_ png: Data, sourceWidth: Int, sourceHeight: Int, secretRect: CGRect) throws {
    let out = try Decoded(png)
    #expect(out.width <= 8192 && out.height <= 8192 && out.width * out.height <= ShakeScreenshot.maxPixels)
    #expect(png.count <= ShakeScreenshot.maxPNGBytes)
    let scaleX = CGFloat(out.width) / CGFloat(sourceWidth), scaleY = CGFloat(out.height) / CGFloat(sourceHeight)
    let covered = try #require(ScreenshotFlattener.coveredPixels(secretRect, scaleX: scaleX, scaleY: scaleY, width: out.width, height: out.height))
    var wrongFill = 0, tinted = 0
    for y in 0..<out.height {
        for x in 0..<out.width {
            let c = out.at(x, y)
            if covered.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { if c != (0, 0, 0) { wrongFill += 1 } }
            else if abs(Int(c.r) - Int(c.g)) > 1 || abs(Int(c.b) - Int(c.g)) > 1 { tinted += 1 }
        }
    }
    #expect(wrongFill == 0, "Every pixel of the delivered redaction, edges included, is exactly the fill")
    #expect(tinted == 0, "No original pixel inside the redaction reaches its neighbors through resampling")
    try expectNoMetadata(png)
}

@Test func redactionHoldsThroughTheByteCapFitDown() throws {
    let width = 2600, height = 2600, rect = CGRect(x: 777, y: 613, width: 1011, height: 503)
    var seed: UInt32 = 0x9E37_79B9
    let input = encoded(source(width: width, height: height) { x, y in
        if rect.contains(CGPoint(x: x, y: y)) { return secret }
        let v = noise(&seed); return (v, v, v)
    })
    let png = try #require(ScreenshotFlattener.flatten(input, marks: [.redaction(rect)]))
    let out = try Decoded(png)
    #expect(out.width < width, "Forced through the byte cap")
    try expectNoLeak(png, sourceWidth: width, sourceHeight: height, secretRect: rect)
}

@Test func redactionHoldsThroughThePixelCapFitDown() throws {
    let width = 5000, height = 5000, rect = CGRect(x: 1001, y: 2003, width: 1999, height: 37)
    let input = encoded(source(width: width, height: height) { x, y in rect.contains(CGPoint(x: x, y: y)) ? secret : ((x / 7 + y / 11) % 2 == 0 ? (255, 255, 255) : (0, 0, 0)) })
    let png = try #require(ScreenshotFlattener.flatten(input, marks: [.redaction(rect)]))
    let out = try Decoded(png)
    #expect(out.width * out.height <= ShakeScreenshot.maxPixels && out.width < width, "Forced through the pixel cap")
    try expectNoLeak(png, sourceWidth: width, sourceHeight: height, secretRect: rect)
}

@Test func redactionHoldsOnATallImageThroughTheDimensionCap() throws {
    let width = 300, height = 9000, rect = CGRect(x: 10, y: 8000, width: 280, height: 13)
    let input = encoded(source(width: width, height: height) { x, y in rect.contains(CGPoint(x: x, y: y)) ? secret : (255, 255, 255) })
    let png = try #require(ScreenshotFlattener.flatten(input, marks: [.redaction(rect)]))
    let out = try Decoded(png)
    #expect(out.height == 8192, "Forced through the dimension cap")
    try expectNoLeak(png, sourceWidth: width, sourceHeight: height, secretRect: rect)
}

@Test func aDeliveredRedactionThinnerThanOneOutputPixelStillCovers() throws {
    let width = 5000, height = 5000, rect = CGRect(x: 2000, y: 2000, width: 1, height: 1)
    let input = encoded(source(width: width, height: height) { x, y in rect.contains(CGPoint(x: x, y: y)) ? secret : (255, 255, 255) })
    let png = try #require(ScreenshotFlattener.flatten(input, marks: [.redaction(rect)], maxBytes: 100_000))
    try expectNoLeak(png, sourceWidth: width, sourceHeight: height, secretRect: rect)
}

@Test func anEditThatCannotFitReturnsNilAndNeverTheSource() {
    let input = encoded(source(width: 64, height: 64) { _, _ in secret })
    #expect(ScreenshotFlattener.flatten(input, marks: [.redaction(CGRect(x: 0, y: 0, width: 4, height: 4))], maxBytes: 1) == nil)
    #expect(ScreenshotFlattener.flatten(Data("not an image".utf8), marks: []) == nil)
}

// MARK: orientation

/// Stored pixels: red top-left, green top-right, blue bottom-left, white bottom-right. For each EXIF
/// value, what shows in the upright image's top-left, top-right and bottom-left corners.
@Test(arguments: [
    (1, false, (255, 0, 0), (0, 255, 0), (0, 0, 255)),
    (2, false, (0, 255, 0), (255, 0, 0), (255, 255, 255)),
    (3, false, (255, 255, 255), (0, 0, 255), (0, 255, 0)),
    (4, false, (0, 0, 255), (255, 255, 255), (255, 0, 0)),
    (5, true, (255, 0, 0), (0, 0, 255), (0, 255, 0)),
    (6, true, (0, 0, 255), (255, 0, 0), (255, 255, 255)),
    (7, true, (255, 255, 255), (0, 255, 0), (0, 0, 255)),
    (8, true, (0, 255, 0), (255, 255, 255), (255, 0, 0))
] as [(Int, Bool, (UInt8, UInt8, UInt8), (UInt8, UInt8, UInt8), (UInt8, UInt8, UInt8))])
func orientationIsHonoredAndRedactionIsInUprightPixels(orientation: Int, sideways: Bool, topLeft: (UInt8, UInt8, UInt8), topRight: (UInt8, UInt8, UInt8), bottomLeft: (UInt8, UInt8, UInt8)) throws {
    let w = 60, h = 40
    let input = encoded(source(width: w, height: h) { x, y in
        switch (x < w / 2, y < h / 2) {
        case (true, true): (255, 0, 0)
        case (false, true): (0, 255, 0)
        case (true, false): (0, 0, 255)
        case (false, false): (255, 255, 255)
        }
    }, properties: [kCGImagePropertyOrientation: orientation])
    let read = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(input as CFData, nil)!, 0, nil) as? [CFString: Any]
    #expect(read?[kCGImagePropertyOrientation] as? Int == orientation || orientation == 1, "The fixture must really carry the tag")

    let png = try #require(ScreenshotFlattener.flatten(input, marks: [.redaction(CGRect(x: 0, y: 0, width: 4, height: 4))]))
    let out = try Decoded(png)
    #expect(out.width == (sideways ? h : w) && out.height == (sideways ? w : h))
    #expect(out.at(0, 0) == (0, 0, 0) && out.at(3, 3) == (0, 0, 0), "The redaction lands top-left of what the user saw")
    #expect(out.at(5, 5) == topLeft)
    #expect(out.at(out.width - 2, 1) == topRight)
    #expect(out.at(1, out.height - 2) == bottomLeft)
    try expectNoMetadata(png)
}

// MARK: alpha and metadata

@Test func transparentPixelsBecomeOpaqueWhite() throws {
    let image = source(width: 8, height: 8, alpha: 0) { _, _ in secret }
    let out = try Decoded(#require(ScreenshotFlattener.flatten(encoded(image), marks: [.redaction(CGRect(x: 0, y: 0, width: 2, height: 2))])))
    #expect(out.at(0, 0) == (0, 0, 0))
    #expect(out.at(7, 7) == (255, 255, 255), "Composited over white")
    let half = try Decoded(#require(ScreenshotFlattener.flatten(encoded(source(width: 8, height: 8, alpha: 128) { _, _ in (0, 0, 0) }), marks: [.pen(points: [], width: 1)])))
    #expect((126...129).contains(half.at(4, 4).r), "Half-transparent black over white")
}

@Test func sourceMetadataDoesNotSurvive() throws {
    let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "SECRET-EXIF", kCGImagePropertyExifLensModel: "SECRET-LENS"]
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 122.3, kCGImagePropertyGPSLongitudeRef: "W"]
    let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "SECRET-MAKE", kCGImagePropertyTIFFSoftware: "SECRET-SOFTWARE"]
    let image = source(width: 32, height: 32) { _, _ in (10, 20, 30) }
    let metadata = CGImageMetadataCreateMutable()
    #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString, "SECRET-XMP" as CFString))

    let tagged = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(tagged, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImageAndMetadata(destination, image, metadata, [kCGImagePropertyExifDictionary: exif, kCGImagePropertyGPSDictionary: gps, kCGImagePropertyTIFFDictionary: tiff] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    var input = tagged as Data
    let carried = try #require(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(input as CFData, nil)!, 0, nil) as? [CFString: Any])
    #expect(carried[kCGImagePropertyGPSDictionary] != nil && carried[kCGImagePropertyExifDictionary] != nil, "The fixture must really carry EXIF and GPS")
    #expect(input.range(of: Data("SECRET-XMP".utf8)) != nil, "The fixture must really carry XMP")

    // A text chunk before IDAT, and bytes after IEND, neither of which ImageIO was asked to write.
    let text = Data("tEXtComment\0SECRET".utf8)
    let chunk = Data([0, 0, 0, UInt8(text.count - 4)]) + text + withUnsafeBytes(of: crc32(text).bigEndian) { Data($0) }
    input.insert(contentsOf: chunk, at: input.startIndex + 33)
    input.append(Data("SECRET-TRAILER".utf8))

    for marks in [[ScreenshotMark.redaction(CGRect(x: 0, y: 0, width: 4, height: 4))], [.pen(points: [CGPoint(x: 9, y: 9)], width: 2)]] {
        let png = try #require(ScreenshotFlattener.flatten(input, marks: marks))
        #expect(png.range(of: Data("SECRET".utf8)) == nil)
        try expectNoMetadata(png)
    }
}

@Test func theExistingEncoderIsUnchangedForCaptures() throws {
    let image = source(width: 20, height: 10) { _, _ in (1, 2, 3) }
    let png = try #require(ShakeScreenshot.encodePNG(image))
    let decoded = try #require(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil))
    #expect(decoded.width == 20 && decoded.height == 10)
    try expectNoMetadata(png)
}

// MARK: ink

private let paper: RGB = (128, 128, 128)
private func rgb(_ ink: ScreenshotInk) -> RGB { (ink.rgb.red, ink.rgb.green, ink.rgb.blue) }

@Test(arguments: ScreenshotInk.allCases) func eachInkDrawsExactlyItsColor(ink: ScreenshotInk) throws {
    let input = encoded(source(width: 200, height: 200) { _, _ in paper })
    let png = try #require(ScreenshotFlattener.flatten(input, marks: [.pen(points: [CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)], width: 10, ink: ink)]))
    let out = try Decoded(png)
    #expect((0..<200).allSatisfy { out.at($0, 100) == rgb(ink) })
    #expect(out.at(100, 80) == paper)
    try expectNoMetadata(png)
}

@Test func strokesKeepTheirOwnInkAndOrder() throws {
    let input = encoded(source(width: 100, height: 100) { _, _ in paper })
    let out = try Decoded(#require(ScreenshotFlattener.flatten(input, marks: [
        .pen(points: [CGPoint(x: 0, y: 20), CGPoint(x: 100, y: 20)], width: 6, ink: .yellow),
        .pen(points: [CGPoint(x: 0, y: 60), CGPoint(x: 100, y: 60)], width: 6, ink: .blue),
        .pen(points: [CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100)], width: 6, ink: .white)
    ])))
    #expect(out.at(10, 20) == rgb(.yellow) && out.at(10, 60) == rgb(.blue))
    #expect(out.at(50, 20) == rgb(.white) && out.at(50, 60) == rgb(.white), "The later stroke is on top")
}

/// A redaction wins over every ink, whichever came first, and no ink shows at its edges.
@Test(arguments: ScreenshotInk.allCases) func redactionAlwaysWinsOverInk(ink: ScreenshotInk) throws {
    let input = encoded(source(width: 200, height: 200) { x, y in (50..<150).contains(x) && (50..<150).contains(y) ? secret : paper })
    let redaction = ScreenshotMark.redaction(CGRect(x: 50, y: 50, width: 100, height: 100))
    let stroke = ScreenshotMark.pen(points: [CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)], width: 20, ink: ink)
    for marks in [[redaction, stroke], [stroke, redaction]] {
        let out = try Decoded(#require(ScreenshotFlattener.flatten(input, marks: marks)))
        for y in 50..<150 { #expect((50..<150).allSatisfy { out.at($0, y) == (0, 0, 0) }) }
        #expect(out.at(20, 100) == rgb(ink), "The stroke still shows outside")
    }
}

@Test func aPenStrokeOfAnyInkDoesNotHideWhatItCrosses() throws {
    let input = encoded(source(width: 100, height: 100) { _, _ in secret })
    for ink in ScreenshotInk.allCases {
        let out = try Decoded(#require(ScreenshotFlattener.flatten(input, marks: [.pen(points: [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)], width: 6, ink: ink)])))
        #expect(out.at(50, 20) == secret, "Only what's under the line changes")
    }
}

@Test func penWidthStaysReadableAtPhoneSizeWhateverTheZoom() {
    let fit: CGFloat = 1.0 / 3 // A 3x screenshot fitted to the screen.
    #expect(ScreenshotFlattener.penWidth(zoomScale: fit, fitScale: fit) == 18, "6 points on screen")
    #expect(ScreenshotFlattener.penWidth(zoomScale: fit * 8, fitScale: fit) == 9, "Zoomed in, still 3 points when fitted")
}

// MARK: clearing edits

@Test func noMarksFlattensToTheSourceReEncoded() throws {
    var seed: UInt32 = 0x1234_5678
    var painted: [[UInt8]] = []
    let image = source(width: 64, height: 64) { _, _ in
        let c: RGB = (noise(&seed), noise(&seed), noise(&seed))
        painted.append([c.r, c.g, c.b])
        return c
    }
    let input = encoded(image, properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "SECRET"]])
    let png = try #require(ScreenshotFlattener.flatten(input, marks: []))
    let after = try Decoded(png)
    for y in 0..<64 {
        #expect((0..<64).allSatisfy { let c = after.at($0, y); return [c.r, c.g, c.b] == painted[y * 64 + $0] }, "Every pixel of the source")
    }
    try expectNoMetadata(png)
}

@Test func undoingOneMarkLeavesTheOthersOnTheSource() throws {
    let input = encoded(source(width: 100, height: 100) { _, _ in secret })
    let kept = ScreenshotMark.redaction(CGRect(x: 0, y: 0, width: 10, height: 10)), undone = ScreenshotMark.redaction(CGRect(x: 50, y: 50, width: 10, height: 10))
    let out = try Decoded(#require(ScreenshotFlattener.flatten(input, marks: [kept, undone].dropLast())))
    #expect(out.at(5, 5) == (0, 0, 0))
    #expect(out.at(55, 55) == secret, "Reflattened from the source, so an undone redaction leaves nothing")
}
