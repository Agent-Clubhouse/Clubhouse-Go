import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Synthetic pixels exercise the shared face's real cache/task path, without a desktop or provider.
@MainActor final class CompanionProfileImageRenderingTests: XCTestCase {
    func testCustomImageWinsEmojiAndReplacementVersionRepaintsTheSameFace() async throws {
        let host = "profile-image-test-" + UUID().uuidString
        do {
            try await checkProfileImageRendering(host: host)
        } catch {
            await CompanionIconStore.shared.remove(host: host)
            throw error
        }
        await CompanionIconStore.shared.remove(host: host)
    }

    private func checkProfileImageRendering(host: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "Requires a foreground-active hosted test scene")
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let first = try await icon(.red, host: host)

        func face(_ reference: CompanionIconReference) -> some View {
            CompanionIdentityFace(name: "bold-gazelle", color: "rose", emoji: "🌿", icon: reference, size: 48)
                .companionTheme(.clubhouse)
                .environment(\.colorScheme, .light)
                .ignoresSafeArea()
        }

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        let hosting = UIHostingController(rootView: face(first))
        window.rootViewController = hosting
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        try await expectPixel(in: hosting.view, rgb: [255, 0, 0])

        // Ingest new bytes under the same host/kind/id, as a new snapshot version would do.
        let replacement = try await icon(.blue, host: host)
        XCTAssertEqual(first.id, replacement.id)
        XCTAssertNotEqual(first.version, replacement.version)
        hosting.rootView = face(replacement)
        try await expectPixel(in: hosting.view, rgb: [0, 0, 255])

        // A valid SHA-256 version with no cached bytes or fetcher keeps the initials fallback.
        let absentVersion = CompanionIconReference.digest(Data("absent synthetic profile image".utf8))
        let missing = CompanionIconReference(host: host, kind: .agent, id: first.id, version: absentVersion)
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
        let snapshot = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            // SwiftUI can defer display after layout and the cached-image task have completed.
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
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
