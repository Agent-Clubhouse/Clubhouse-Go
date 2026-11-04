import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Capture policy and PNG encoding for the optional shake screenshot. Separated from UIKit so the
/// suppression rules and size caps are deterministic in tests. The capture stays on the device: it is
/// only shown in the composer for review and is included only if the user submits it.
public enum ShakeScreenshot {
    /// Same per-report PNG cap the client enforces.
    public static let maxPNGBytes = 8 * 1024 * 1024
    public static let maxPixels = 20_000_000
    public static let maxDimension = 8192

    /// Never capture when the host turned capture off or a secure text field is first responder.
    public static func shouldCapture(captureScreen: Bool, secureFieldActive: Bool) -> Bool {
        captureScreen && !secureFieldActive
    }

    /// Largest size within the pixel and dimension caps that preserves the aspect ratio. Never upscales.
    public static func fittedPixelSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let area = Double(width) * Double(height)
        let scale = min(1, (Double(maxPixels) / area).squareRoot(),
                        Double(maxDimension) / Double(width), Double(maxDimension) / Double(height))
        let fitted = (width: max(1, Int((Double(width) * scale).rounded(.down))),
                      height: max(1, Int((Double(height) * scale).rounded(.down))))
        guard fitted.width * fitted.height <= maxPixels else { return nil }
        return fitted
    }

    /// Encodes a metadata-free PNG within the caps, downscaling until it fits. Returns nil if it cannot.
    public static func encodePNG(_ image: CGImage, maxBytes: Int = maxPNGBytes) -> Data? {
        encodePNG(width: image.width, height: image.height, maxBytes: maxBytes) { resized(image, width: $0, height: $1) }
    }

    /// The same fit, for an image that has to produce each size itself, such as one that must repaint after resampling.
    static func encodePNG(width: Int, height: Int, maxBytes: Int = maxPNGBytes, render: (_ width: Int, _ height: Int) -> CGImage?) -> Data? {
        guard maxBytes > 0, var size = fittedPixelSize(width: width, height: height) else { return nil }
        for _ in 0..<8 {
            guard let image = render(size.width, size.height), let png = png(image) else { return nil }
            if png.count <= maxBytes { return png }
            size = (Int(Double(size.width) * 0.75), Int(Double(size.height) * 0.75))
            guard size.width > 0, size.height > 0 else { return nil }
        }
        return nil
    }

    /// Accepts a host-supplied initial attachment only if it is a decodable PNG within the caps.
    public static func validatedAttachment(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maxPNGBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxDimension, height <= maxDimension, width * height <= maxPixels,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return data
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if width == image.width, height == image.height { return image }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func png(_ source: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return withoutMetadata(output as Data)
    }

    /// ImageIO adds an `eXIf` chunk to every PNG it writes, with or without properties. Keeps only what
    /// draws the image, whole chunks with their checksums. Nil if the bytes aren't a complete PNG.
    private static func withoutMetadata(_ png: Data) -> Data? {
        let signature = 8, kept: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB", "gAMA", "cHRM", "iCCP"]
        guard png.count > signature else { return nil }
        var output = png.prefix(signature), offset = png.startIndex + signature
        while offset + 12 <= png.endIndex {
            let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let end = offset + 12 + length
            guard end <= png.endIndex else { return nil }
            let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
            if kept.contains(type) { output.append(png[offset..<end]) }
            if type == "IEND" { return Data(output) }
            offset = end
        }
        return nil
    }
}
