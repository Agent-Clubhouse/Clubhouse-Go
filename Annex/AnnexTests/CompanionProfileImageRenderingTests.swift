import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Synthetic pixels exercise the shared face's real cache/task path, without a desktop or provider.
@MainActor final class CompanionProfileImageRenderingTests: XCTestCase {
    func testCustomImageWinsEmojiAndReplacementVersionRepaintsTheSameFace() async throws {
        let host = "profile-image-test-" + UUID().uuidString
        addTeardownBlock { await CompanionIconStore.shared.remove(host: host) }
        let first = try await icon(.red, host: host)

        func face(_ reference: CompanionIconReference) -> some View {
            CompanionIdentityFace(name: "bold-gazelle", color: "rose", emoji: "🌿", icon: reference, size: 48)
                .companionTheme(.clubhouse)
                .environment(\.colorScheme, .light)
                .ignoresSafeArea()
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let hosting = UIHostingController(rootView: face(first))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await expectPixel(in: hosting.view, rgb: [255, 0, 0])

        // Ingest new bytes under the same host/kind/id, as a new snapshot version would do.
        let replacement = try await icon(.blue, host: host)
        XCTAssertEqual(first.id, replacement.id)
        XCTAssertNotEqual(first.version, replacement.version)
        hosting.rootView = face(replacement)
        try await expectPixel(in: hosting.view, rgb: [0, 0, 255])

        // A selected but unavailable image keeps the existing solid-colour initials fallback.
        let missing = CompanionIconReference(host: host, kind: .agent, id: first.id, version: "missing")
        let unavailable = await CompanionIconStore.shared.image(for: missing, points: 48)
        XCTAssertNil(unavailable)
        hosting.rootView = face(missing)
        try await expectPixel(in: hosting.view, rgb: [244, 63, 94]) // rose, above the initials
    }

    private func icon(_ color: UIColor, host: String) async throws -> CompanionIconReference {
        let data = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let reference = await CompanionIconStore.shared.ingest(dataURL: "data:image/png;base64," + data.base64EncodedString(),
                                                              host: host, kind: .agent, id: "same-agent")
        return try XCTUnwrap(reference)
    }

    private func expectPixel(in view: UIView, rgb: [Int], file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var actual: [Int] = []
        repeat {
            view.window?.layoutIfNeeded()
            view.layoutIfNeeded()
            actual = try pixelAboveInitials(in: view)
            if zip(actual, rgb).allSatisfy({ abs($0.0 - $0.1) <= 3 }) { return }
            try await Task.sleep(for: .milliseconds(10)) // Await the face's asynchronous cached-image task.
        } while ContinuousClock.now < deadline
        XCTFail("Expected profile/fallback pixel \(rgb), got \(actual)", file: file, line: line)
    }

    private func pixelAboveInitials(in view: UIView) throws -> [Int] {
        let snapshot = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            view.layer.render(in: context.cgContext)
        }
        let image = try XCTUnwrap(snapshot.cgImage)
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(image.width / 2), y: CGFloat(image.height / 4), width: 1, height: 1)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
    }
}
