#if DEBUG
import GameController
import UIKit

/// Opt-in, metadata-only observations: never requests focus or reads message content.
@MainActor enum CompanionWakeFocusDiagnostics {
    private static var observer: Observer?
    private static var presentation = 0

    static func begin() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--companion-preview"),
              arguments.contains("--companion-preview-wake-focus-diagnostics") else { return }
        end()
        presentation += 1
        let current = Observer(presentation: presentation)
        observer = current
        current.start()
        current.snapshot("appear-before-focus-request")
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.isKeyWindow {
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                controller?.transitionCoordinator?.animate(alongsideTransition: nil) { context in
                    current.snapshot("presentation-completed-cancelled-\(context.isCancelled)")
                }
            }
        }
    }

    static func snapshot(_ event: String, focused: Bool) {
        observer?.snapshot("\(event)-binding-\(focused)")
    }

    static func end() {
        observer?.snapshot("disappear")
        observer?.stop()
        observer = nil
    }

    @MainActor private final class Observer: NSObject {
        nonisolated deinit {}
        private let presentation: Int
        private let started: ContinuousClock.Instant = .now
        private var samples: Int = 0

        init(presentation: Int) { self.presentation = presentation }

        func start() {
            for name in [
                UITextField.textDidBeginEditingNotification, UITextField.textDidEndEditingNotification,
                UITextView.textDidBeginEditingNotification, UITextView.textDidEndEditingNotification,
                UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
                UIResponder.keyboardWillHideNotification, UIResponder.keyboardDidHideNotification,
                UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification
            ] {
                NotificationCenter.default.addObserver(self, selector: #selector(notified(_:)), name: name, object: nil)
            }
        }

        func stop() { NotificationCenter.default.removeObserver(self) }

        @objc private func notified(_ note: Notification) {
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
            snapshot("\(note.name.rawValue)-keyboardEnd-\(frame.map { String(describing: $0) } ?? "none")-duration-\(duration.map { String($0) } ?? "none")")
        }

        func snapshot(_ event: String) {
            guard samples < 64 else { return }
            samples += 1
            print("WAKE_FOCUS presentation=\(presentation) sample=\(samples) elapsed=\(started.duration(to: .now)) event=\(event) os=\(ProcessInfo.processInfo.operatingSystemVersionString) idiom=\(UIDevice.current.userInterfaceIdiom.rawValue) appState=\(UIApplication.shared.applicationState.rawValue) hardwareKeyboardReported=\(GCKeyboard.coalesced != nil)")
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for (index, window) in scene.windows.enumerated() {
                    var controller = window.rootViewController
                    while let presented = controller?.presentedViewController { controller = presented }
                    let transition = controller?.transitionCoordinator
                    print("WAKE_FOCUS window=\(index) sceneState=\(scene.activationState.rawValue) key=\(window.isKeyWindow) hidden=\(window.isHidden) presenting=\(controller?.isBeingPresented ?? false) transitionAnimated=\(transition?.isAnimated ?? false) transitionDuration=\(transition?.transitionDuration ?? 0)")
                    inputs(in: window, window: index)
                }
            }
        }

        private func inputs(in view: UIView, window: Int) {
            if view is UITextField || view is UITextView {
                print("WAKE_FOCUS input=\(String(describing: type(of: view))) window=\(window) inWindow=\(view.window != nil) firstResponder=\(view.isFirstResponder) wakeIdentifier=\(view.accessibilityIdentifier == "wake-message") hidden=\(view.isHidden) frame=\(view.frame)")
            }
            for child in view.subviews { inputs(in: child, window: window) }
        }
    }
}
#endif
