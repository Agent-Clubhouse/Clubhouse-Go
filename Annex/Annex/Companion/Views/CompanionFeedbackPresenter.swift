import SwiftUI
import UIKit
#if DEBUG
import CryptoKit
#endif
import Framebriar
import FramebriarUI

extension EnvironmentValues {
    /// Opens feedback, or explains enrollment. Nil when the build has no feedback.
    @Entry var companionSendFeedback: (@MainActor () -> Void)?
}

/// Transfer Settings and its pre-sheet image together, rather than racing a Boolean sheet binding
/// against a separate @State value. A nil image still opens Settings; dismissal releases the item.
final class CompanionFeedbackSettingsCapture: Identifiable {
    let id: UUID = UUID()
    var screenshot: CGImage?
    let screenshotUnavailable: FeedbackScreenshotUnavailable?
    init(window: UIWindow?) {
        let capture = CompanionFeedbackPresenter.freezeExpected(window)
        screenshot = capture.image; screenshotUnavailable = capture.unavailable
    }
    nonisolated deinit {}
}

extension Binding where Value == CompanionFeedbackSettingsCapture? {
    /// View disappearance can mean navigation or a temporary cover. Release only when the
    /// presentation is actually dismissed/replaced, including a swipe or a programmatic close.
    var releasingFeedbackScreenshot: Self {
        Binding(get: { wrappedValue }, set: { next in
            if next?.id != wrappedValue?.id { wrappedValue?.screenshot = nil }
            wrappedValue = next
        })
    }
}

/// Feedback entry points that don't depend on a gesture: the "Send feedback" menu items and the offer
/// shown after an iOS screenshot. Presents over whatever is on screen (sheets, Review), so a trigger
/// from any screen reaches the same composer. Captures stay on the phone until the person submits.
@MainActor final class CompanionFeedbackPresenter {
    static let promptDuration: Duration = .seconds(8)
    let model: FeedbackModel?
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var statusTask: Task<Void, Never>?
    private var screenshotLifecycle = CompanionScreenshotPromptLifecycle()
    private var screenshotData: Data?
    private var screenshotUnavailable: FeedbackScreenshotUnavailable?
    private var menuScreenshot: CGImage?
    private var menuScreenshotUnavailable: FeedbackScreenshotUnavailable?
    private weak var menuSource: UIControl?
    private weak var menuWindow: UIWindow?
    private weak var screenshotScene: UIWindowScene?
    private weak var screenshotWindow: UIWindow?
    private var explainedThisSession = false
    private var promptWindow: UIWindow?
    private var promptTask: Task<Void, Never>?
    /// Composer, enrollment or explainer currently presented by this presenter.
    private weak var presented: UIViewController?

