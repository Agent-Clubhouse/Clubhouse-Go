import SwiftUI
import UIKit
import Testing
@testable import ClubhouseGo

@MainActor struct CompanionFeedbackSettingsCaptureTests {
    @Test func dismissalAndReplacementReleasePixelsEvenWhenDestinationRetainsHolder() {
        let first = CompanionFeedbackSettingsCapture(window: nil)
        var current: CompanionFeedbackSettingsCapture? = first
        let presentation = Binding(get: { current }, set: { current = $0 }).releasingFeedbackScreenshot
        weak var pixels: CGImage?
        autoreleasepool {
            first.screenshot = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }.cgImage
            pixels = first.screenshot
            presentation.wrappedValue = first
            #expect(pixels != nil, "An unchanged presentation keeps its pre-Settings capture")

            let replacement = CompanionFeedbackSettingsCapture(window: nil)
            replacement.screenshot = first.screenshot
            presentation.wrappedValue = replacement
            #expect(first.screenshot == nil && pixels != nil)
            presentation.wrappedValue = nil
            #expect(current == nil && replacement.screenshot == nil)
        }
        #expect(pixels == nil)
    }
}
