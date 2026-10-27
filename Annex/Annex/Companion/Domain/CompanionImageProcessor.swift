import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares a picked image for the desktop in one ImageIO pass: the EXIF orientation is applied to the pixels,
/// the long edge is capped, and the result is re-encoded from bare pixels, so no EXIF, GPS or other metadata
/// leaves the phone. Photos become JPEG; PNG screenshots and images with transparency stay PNG.
enum CompanionImageProcessor {
    static let maximumPixelLength = 2048
    static let jpegQuality = 0.8
    /// Larger picks are refused before decoding, as are images whose pixel count could exhaust memory.
    static let maximumInputBytes = 64 * 1024 * 1024
    static let maximumInputPixels = 100_000_000

    enum Failure: Error, LocalizedError, Equatable {
        case unreadable, tooLarge, unsupported
        var errorDescription: String? {
            switch self {
            case .unreadable: "That image couldn't be read."
            case .tooLarge: "That image is too large to send, even after shrinking it."
            case .unsupported: "The desktop can't take images in this format."
            }
        }
    }

    static func process(_ data: Data, limits: CompanionAttachmentLimits, maximumPixelLength: Int = maximumPixelLength) throws -> CompanionImageAttachment {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumInputPixels / height else { throw Failure.unreadable }
        let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        let isHEIC = type.map { $0.conforms(to: .heic) || $0.conforms(to: .heif) } ?? false
        let isPNG = type?.conforms(to: .png) ?? false
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        // Screenshots are PNG and stay sharp as PNG. HEIC always becomes JPEG, which every desktop can read.
        var mimeType = !isHEIC && (isPNG || hasAlpha) ? "image/png" : "image/jpeg"
        if !limits.imageTypes.contains(mimeType) { mimeType = mimeType == "image/png" ? "image/jpeg" : "image/png" }
        guard limits.imageTypes.contains(mimeType) else { throw Failure.unsupported }

        var length = min(maximumPixelLength, max(width, height))
        var quality = jpegQuality
        for _ in 0..<12 {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: length
            ] as CFDictionary) else { throw Failure.unreadable }
            let encoded = try encode(image, mimeType: mimeType, quality: quality)
            if encoded.count <= limits.maxImageBytes {
                return .init(bytes: .init(encoded), mimeType: mimeType, width: image.width, height: image.height)
            }
            // Over the desktop's limit: lower JPEG quality a little first, then shrink.
            if mimeType == "image/jpeg", quality > 0.55 { quality -= 0.1; continue }
            if mimeType == "image/png", limits.imageTypes.contains("image/jpeg"), length <= 1024 { mimeType = "image/jpeg"; continue }
            length = Int(Double(length) * 0.75)
            guard length >= 64 else { break }
        }
        throw Failure.tooLarge
    }

    private static func encode(_ image: CGImage, mimeType: String, quality: Double) throws -> Data {
        let output = NSMutableData()
        let type = mimeType == "image/png" ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { throw Failure.unsupported }
        // Only the pixels and the compression setting: no properties are copied from the source.
        let options: [CFString: Any] = mimeType == "image/png" ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return output as Data
    }
}
