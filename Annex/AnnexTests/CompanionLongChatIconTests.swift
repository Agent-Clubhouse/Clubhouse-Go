import XCTest
import UIKit
@testable import ClubhouseGo

/// Synthetic main-thread image work, not a claim about the user's original avatars.
@MainActor final class CompanionLongChatIconTests: XCTestCase {
    func testAvatarDecodeWorkload() throws {
        for size in [64, 1024] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
                for y in stride(from: 0, to: size, by: 4) {
                    UIColor(hue: CGFloat(y) / CGFloat(size), saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: y, width: size, height: 4))
                }
            }
            let data = try XCTUnwrap(image.pngData())
            let started = Date()
            for _ in 0..<200 {
                try autoreleasepool {
                    let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
                    let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8,
                        bytesPerRow: 24 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(decoded, in: CGRect(x: 0, y: 0, width: 24, height: 24))
                }
            }
            print("LONG_CHAT_ICON pixels=\(size)x\(size) compressedBytes=\(data.count) decodedRGBABytes=\(size * size * 4) decodeAndDraw200Ms=\(Date().timeIntervalSince(started) * 1000)")
        }
    }
}
