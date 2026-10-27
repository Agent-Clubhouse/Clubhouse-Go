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
        guard maxBytes > 0, var size = fittedPixelSize(width: image.width, height: image.height) else { return nil }
        for _ in 0..<8 {
            guard let png = png(image, width: size.width, height: size.height) else { return nil }
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

    private static func png(_ image: CGImage, width: Int, height: Int) -> Data? {
        var source = image
        if width != image.width || height != image.height {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            source = scaled
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
