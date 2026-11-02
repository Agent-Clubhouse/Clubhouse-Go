import Foundation

/// Pure event policy, separated from UIKit so timing and presentation races are deterministic in tests.
/// Uses a monotonic timestamp. Suppressed motion during a presentation also restarts the cooldown.
public struct ShakeFeedbackGate: Sendable {
    private var lastMotion: TimeInterval?
    public init() {}

    public mutating func shouldOpen(at time: TimeInterval, enabled: Bool, canSubmit: Bool,
                                    isActive: Bool, isPresenting: Bool, isEditing: Bool) -> Bool {
        guard time.isFinite, time >= 0, enabled, canSubmit, isActive else { return false }
        let previous = lastMotion
        lastMotion = time
        guard !isPresenting, !isEditing else { return false }
        if let previous, time - previous < 2 { return false }
        return true
    }
}

#if os(iOS)
import ObjectiveC
import SwiftUI
import UIKit

/// A shake the SDK accepted. Present from `window` and use `screenshotPNG` as is: it was captured from
/// that window before anything opened, and is nil if capture is off, failed, or a secure field is active.
@MainActor public struct FeedbackShakeEvent {
    public let window: UIWindow
    public let screenshotPNG: Data?
}

extension View {
    /// Calls `perform` for an accepted shake so a host can route to its own presenter. Never submits.
    /// Install once at the scene root. Works over sheets without taking first responder (see the README).
    /// A shake is ignored while any text input is active, so it never moves focus or disturbs a draft.
    /// - Parameters:
    ///   - isPresenting: suppress shakes right now, e.g. during pairing or restore. Don't include ordinary sheets.
    ///   - captureScreen: render the key window into `event.screenshotPNG`.
    ///   - onNotEnrolled: called instead of `perform` when the user can't file feedback yet.
    public func onFeedbackShake(model: FeedbackModel?, enabled: Bool, isPresenting: Bool = false, captureScreen: Bool = true,
                                onNotEnrolled: (@MainActor () -> Void)? = nil,
                                perform: @escaping @MainActor (FeedbackShakeEvent) -> Void) -> some View {
        modifier(ShakeFeedbackModifier(model: model, enabled: enabled, isPresenting: isPresenting, captureScreen: captureScreen,
                                       onNotEnrolled: onNotEnrolled, perform: perform))
    }

    /// Optional local motion shortcut that presents the composer over whatever is showing, including
    /// sheets. Opens the composer; never submits anything. Same rules as `onFeedbackShake`.
    public func shakeToOpenFeedback(model: FeedbackModel?, enabled: Bool, isPresenting: Bool = false,
                                    captureScreen: Bool = true) -> some View {
        onFeedbackShake(model: model, enabled: enabled, isPresenting: isPresenting, captureScreen: captureScreen) { event in
            guard let model else { return }
            ShakeWindowInspector.presentComposer(model: model, event: event)
        }
    }
}

private struct ShakeFeedbackModifier: ViewModifier {
    let model: FeedbackModel?
    let enabled: Bool
    let isPresenting: Bool
    let captureScreen: Bool
    let onNotEnrolled: (@MainActor () -> Void)?
    let perform: @MainActor (FeedbackShakeEvent) -> Void