    init(model: FeedbackModel?, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenshotTaken() }
        })
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let scene = note.object as? UIWindowScene else { return }
                    if scene === self.menuWindow?.windowScene, name != UIScene.didActivateNotification { self.discardMenuFeedback() }
                    guard scene === self.screenshotScene else { return }
                    if name == UIScene.didDisconnectNotification { self.dismissPrompt() }
                    else if name == UIScene.willDeactivateNotification { self.hidePrompt() }
                    else { self.resumeScreenshotOffer() }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    /// Called on the opening press, before UIKit puts the menu over the app. A nil capture
    /// replaces any older one too: a secure field or failure must never reuse another screen.
    func prepareMenuFeedback(in window: UIWindow, source: UIControl) {
        guard let model, !model.isComposerOpen, presented == nil else {
            discardMenuFeedback()
            return
        }
        menuWindow = window
        menuSource = source
        let capture = Self.freezeExpected(window)
        menuScreenshot = capture.image; menuScreenshotUnavailable = capture.unavailable
        #if DEBUG
        // Isolated fixture: simulate the source ending its highlight before selection.
        if ProcessInfo.processInfo.arguments.contains("--framebriar-wire-ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--feedback-early-highlight-end") { discardMenuFeedback(from: source) }
        #endif
    }

    func sendMenuFeedback() {
        let screenshot = menuScreenshot, unavailable = menuScreenshotUnavailable, window = menuWindow
        discardMenuFeedback()
        sendFeedback(screenshotUnavailable: unavailable, frozenImage: screenshot, from: window)
    }

    /// Ignore a late dismissal from another menu. The selected action consumes its image first.
    func discardMenuFeedback(from source: UIControl? = nil) {
        guard source == nil || source === menuSource else { return }
        menuScreenshot = nil
        // A premature highlight-end must still allow text-only feedback from its source window.
        if source == nil { menuWindow = nil; menuSource = nil; menuScreenshotUnavailable = nil }
    }

    /// Resolve the local enrollment status before choosing a route, including at cold launch.
    func sendFeedback(screenshotPNG: Data? = nil, screenshotUnavailable: FeedbackScreenshotUnavailable? = nil, frozenImage: CGImage? = nil, from sourceWindow: UIWindow? = nil, fromShake: Bool = false) {
        guard let model, presented == nil else { return }
        dismissPrompt()
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            if model.status == nil { await model.update() }
            guard let self, !Task.isCancelled, self.presented == nil else { return }
            if model.status?.canSubmit == true {
                let png = frozenImage == nil ? screenshotPNG : await Self.encode(frozenImage)
                guard !Task.isCancelled, self.presented == nil else { return }
                self.presentComposer(screenshot: png, screenshotUnavailable: screenshotUnavailable ?? (frozenImage != nil && png == nil ? .failed : nil), from: sourceWindow)
            } else { self.explainEnrollment(fromScreenshot: false, fromShake: fromShake) }
        }
    }

    func screenshotTaken() {
        // An inactive window is usable only as a capture source. Never present into its scene.
        guard let window = Self.keyWindow(allowInactive: true) else { return }
        let decision = CompanionScreenshotFeedback.decide(enabled: CompanionScreenshotFeedback.isEnabled(defaults), configured: model != nil,
            canSubmit: model?.status.map(\.canSubmit), secureFieldActive: Self.hasSecureFirstResponder(window),
            explainedThisSession: explainedThisSession, busy: presented != nil)
        guard decision != .ignore else { return }
        dismissPrompt()
        screenshotData = Self.capture(window)
        screenshotUnavailable = screenshotData == nil ? .failed : nil
        screenshotScene = window.windowScene
        screenshotWindow = window
        _ = screenshotLifecycle.request(active: false, ready: false)
        if decision == .waitForStatus, let model {
            statusTask?.cancel()
            statusTask = Task { [weak self] in
                await model.update()
                guard !Task.isCancelled else { return }
                self?.resumeScreenshotOffer()
            }
        } else { resumeScreenshotOffer() }
    }

    private func resumeScreenshotOffer() {
        guard screenshotLifecycle.pending, let scene = screenshotScene,
              scene.activationState == .foregroundActive else { return }
        let decision = CompanionScreenshotFeedback.decide(enabled: CompanionScreenshotFeedback.isEnabled(defaults), configured: model != nil,
            canSubmit: model?.status.map(\.canSubmit), secureFieldActive: scene.windows.contains(where: Self.hasSecureFirstResponder),
            explainedThisSession: explainedThisSession, busy: presented != nil)
        switch decision {
        case .ignore: dismissPrompt()
        case .waitForStatus: break
        case .explainEnrollment: dismissPrompt(); explainEnrollment(fromScreenshot: true)
        case .offer:
            if screenshotLifecycle.resume(active: true, ready: true) == .show {
                showPrompt(screenshot: screenshotData, in: scene)
            }
        }
    }

    // MARK: Prompt

    private func showPrompt(screenshot: Data?, in scene: UIWindowScene?) {
        guard let scene, scene.activationState == .foregroundActive else { return }
        hidePrompt()
        _ = screenshotLifecycle.resume(active: true, ready: true)
        let window = PassthroughWindow(windowScene: scene)
        let sourceWindow = screenshotWindow
        let unavailable = screenshotUnavailable
        let prompt = CompanionScreenshotFeedbackPrompt(
            frameChanged: { [weak window] in window?.interactiveFrame = $0 },
            // Present before closing: closing releases this prompt and the closure that holds the capture.
            open: { [weak self] in self?.presentComposer(screenshot: screenshot, screenshotUnavailable: unavailable, from: sourceWindow); self?.dismissPrompt() },
            close: { [weak self] in self?.dismissPrompt() })
        let host = UIHostingController(rootView: prompt)
        host.view.backgroundColor = .clear
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.isHidden = false
        promptWindow = window
        promptTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.promptDuration) } catch { return }
            self?.dismissPrompt()
        }
    }

    private func dismissPrompt() {
        screenshotLifecycle.dismiss()
        screenshotData = nil
        screenshotUnavailable = nil
        screenshotScene = nil
        screenshotWindow = nil
        hidePrompt()
    }

    private func hidePrompt() {
        _ = screenshotLifecycle.resume(active: false, ready: false)
        promptTask?.cancel(); promptTask = nil
        promptWindow?.isHidden = true
        promptWindow = nil
    }

    // MARK: Presentation

    private func presentComposer(screenshot: Data?, screenshotUnavailable: FeedbackScreenshotUnavailable? = nil, from sourceWindow: UIWindow? = nil) {
        guard let model else { return }
        guard presented == nil, !model.isComposerOpen else { return }
        let host = UIHostingController(rootView: NavigationStack {
            CompanionFeedbackComposer(model: model, initialScreenshotPNG: screenshot, screenshotUnavailable: screenshotUnavailable, onClose: { [weak self] in
                self?.presented?.dismiss(animated: true)
            })
        })
        present(host, from: sourceWindow)
    }

    private func explainEnrollment(fromScreenshot: Bool, fromShake: Bool = false) {
        guard let model else { return }
        if fromScreenshot { explainedThisSession = true }
        let alert = UIAlertController(title: "Feedback enrollment required",
                                      message: fromScreenshot
                                        ? "Clubhouse Go can turn a screenshot into feedback after you redeem a feedback invitation in Settings → Invitation & enrollment."
                                        : "Send feedback after you redeem a feedback invitation in Settings → Invitation & enrollment.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Set up feedback", style: .default) { [weak self] _ in
            let enrollment = UIHostingController(rootView: CompanionEnrollmentSheet(model: model))
            self?.present(enrollment)
        })
        if fromScreenshot {
            alert.addAction(UIAlertAction(title: "Don't offer for screenshots", style: .default) { [weak self] _ in
                self?.defaults.set(false, forKey: CompanionScreenshotFeedback.preferenceKey)
            })
        }
        if fromShake {
            alert.addAction(UIAlertAction(title: "Turn off shake", style: .default) { [weak self] _ in
                self?.defaults.set(false, forKey: CompanionFeedback.shakePreferenceKey)
            })
        }
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
        present(alert)
    }

    private func present(_ controller: UIViewController, from sourceWindow: UIWindow? = nil) {
        guard let window = sourceWindow ?? Self.keyWindow(), window.windowScene?.activationState == .foregroundActive,
              let root = window.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        presented = controller
        top.present(controller, animated: true)
    }

    // MARK: Window

    static func keyWindow(allowInactive: Bool = false) -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (active.isEmpty && allowInactive ? scenes : active).flatMap(\.windows).filter { !($0 is PassthroughWindow) && !$0.isHidden }
        return windows.first(where: \.isKeyWindow) ?? windows.first { $0.windowLevel == .normal }
    }

    /// What is on screen now, within the SDK's size caps; nil while a password field is in use.
    static func capture(_ window: UIWindow) -> Data? { freeze(window).flatMap { ShakeScreenshot.encodePNG($0) } }

    /// UIKit rendering must run on MainActor. Keep these immutable pixels frozen without PNG work.
    static func freezeExpected(_ window: UIWindow?) -> (image: CGImage?, unavailable: FeedbackScreenshotUnavailable?) {
        guard let window else { return (nil, .failed) }
        guard !hasSecureFirstResponder(window) else { return (nil, .secureField) }
        guard let image = freeze(window) else { return (nil, .failed) }
        return (image, nil)
    }

    static func freeze(_ window: UIWindow) -> CGImage? {
        #if DEBUG
        // Isolated fake-wire UI test only: exercise the same nil path as a failed renderer.
        if ProcessInfo.processInfo.arguments.contains("--framebriar-wire-ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--feedback-capture-failure") { return nil }
        #endif
        guard ShakeScreenshot.shouldCapture(captureScreen: true, secureFieldActive: hasSecureFirstResponder(window)),
              window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.opaque = true
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard rendered else { return nil }
        #if DEBUG
        lastFrozenImage = image.cgImage
        #endif
        return image.cgImage
    }

    static func encode(_ image: CGImage?) async -> Data? {
        guard let image else { return nil }
        #if DEBUG
        deferredPNGEncodes += 1
        #endif
        return await Task.detached(priority: .userInitiated) { encodePixels(image) }.value
    }

    nonisolated private static func encodePixels(_ image: CGImage) -> Data? {
        assert(!Thread.isMainThread)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--framebriar-wire-ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--feedback-encode-failure") { return nil }
        #endif
        return ShakeScreenshot.encodePNG(image)
    }

    #if DEBUG
    private(set) static var fixtureInitialScreenshotSHA: String?
    static func recordFixtureScreenshot(_ png: Data?) {
        guard ProcessInfo.processInfo.arguments.contains("--framebriar-wire-ui-testing") else { return }
        fixtureInitialScreenshotSHA = png.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
    private static weak var lastFrozenImage: CGImage?
    private static var deferredPNGEncodes = 0
    var fixtureCaptureState: String {
        "Pending: \(menuScreenshot != nil) · Alive: \(Self.lastFrozenImage != nil) · Encodes: \(Self.deferredPNGEncodes)"
    }
    #endif

    static func hasSecureFirstResponder(_ view: UIView) -> Bool {
        if view.isFirstResponder,
           (view as? UITextField)?.isSecureTextEntry == true || (view as? UITextView)?.isSecureTextEntry == true { return true }
        return view.subviews.contains { hasSecureFirstResponder($0) }
    }
}

