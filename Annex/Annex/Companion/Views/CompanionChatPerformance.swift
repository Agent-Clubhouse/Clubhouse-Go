import SwiftUI
import UIKit
import QuartzCore
import ClubhouseTransport

/// Non-observable instrumentation for the frontmost open chat. One display link, paused outside a
/// focused edit's one-second activity tail or a user scroll. Never reads or stores composer content.
@MainActor enum CompanionChatPerformance {
    private static var lease: UInt64 = 0
    private static var active = false
    private static var target: CompanionTarget?
    private static var lastEdit: CFTimeInterval = -.infinity
    private static var scrolling = false
    private static var lastCallback: CFTimeInterval?
    private static var displayLink: CADisplayLink?
    private static let displayTarget = DisplayTarget()
    private static var messages = 0
    private static var visible = 0
    private static var laidOut = 0
    private static let lifecycleObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { suspendActivity() } }

    private static func suspendActivity() {
        lastEdit = -.infinity; scrolling = false; lastCallback = nil
        displayLink?.isPaused = true
    }

    static func start(target: CompanionTarget) -> UInt64 {
        _ = lifecycleObserver
        self.target = target
        lease &+= 1; active = true; lastEdit = -.infinity; scrolling = false
        messages = 0; visible = 0; laidOut = 0
        lastCallback = nil
        displayLink?.invalidate(); displayLink = nil
        return lease
    }
    static func stop(_ owner: UInt64) {
        guard owner == lease else { return }
        active = false; target = nil; lastCallback = nil
        displayLink?.invalidate(); displayLink = nil
    }
    static func edit(target: CompanionTarget, messageCount: Int) {
        guard active, self.target == target, AnnexTelemetry.shared.isEnabled else { return }
        messages = messageCount; lastEdit = CACurrentMediaTime()
        AnnexTelemetry.shared.recordComposerEdit(messageCount: messageCount)
        wakeDisplayLink()
    }
    static func scroll(target: CompanionTarget, isUserScrolling: Bool) {
        guard active, self.target == target else { return }
        scrolling = isUserScrolling
        if scrolling && AnnexTelemetry.shared.isEnabled { wakeDisplayLink() }
    }
    static func viewport(target: CompanionTarget, messageCount: Int, frames: [String: ClosedRange<Double>], offset: Double, height: Double) {
        guard active, self.target == target, AnnexTelemetry.shared.isEnabled else { return }
        messages = messageCount; laidOut = frames.count
        visible = frames.values.reduce(0) { $0 + ($1.upperBound > offset && $1.lowerBound < offset + height ? 1 : 0) }
        AnnexTelemetry.shared.recordPerformance(.chatViewport, durationMs: 0, messageCount: messages, visibleRows: visible, laidOutRows: laidOut)
    }
    static func measureBody<T>(target: CompanionTarget, messageCount: Int, body: () -> T) -> T {
        AnnexTelemetry.shared.measurePerformance(.conversationBody, messageCount: messageCount) {
            if active && self.target == target && CACurrentMediaTime() - lastEdit < 1 {
                AnnexTelemetry.shared.measurePerformance(.typingConversationBody, messageCount: messageCount, body: body)
            } else { body() }
        }
    }
    private static func wakeDisplayLink() {
        if displayLink == nil {
            let link = CADisplayLink(target: displayTarget, selector: #selector(DisplayTarget.tick))
            link.add(to: .main, forMode: .common); displayLink = link
        }
        if displayLink?.isPaused == true { lastCallback = nil; displayLink?.isPaused = false }
    }
    private static func frame() {
        let now = CACurrentMediaTime()
        guard active, UIApplication.shared.applicationState == .active, AnnexTelemetry.shared.isEnabled, scrolling || now - lastEdit < 1 else {
            displayLink?.isPaused = true; lastCallback = nil; return
        }
        if let previous = lastCallback {
            AnnexTelemetry.shared.recordPerformance(.chatDisplayLinkCallbackGap, durationMs: (now - previous) * 1_000,
                messageCount: messages, visibleRows: visible, laidOutRows: laidOut)
        }
        lastCallback = now
    }
    /// No stored state or UI ownership; the process-lifetime target delegates on the main thread.
    private final class DisplayTarget: NSObject {
        nonisolated deinit {}
        @objc func tick() { frame() }
    }
}
