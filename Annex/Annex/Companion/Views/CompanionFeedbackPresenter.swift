import SwiftUI
import UIKit
import Framebriar
import FramebriarUI

extension EnvironmentValues {
    /// Opens the feedback form, or explains enrollment when this phone isn't enrolled. Nil when the build has no feedback.
    @Entry var companionSendFeedback: (@MainActor () -> Void)?
}

/// Feedback entry points that don't depend on a gesture: the "Send feedback" menu items and the offer
/// shown after an iOS screenshot. Presents over whatever is on screen (sheets, Review), so a trigger
/// from any screen reaches the same composer. Captures stay on the phone until the person submits.
@MainActor final class CompanionFeedbackPresenter {
    static let promptDuration: Duration = .seconds(8)
    let model: FeedbackModel?
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var explainedThisSession = false
    private var promptWindow: UIWindow?
    private var promptTask: Task<Void, Never>?
    /// Composer, enrollment or explainer currently presented by this presenter.
    private weak var presented: UIViewController?

    init(model: FeedbackModel?, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenshotTaken() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The menu items: always answer, enrolled or not.
    func sendFeedback() {
        guard let model, presented == nil else { return }
        dismissPrompt()
        if model.status?.canSubmit == true { presentComposer(screenshot: nil) }
        else { explainEnrollment(fromScreenshot: false) }
    }

    func screenshotTaken() {
        let window = Self.keyWindow()
        let secure = window.map(Self.hasSecureFirstResponder) ?? false
        switch CompanionScreenshotFeedback.decide(enabled: CompanionScreenshotFeedback.isEnabled(defaults), configured: model != nil,
                                                  canSubmit: model?.status.map(\.canSubmit), secureFieldActive: secure,
                                                  explainedThisSession: explainedThisSession, busy: presented != nil) {
        case .ignore: return
        case .explainEnrollment: explainEnrollment(fromScreenshot: true)
        case .offer:
            // The same window snapshot a shake attaches; nothing is kept unless the person opens the form.
            guard let window else { return }
            showPrompt(screenshot: Self.capture(window), in: window.windowScene)
        }
    }

    // MARK: Prompt

    private func showPrompt(screenshot: Data?, in scene: UIWindowScene?) {
        guard let scene else { return }
        dismissPrompt()
        let window = PassthroughWindow(windowScene: scene)
        let prompt = CompanionScreenshotFeedbackPrompt(
            frameChanged: { [weak window] in window?.interactiveFrame = $0 },
            // Present before closing: closing releases this prompt and the closure that holds the capture.
            open: { [weak self] in self?.presentComposer(screenshot: screenshot); self?.dismissPrompt() },
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
        promptTask?.cancel(); promptTask = nil
        promptWindow?.isHidden = true
        promptWindow = nil
    }

    // MARK: Presentation

    private func presentComposer(screenshot: Data?) {
        guard let model else { return }
        present(UIHostingController(rootView: NavigationStack { FeedbackView(model: model, initialScreenshotPNG: screenshot) }))
    }

    private func explainEnrollment(fromScreenshot: Bool) {
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
        alert.addAction(UIAlertAction(title: "Not now", style: .cancel))
        present(alert)
    }

    private func present(_ controller: UIViewController) {
        guard let root = Self.keyWindow()?.rootViewController else { return }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        presented = controller
        top.present(controller, animated: true)
    }

    // MARK: Window

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (active.isEmpty ? scenes : active).flatMap(\.windows).filter { !($0 is PassthroughWindow) && !$0.isHidden }
        return windows.first(where: \.isKeyWindow) ?? windows.first { $0.windowLevel == .normal }
    }

    /// What is on screen now, within the SDK's size caps; nil while a password field is in use.
    static func capture(_ window: UIWindow) -> Data? {
        guard ShakeScreenshot.shouldCapture(captureScreen: true, secureFieldActive: hasSecureFirstResponder(window)),
              window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.cgImage.flatMap { ShakeScreenshot.encodePNG($0) }
    }

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
private struct CompanionEnrollmentSheet: View {
    let model: FeedbackModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            EnrollmentView(model: model).toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension View {
    /// Installs the menu action for this subtree. Screenshots are observed by the presenter itself.
    func companionFeedbackEntryPoints(_ presenter: CompanionFeedbackPresenter?) -> some View {
        var action: (@MainActor () -> Void)?
        if let presenter, presenter.model != nil { action = { presenter.sendFeedback() } }
        return environment(\.companionSendFeedback, action)
    }
}
