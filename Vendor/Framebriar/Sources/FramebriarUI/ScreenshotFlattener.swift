import CoreGraphics
import Foundation
import ImageIO

/// The pen's fixed colors. A pen stroke marks the image and never hides it, whatever its color.
public enum ScreenshotInk: Sendable, Equatable, CaseIterable {
    case red, yellow, blue, white

    /// In sRGB, where flattened output is, so a delivered stroke is exactly this color.
    public var rgb: (red: UInt8, green: UInt8, blue: UInt8) {
        switch self {
        case .red: (255, 0, 0)
        case .yellow: (255, 204, 0)
        case .blue: (0, 122, 255)
        case .white: (255, 255, 255)
        }
    }
}

/// A mark on the upright image, in source pixels with a top-left origin, so zoom and rotation don't affect it.
/// Hold marks in view memory only. On purpose this isn't `Codable`, and no report or queue type can carry one.
public enum ScreenshotMark: Sendable, Equatable {
    case pen(points: [CGPoint], width: CGFloat, ink: ScreenshotInk = .red)
    case redaction(CGRect)
}

/// Turns an image and its marks into new PNG bytes. Separated from UIKit so the pixels are deterministic in tests.
/// Nothing from the source survives except its visible pixels: no alpha, layers or metadata. Redactions go on
/// last, at source resolution before any resampling and again after it, so a fit-down can't carry an original
/// pixel into the covered area or blend one into its neighbors.
enum ScreenshotFlattener {
    /// A decode guard, well above what the report limits keep. `ShakeScreenshot` fits the result down.
    static let maxSourcePixels = 100_000_000

    /// The image as displayed: orientation applied, composited over white, opaque.
    static func upright(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width * image.height <= maxSourcePixels else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let sideways = (5...8).contains(orientation)
        let width = sideways ? image.height : image.width, height = sideways ? image.width : image.height
        guard let context = opaqueContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.concatenate(transform(orientation, width: CGFloat(image.width), height: CGFloat(image.height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// A stroke's width in source pixels: 6 points on screen, and at least 3 at the fitted zoom, so one
    /// drawn zoomed in can still be read when the whole image is shown at phone size.
    static func penWidth(zoomScale: CGFloat, fitScale: CGFloat) -> CGFloat { max(6 / zoomScale, 3 / fitScale) }

    /// Nil if the image can't be decoded or can't fit the limits. Never returns the source bytes.
    static func flatten(_ data: Data, marks: [ScreenshotMark], maxBytes: Int = ShakeScreenshot.maxPNGBytes) -> Data? {
        guard let base = upright(data), let full = render(base, marks: marks) else { return nil }
        let redactions = marks.compactMap { mark -> CGRect? in if case .redaction(let rect) = mark { rect } else { nil } }
        return ShakeScreenshot.encodePNG(width: full.width, height: full.height, maxBytes: maxBytes) { width, height in
            if width == full.width, height == full.height { return full }
            guard let context = opaqueContext(width: width, height: height) else { return nil }
            context.interpolationQuality = .high
            context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
            fill(redactions, in: context, scaleX: CGFloat(width) / CGFloat(full.width), scaleY: CGFloat(height) / CGFloat(full.height))
            return context.makeImage()
        }
    }

    /// Whole pixels, top-left origin, expanded outward so a partly covered pixel is fully covered. Nil if outside the image.
    static func coveredPixels(_ rect: CGRect, scaleX: CGFloat = 1, scaleY: CGFloat = 1, width: Int, height: Int) -> CGRect? {
        let minX = max(0, (rect.minX * scaleX).rounded(.down)), maxX = min(CGFloat(width), (rect.maxX * scaleX).rounded(.up))
        let minY = max(0, (rect.minY * scaleY).rounded(.down)), maxY = min(CGFloat(height), (rect.maxY * scaleY).rounded(.up))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func render(_ base: CGImage, marks: [ScreenshotMark]) -> CGImage? {
        guard let context = opaqueContext(width: base.width, height: base.height) else { return nil }
        context.interpolationQuality = .none
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(base.height)); context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round); context.setLineJoin(.round)
        for case .pen(let points, let width, let ink) in marks {
            guard let first = points.first else { continue }
            context.setStrokeColor(CGColor(srgbRed: CGFloat(ink.rgb.red) / 255, green: CGFloat(ink.rgb.green) / 255, blue: CGFloat(ink.rgb.blue) / 255, alpha: 1))
            context.setLineWidth(width)
            context.beginPath(); context.move(to: first)
            // A lone point still draws a dot, because the cap is round.
            points.dropFirst().isEmpty ? context.addLine(to: first) : context.addLines(between: points)
            context.strokePath()
        }
        context.restoreGState()
        fill(marks.compactMap { mark -> CGRect? in if case .redaction(let rect) = mark { rect } else { nil } }, in: context, scaleX: 1, scaleY: 1)
        return context.makeImage()
    }

    private static func fill(_ redactions: [CGRect], in context: CGContext, scaleX: CGFloat, scaleY: CGFloat) {
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for rect in redactions {
            guard let pixels = coveredPixels(rect, scaleX: scaleX, scaleY: scaleY, width: context.width, height: context.height) else { continue }
            context.fill(CGRect(x: pixels.minX, y: CGFloat(context.height) - pixels.maxY, width: pixels.width, height: pixels.height))
        }
    }

    private static func opaqueContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// Maps the stored pixels (y up) to the upright image, per the EXIF orientation values.
    private static func transform(_ orientation: Int, width w: CGFloat, height h: CGFloat) -> CGAffineTransform {
        switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: .identity
        }
    }
}
