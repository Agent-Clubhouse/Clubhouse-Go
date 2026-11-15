#if DEBUG
import GameController
import UIKit

nonisolated struct CompanionWakeFocusRecord: Encodable, Sendable {
    enum Event: Encodable, Sendable {
        case appear, focusRequested(Bool), focusChanged(Bool), disappear
        case presentationCompleted(cancelled: Bool)
        case notification(Notification, keyboardFrame: CGRect?, duration: Double?)
    }
    enum Notification: String, Encodable, Sendable {
        case fieldBegan, fieldEnded, viewBegan, viewEnded, becameKey, resignedKey
        case sceneActivated, sceneDeactivated, keyboardWillShow, keyboardDidShow
        case keyboardWillHide, keyboardDidHide, keyboardWillChangeFrame, keyboardDidChangeFrame
    }
    struct Input: Encodable, Sendable {
        enum Kind: String, Encodable, Sendable { case textField, textView }
        let kind: Kind
        let inWindow: Bool
        let firstResponder: Bool
        let wakeIdentifier: Bool
        let hidden: Bool
        let frame: CGRect
    }
    struct Window: Encodable, Sendable {
        let sceneState: Int
        let key: Bool
        let hidden: Bool
        let presenting: Bool
        let transitionAnimated: Bool
        let transitionDuration: Double
        let inputs: [Input]
    }
    let presentation: Int
    let sample: Int
    let elapsedSeconds: Double
    let event: Event
    let osMajor: Int
    let osMinor: Int
    let osPatch: Int
    let idiom: Int
    let appState: Int
    let hardwareKeyboardReported: Bool
    let eventInput: Input?
    let windows: [Window]
}

/// Opt-in, metadata-only observations: never requests focus or reads message content.
@MainActor enum CompanionWakeFocusDiagnostics {
    private static var observer: Observer?
    private static var presentation = 0
    private static let trace = CompanionDiagnosticTrace(wake: true, automaticallyStart: false)

    static func prepare() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--companion-preview"),
              arguments.contains("--companion-preview-wake-focus-diagnostics") else { return }
        await trace.start()
    }

    static func begin() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--companion-preview"),
              arguments.contains("--companion-preview-wake-focus-diagnostics") else { return }
        begin(trace: trace)
    }

    static func begin(trace: CompanionDiagnosticTrace) {
        end()
        presentation += 1
        let current = Observer(presentation: presentation, trace: trace)
        observer = current
        current.start()
        current.snapshot(.appear)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.isKeyWindow {
                var controller = window.rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                controller?.transitionCoordinator?.animate(alongsideTransition: nil) { context in
                    current.snapshot(.presentationCompleted(cancelled: context.isCancelled))
                }
            }
        }
    }

    static func snapshot(_ event: CompanionWakeFocusRecord.Event) {
        observer?.snapshot(event)
    }

    static func end() {
        observer?.snapshot(.disappear)
        observer?.stop()
        observer = nil
    }

    @MainActor private final class Observer: NSObject {
        nonisolated deinit {}
        private let presentation: Int
        private let trace: CompanionDiagnosticTrace
        private let started: ContinuousClock.Instant = .now
        private var samples: Int = 0

        init(presentation: Int, trace: CompanionDiagnosticTrace) {
            self.presentation = presentation
            self.trace = trace
        }

        private static let notifications: [(Foundation.Notification.Name, CompanionWakeFocusRecord.Notification)] = [
            (UITextField.textDidBeginEditingNotification, .fieldBegan), (UITextField.textDidEndEditingNotification, .fieldEnded),
            (UITextView.textDidBeginEditingNotification, .viewBegan), (UITextView.textDidEndEditingNotification, .viewEnded),
            (UIWindow.didBecomeKeyNotification, .becameKey), (UIWindow.didResignKeyNotification, .resignedKey),
            (UIScene.didActivateNotification, .sceneActivated), (UIScene.willDeactivateNotification, .sceneDeactivated),
            (UIResponder.keyboardWillShowNotification, .keyboardWillShow), (UIResponder.keyboardDidShowNotification, .keyboardDidShow),
            (UIResponder.keyboardWillHideNotification, .keyboardWillHide), (UIResponder.keyboardDidHideNotification, .keyboardDidHide),
            (UIResponder.keyboardWillChangeFrameNotification, .keyboardWillChangeFrame),
            (UIResponder.keyboardDidChangeFrameNotification, .keyboardDidChangeFrame)
        ]

        func start() {
            for (name, _) in Self.notifications {
                NotificationCenter.default.addObserver(self, selector: #selector(notified(_:)), name: name, object: nil)
            }
        }

        func stop() { NotificationCenter.default.removeObserver(self) }

        @objc private func notified(_ note: Notification) {
            guard let kind = Self.notifications.first(where: { $0.0 == note.name })?.1 else { return }
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
            snapshot(.notification(kind, keyboardFrame: frame, duration: duration), eventInput: note.object as? UIView)
        }

        func snapshot(_ event: CompanionWakeFocusRecord.Event, eventInput: UIView? = nil) {
            guard samples < 64 else { return }
            samples += 1
            let elapsed = started.duration(to: .now).components
            var windows: [CompanionWakeFocusRecord.Window] = []
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows.prefix(8) where windows.count < 8 {
                    var controller = window.rootViewController
                    while let presented = controller?.presentedViewController { controller = presented }
                    let transition = controller?.transitionCoordinator
                    var inputs: [CompanionWakeFocusRecord.Input] = []
                    var remainingViews = 256
                    collectInputs(in: controller?.viewIfLoaded ?? window, remaining: &remainingViews, into: &inputs)
                    windows.append(.init(sceneState: scene.activationState.rawValue, key: window.isKeyWindow,
                        hidden: window.isHidden, presenting: controller?.isBeingPresented ?? false,
                        transitionAnimated: transition?.isAnimated ?? false, transitionDuration: transition?.transitionDuration ?? 0,
                        inputs: inputs))
                }
            }
            let version = ProcessInfo.processInfo.operatingSystemVersion
            trace.append(.init(presentation: presentation, sample: samples,
                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, event: event,
                osMajor: version.majorVersion, osMinor: version.minorVersion, osPatch: version.patchVersion,
                idiom: UIDevice.current.userInterfaceIdiom.rawValue, appState: UIApplication.shared.applicationState.rawValue,
                hardwareKeyboardReported: GCKeyboard.coalesced != nil,
                eventInput: eventInput.flatMap(Self.input), windows: windows))
        }

        private static func input(_ view: UIView) -> CompanionWakeFocusRecord.Input? {
            guard view is UITextField || view is UITextView else { return nil }
            return .init(kind: view is UITextView ? .textView : .textField, inWindow: view.window != nil,
                firstResponder: view.isFirstResponder, wakeIdentifier: view.accessibilityIdentifier == "wake-message",
                hidden: view.isHidden, frame: view.frame)
        }

        private func collectInputs(in view: UIView, remaining: inout Int, into inputs: inout [CompanionWakeFocusRecord.Input]) {
            guard remaining > 0, inputs.count < 16 else { return }
            remaining -= 1
            if let input = Self.input(view) { inputs.append(input) }
            for child in view.subviews {
                guard remaining > 0, inputs.count < 16 else { break }
                collectInputs(in: child, remaining: &remaining, into: &inputs)
            }
        }
    }
}
#endif