    func body(content: Content) -> some View {
        content.background {
            if let model {
                ShakeAnchor(model: model, enabled: enabled, isPresenting: isPresenting, captureScreen: captureScreen,
                            onNotEnrolled: onNotEnrolled, perform: perform)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

/// Marks where a modifier lives, so a shake reaches only the coordinator for its own scene.
private struct ShakeAnchor: UIViewRepresentable {
    let model: FeedbackModel
    let enabled: Bool
    let isPresenting: Bool
    let captureScreen: Bool
    let onNotEnrolled: (@MainActor () -> Void)?
    let perform: @MainActor (FeedbackShakeEvent) -> Void

    func makeCoordinator() -> ShakeCoordinator { ShakeCoordinator() }
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView(); view.isHidden = true
        view.coordinator = context.coordinator
        ShakeRouter.shared.add(context.coordinator)
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model; coordinator.enabled = enabled; coordinator.captureScreen = captureScreen
        coordinator.onNotEnrolled = onNotEnrolled; coordinator.perform = perform
        coordinator.setSuppressed(isPresenting || model.isComposerOpen)
        coordinator.scene = view.window?.windowScene ?? coordinator.scene
    }
    static func dismantleUIView(_ view: AnchorView, coordinator: ShakeCoordinator) { ShakeRouter.shared.remove(coordinator) }

    final class AnchorView: UIView {
        weak var coordinator: ShakeCoordinator?
        // Keeps the last scene: a full-screen cover takes the presenter's views out of the window.
        override func didMoveToWindow() { super.didMoveToWindow(); if let scene = window?.windowScene { coordinator?.scene = scene } }
    }
}

/// Applies the guards for one installed modifier.
@MainActor final class ShakeCoordinator {
    weak var model: FeedbackModel?
    weak var scene: UIWindowScene?
    var enabled = false
    var captureScreen = true
    var onNotEnrolled: (@MainActor () -> Void)?
    var perform: (@MainActor (FeedbackShakeEvent) -> Void)?
    private var suppressed = false
    private var gate = ShakeFeedbackGate()

    /// A presentation ending restarts the cooldown, so a shake used to dismiss can't reopen at once.
    func setSuppressed(_ value: Bool) {
        if suppressed != value { markBoundary() }
        suppressed = value
    }
    private func markBoundary() {
        _ = gate.shouldOpen(at: ProcessInfo.processInfo.systemUptime, enabled: true, canSubmit: true, isActive: true, isPresenting: true, isEditing: false)
    }

    func resetCooldownForTesting() { gate = ShakeFeedbackGate() }

    /// True when this shake was acted on, opening feedback or explaining enrollment.
    func handle(_ window: UIWindow) -> Bool {
        guard let model, let status = model.status, let scene, window.windowScene === scene else { return false }
        let presenting = suppressed || model.isComposerOpen || ShakeWindowInspector.isBusy(window)
        let editing = ShakeWindowInspector.hasActiveTextInput(window)
        let open = gate.shouldOpen(at: ProcessInfo.processInfo.systemUptime, enabled: enabled, canSubmit: status.canSubmit || onNotEnrolled != nil,
                                   isActive: scene.activationState == .foregroundActive, isPresenting: presenting, isEditing: editing)
        guard open else { return false }
        guard status.canSubmit else { onNotEnrolled?(); return true }
        // Capture before presenting so the composer itself is never in the image.
        perform?(FeedbackShakeEvent(window: window, screenshotPNG: captureScreen ? ShakeWindowInspector.capture(window) : nil))
        return true
    }
}

/// One shake, one action: only the key window of a foreground-active scene counts, a shake is handled
/// once in the run-loop turn that delivers it however many windows forward it, and the first coordinator
/// for the scene to act ends the walk. (`UIEvent.timestamp` isn't used: it didn't change between
/// shakes on the simulator, which rejected every shake after the first.)
@MainActor final class ShakeRouter {
    static let shared = ShakeRouter()
    private final class Weak { weak var value: ShakeCoordinator?; init(_ value: ShakeCoordinator) { self.value = value } }
    private var coordinators: [Weak] = []
    private var routedThisTurn = false

    func add(_ coordinator: ShakeCoordinator) {
        ShakeWindowHook.install()
        coordinators.removeAll { $0.value == nil }
        coordinators.append(Weak(coordinator))
    }
    func remove(_ coordinator: ShakeCoordinator) { coordinators.removeAll { $0.value == nil || $0.value === coordinator } }

    @discardableResult func route(window: UIWindow) -> Bool {
        guard Self.accepts(isKeyWindow: window.isKeyWindow, sceneActive: window.windowScene?.activationState == .foregroundActive,
                           alreadyRouted: routedThisTurn) else { return false }
        routedThisTurn = true
        DispatchQueue.main.async { [weak self] in self?.routedThisTurn = false }
        for coordinator in coordinators.compactMap(\.value) where coordinator.handle(window) { return true }
        return false
    }
    nonisolated static func accepts(isKeyWindow: Bool, sceneActive: Bool, alreadyRouted: Bool) -> Bool {
        isKeyWindow && sceneActive && !alreadyRouted
    }
}

/// Adds a `motionEnded` implementation to `UIWindow` once, at first use. It reports shakes, then calls
/// whatever implementation `UIWindow` already resolved to, exactly once, so the responder chain and any
/// existing override carry on unchanged. Nothing else is touched. Every window of the app passes through
/// here, and a window subclass that overrides `motionEnded` without calling super hides the event.
enum ShakeWindowHook {
    private typealias Original = @convention(c) (AnyObject, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
    private static let selector = #selector(UIResponder.motionEnded(_:with:))
    private static let installed: Bool = { wrap(UIWindow.self) { window in ShakeRouter.shared.route(window: window) } }()

    /// `static let` initialization is thread-safe and runs once.
    static func install() { _ = installed }

    /// Wraps `cls`'s `motionEnded`. Internal so tests can check both a class that inherits it and one that overrides it.
    @discardableResult
    static func wrap(_ cls: AnyClass, onShake: @escaping @MainActor (UIWindow) -> Void) -> Bool {
        guard let method = class_getInstanceMethod(cls, selector) else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let selector = selector
        let block: @convention(block) (AnyObject, UIEvent.EventSubtype, UIEvent?) -> Void = { object, motion, event in
            if motion == .motionShake, let window = object as? UIWindow {
                MainActor.assumeIsolated { onShake(window) }
            }
            original(object, selector, motion, event)
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) { method_setImplementation(method, implementation) }
        return true
    }
}

/// Read-only checks of what a window is showing, plus the capture and default presentation.
@MainActor enum ShakeWindowInspector {
    static func topmost(_ window: UIWindow) -> UIViewController? {
        var top = window.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
    /// Mid-transition, or an alert that a sheet shouldn't cover.
    static func isBusy(_ window: UIWindow) -> Bool {
        guard let top = topmost(window) else { return true }
        return top is UIAlertController || top.isBeingPresented || top.isBeingDismissed
    }
    static func hasActiveTextInput(_ view: UIView) -> Bool {
        if view.isFirstResponder && view is any UIKeyInput { return true }
        return view.subviews.contains { hasActiveTextInput($0) }
    }
    static func hasSecureInput(_ view: UIView) -> Bool {
        if view.isFirstResponder,
           (view as? UITextField)?.isSecureTextEntry == true || (view as? UITextView)?.isSecureTextEntry == true { return true }
        return view.subviews.contains { hasSecureInput($0) }
    }
    /// Renders what is currently on screen without forcing a new layout pass, then encodes it within the caps.
    static func capture(_ window: UIWindow) -> Data? {
        guard ShakeScreenshot.shouldCapture(captureScreen: true, secureFieldActive: hasSecureInput(window)),
              window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.cgImage.flatMap { ShakeScreenshot.encodePNG($0) }
    }
    static func presentComposer(model: FeedbackModel, event: FeedbackShakeEvent) {
        guard let top = topmost(event.window) else { return }
        // A hosting controller, because a SwiftUI sheet on the root can't open over another sheet.
        let host = UIHostingController(rootView: NavigationStack {
            FeedbackView(model: model, initialScreenshotPNG: event.screenshotPNG) { [weak top] in top?.dismiss(animated: true) }
        })
        top.present(host, animated: true)
    }
}
#endif
