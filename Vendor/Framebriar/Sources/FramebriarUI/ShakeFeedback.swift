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
import SwiftUI
import UIKit

extension View {
    /// Optional local motion shortcut. Opens the composer; never submits anything.
    /// With `captureScreen`, the key window is captured on the device before the composer opens and is
    /// pre-attached for review. The user can remove or replace it; it is sent only on Submit. No capture
    /// is taken while a secure text field is first responder.
    /// Install once at the scene root. Host presentation flags cover SwiftUI's pre-presentation window;
    /// UIKit checks also suppress this shortcut for nested sheets, alerts, pickers and text input.
    public func shakeToOpenFeedback(model: FeedbackModel?, enabled: Bool, isPresenting: Bool = false,
                                    captureScreen: Bool = true) -> some View {
        modifier(ShakeFeedbackModifier(model: model, enabled: enabled, isPresenting: isPresenting, captureScreen: captureScreen))
    }
}

private struct ShakeFeedbackModifier: ViewModifier {
    let model: FeedbackModel?
    let enabled: Bool
    let isPresenting: Bool
    let captureScreen: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingComposer = false
    @State private var capturedPNG: Data?
    @State private var gate = ShakeFeedbackGate()

    func body(content: Content) -> some View {
        content
            .background {
                if model != nil {
                    ShakeMotionReceiver(enabled: enabled && scenePhase == .active && model?.status?.canSubmit == true,
                                        hostIsPresenting: isPresenting || showingComposer) { presenting, editing, capture in
                        guard gate.shouldOpen(at: ProcessInfo.processInfo.systemUptime,
                                              enabled: enabled, canSubmit: model?.status?.canSubmit == true,
                                              isActive: scenePhase == .active,
                                              isPresenting: presenting || isPresenting || showingComposer,
                                              isEditing: editing) else { return false }
                        // Capture before presenting so the composer itself is never in the image.
                        capturedPNG = captureScreen ? capture() : nil
                        showingComposer = true
                        return true
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: showingComposer) { _, showing in
                if !showing { capturedPNG = nil; recordPresentationBoundary() }
            }
            .onChange(of: isPresenting) { _, _ in recordPresentationBoundary() }
            .sheet(isPresented: $showingComposer) {
                if let model { NavigationStack { FeedbackView(model: model, initialScreenshotPNG: capturedPNG) } }
            }
    }
    private func recordPresentationBoundary() {
        _ = gate.shouldOpen(at: ProcessInfo.processInfo.systemUptime, enabled: enabled,
                            canSubmit: model?.status?.canSubmit == true, isActive: scenePhase == .active,
                            isPresenting: true, isEditing: false)
    }
}

private struct ShakeMotionReceiver: UIViewControllerRepresentable {
    let enabled: Bool
    let hostIsPresenting: Bool
    /// (presenting, editing, capture) -> handled. `capture` applies the screenshot policy and returns a PNG or nil.
    let onShake: @MainActor (Bool, Bool, @MainActor () -> Data?) -> Bool
    func makeUIViewController(context: Context) -> MotionController { MotionController() }
    func updateUIViewController(_ controller: MotionController, context: Context) {
        controller.enabled = enabled
        controller.hostIsPresenting = hostIsPresenting
        controller.onShake = onShake
        controller.updateEligibility()
    }
    static func dismantleUIViewController(_ controller: MotionController, coordinator: ()) { controller.stop() }

    @MainActor final class MotionController: UIViewController {
        var enabled = false
        var hostIsPresenting = false
        var onShake: (@MainActor (Bool, Bool, @MainActor () -> Data?) -> Bool)?
        private var observers: [NSObjectProtocol] = []
        private var rearmTask: Task<Void, Never>?
        override var canBecomeFirstResponder: Bool { enabled && !hostIsPresenting }
        override func loadView() { view = UIView(); view.backgroundColor = .clear }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateEligibility() }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); rearmTask?.cancel(); resignFirstResponder() }
        override func viewDidLoad() {
            super.viewDidLoad()
            for name in [UIResponder.keyboardDidHideNotification, UIWindow.didBecomeKeyNotification, UIApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.updateEligibility() }
                })
            }
        }
        func stop() {
            enabled = false; onShake = nil; rearmTask?.cancel(); rearmTask = nil; resignFirstResponder()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
        func updateEligibility() {
            rearmTask?.cancel(); rearmTask = nil
            guard enabled, !hostIsPresenting, let window = viewIfLoaded?.window, window.isKeyWindow,
                  window.windowScene?.activationState == .foregroundActive, !Self.isEditing(window) else {
                resignFirstResponder(); return
            }
            if claimResponderIfAvailable() { return }
            // SwiftUI can clear a sheet binding before UIKit marks the dismissal transition.
            // Retry only across this bounded handoff (at most 3 s), never continuously poll motion
            // or take first responder away from text input. A subsequent view/lifecycle update
            // can rearm again if UIKit was still busy after that interval.
            rearmTask = Task { @MainActor [weak self] in
                for _ in 0..<30 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard !Task.isCancelled, let self, self.enabled, !self.hostIsPresenting,
                          let window = self.viewIfLoaded?.window, window.isKeyWindow,
                          window.windowScene?.activationState == .foregroundActive,
                          !Self.isEditing(window) else { return }
                    if self.claimResponderIfAvailable() { return }
                }
            }
        }
        private func claimResponderIfAvailable() -> Bool {
            guard let window = viewIfLoaded?.window, !Self.hasPresentation(window.rootViewController) else {
                resignFirstResponder(); return false
            }
            return isFirstResponder || becomeFirstResponder()
        }
        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake, enabled, let window = viewIfLoaded?.window,
                  window.isKeyWindow, window.windowScene?.activationState == .foregroundActive else {
                super.motionEnded(motion, with: event); return
            }
            let presenting = hostIsPresenting || Self.hasPresentation(window.rootViewController)
            let capture: @MainActor () -> Data? = { [weak window] in window.flatMap(Self.capture) }
            if onShake?(presenting, Self.isEditing(window), capture) != true { super.motionEnded(motion, with: event) }
        }
        /// Renders what is currently on screen without forcing a new layout pass, then encodes it within the caps.
        private static func capture(_ window: UIWindow) -> Data? {
            guard ShakeScreenshot.shouldCapture(captureScreen: true, secureFieldActive: hasSecureFirstResponder(window)),
                  window.bounds.width > 0, window.bounds.height > 0 else { return nil }
            let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            return image.cgImage.flatMap { ShakeScreenshot.encodePNG($0) }
        }
        private static func hasSecureFirstResponder(_ view: UIView) -> Bool {
            if view.isFirstResponder,
               (view as? UITextField)?.isSecureTextEntry == true || (view as? UITextView)?.isSecureTextEntry == true { return true }
            return view.subviews.contains { hasSecureFirstResponder($0) }
        }
        private static func hasPresentation(_ controller: UIViewController?) -> Bool {
            guard let controller else { return false }
            if controller.presentedViewController != nil || controller.isBeingPresented || controller.isBeingDismissed { return true }
            return controller.children.contains { hasPresentation($0) }
        }
        private static func isEditing(_ view: UIView) -> Bool {
            if view.isFirstResponder && view is any UIKeyInput { return true }
            return view.subviews.contains { isEditing($0) }
        }
    }
}
#endif