/// Lets touches outside the prompt reach the app underneath. SwiftUI buttons have no views of their
/// own, so the prompt reports where it is instead.
private final class PassthroughWindow: UIWindow {
    var interactiveFrame: CGRect = .zero
    /// The app's window stays key, so text input and the shake receiver are undisturbed.
    override var canBecomeKey: Bool { false }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { interactiveFrame.contains(point) }
}

private struct CompanionScreenshotFeedbackPrompt: View {
    let frameChanged: (CGRect) -> Void
    let open: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                Label("Send feedback with this screenshot?", systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.semibold)).padding(.leading, 16).padding(.vertical, 12)
            }
            .accessibilityIdentifier("screenshot-feedback-prompt")
            Button("Dismiss", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly).padding(12)
                .accessibilityIdentifier("screenshot-feedback-dismiss")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frameChanged($0) }
        .padding(.top, 8).padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The same enrollment screen Settings opens, with a way back.
struct CompanionEnrollmentSheet: View {
    let model: FeedbackModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CompanionFeedbackEnrollment(model: model).toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension View {
    /// Installs the menu action for this subtree. Screenshots are observed by the presenter itself.
    func companionFeedbackEntryPoints(_ presenter: CompanionFeedbackPresenter?) -> some View {
        var action: (@MainActor () -> Void)?
        if let presenter, presenter.model != nil { action = { [weak presenter] in presenter?.sendMenuFeedback() } }
        return environment(\.companionSendFeedback, action)
            .background {
                CompanionFeedbackMenuCapture(presenter: presenter).allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

/// Observe the app window, because native toolbar Menus discard SwiftUI source backgrounds and
/// gestures. Only the explicitly tagged menu controls trigger capture. The passive recognizer
/// yields immediately; the native menu event also covers activation without a physical touch.
private struct CompanionFeedbackMenuCapture: UIViewRepresentable {
    let presenter: CompanionFeedbackPresenter?
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ view: Anchor, context: Context) {
        view.presenter = presenter
        // Toolbar controls can be installed later in this SwiftUI update.
        DispatchQueue.main.async { [weak view] in view?.connectControls() }
    }
    static func dismantleUIView(_ view: Anchor, coordinator: ()) { view.disconnect() }

    final class Anchor: UIView {
        weak var presenter: CompanionFeedbackPresenter?
        private let press = CompanionFeedbackOpeningPress()
        private weak var observedWindow: UIWindow?
        private let controls = NSHashTable<UIControl>.weakObjects()
        private let highlightObservations = NSMapTable<UIControl, NSKeyValueObservation>.weakToStrongObjects()
        private var lastPress: TimeInterval = -.infinity
        private static let sources: Set<String> = ["home-more-menu", "conversation-actions-menu", "fixture-feedback-menu"]
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            press.anchor = self
            press.cancelsTouchesInView = false
            press.delaysTouchesBegan = false
            press.delaysTouchesEnded = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            disconnect()
            if let window { observedWindow = window; window.addGestureRecognizer(press); connectControls() }
        }
        override func layoutSubviews() { super.layoutSubviews(); connectControls() }
        private static func isSource(_ view: UIView) -> Bool {
            view.accessibilityIdentifier.map(sources.contains) == true
        }
        func connectControls() {
            guard let window else { return }
            func visit(_ view: UIView) {
                if let control = view as? UIControl, Self.isSource(control), !controls.contains(control) {
                    control.addTarget(self, action: #selector(menuWillOpen(_:)), for: .menuActionTriggered)
                    controls.add(control)
                    let observation = control.observe(\.isHighlighted, options: [.old, .new]) { [weak self] control, change in
                        guard change.oldValue == true, change.newValue == false else { return }
                        Task { @MainActor [weak self, weak control] in
                            guard let control, !control.isHighlighted else { return }
                            self?.presenter?.discardMenuFeedback(from: control)
                        }
                    }
                    highlightObservations.setObject(observation, forKey: control)
                }
                for child in view.subviews { visit(child) }
            }
            visit(window)
        }
        func disconnect() {
            observedWindow?.removeGestureRecognizer(press)
            for control in controls.allObjects { control.removeTarget(self, action: #selector(menuWillOpen(_:)), for: .menuActionTriggered) }
            highlightObservations.removeAllObjects()
            presenter?.discardMenuFeedback()
            controls.removeAllObjects(); observedWindow = nil
        }
        func openingPress(_ touch: UITouch) {
            var candidate = touch.view
            while let view = candidate {
                if Self.isSource(view), let control = view as? UIControl, let window = control.window {
                    lastPress = ProcessInfo.processInfo.systemUptime
                    presenter?.prepareMenuFeedback(in: window, source: control)
                    return
                }
                candidate = view.superview
            }
        }
        @objc private func menuWillOpen(_ sender: UIControl) {
            // A physical press already froze the earlier pixels. Accessibility has no touch.
            guard ProcessInfo.processInfo.systemUptime - lastPress > 1, let window = sender.window else { return }
            presenter?.prepareMenuFeedback(in: window, source: sender)
        }
    }
}
private final class CompanionFeedbackOpeningPress: UIGestureRecognizer {
    weak var anchor: CompanionFeedbackMenuCapture.Anchor?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { anchor?.openingPress(touch) }
        state = .failed
    }
}
