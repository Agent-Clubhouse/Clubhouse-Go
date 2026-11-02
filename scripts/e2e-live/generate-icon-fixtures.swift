// Regenerate with: swift scripts/e2e-live/generate-icon-fixtures.swift > scripts/e2e-live/live-icon-images.json
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

func image(_ color: (Double, Double, Double), split: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: 64, height: split ? 32 : 64, bitsPerComponent: 8,
                            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: CGFloat(color.0), green: CGFloat(color.1), blue: CGFloat(color.2), alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    if split {
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
    }
    return context.makeImage()!
}
var values: [String: [String: Any]] = [:]
for (name, type, color, orientation) in [
    ("redPNG", UTType.png, (0.95, 0.08, 0.08), 1),
    ("bluePNG", UTType.png, (0.08, 0.08, 0.95), 1),
    ("greenJPEG", UTType.jpeg, (0.08, 0.85, 0.08), 1),
    ("rotatedJPEG", UTType.jpeg, (0.95, 0.08, 0.08), 6),
    ("yellowGIF", UTType.gif, (0.95, 0.8, 0.08), 1)
] {
    let bytes = NSMutableData()
    let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, type == .gif ? 2 : 1, nil)!
    CGImageDestinationAddImage(destination, image(color, split: orientation == 6),
        [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1,
         kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    if type == .gif { CGImageDestinationAddImage(destination, image((0.08, 0.08, 0.95)), nil) }
    precondition(CGImageDestinationFinalize(destination))
    let data = bytes as Data
    values[name] = ["base64": data.base64EncodedString(), "type": type.preferredMIMEType!, "width": 64,
        "height": orientation == 6 ? 32 : 64, "orientation": orientation, "bytes": data.count,
        "version": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
}
let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted])
print(String(decoding: json, as: UTF8.self))
