#if DEBUG
import UIKit
import ObjectiveC
import os

/// Debug-only trace for shake delivery on a real device: every motion event UIKit dispatches, with the
/// first responder, key window and scene state at that moment, and each change of first responder.
/// Off unless launched with `--shake-trace`, e.g. `xcrun devicectl device process launch --console <app> --shake-trace`;
/// also readable with `log stream --predicate 'subsystem == "com.Agent-Clubhouse.Go.feedback"'`.
@MainActor enum CompanionShakeDiagnostics {
    private static let logger = Logger(subsystem: "com.Agent-Clubhouse.Go.feedback", category: "shake")
    /// Also printed, so `devicectl device process launch --console` shows it.
    nonisolated static func trace(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[shake] \(message)")
    }
    private static var installed = false
    private static var lastResponder = ""
    fileprivate static weak var captured: UIResponder?

    static func install() {
        guard !installed, ProcessInfo.processInfo.arguments.contains("--shake-trace") else { return }
        installed = true
        let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:)))
        let traced = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.companionTracedSendEvent(_:)))
        if let original, let traced { method_exchangeImplementations(original, traced) }
        Task { @MainActor in
            while true {
                let now = describeFirstResponder()
                if now != lastResponder { trace("first responder -> \(now)"); lastResponder = now }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        trace("shake trace installed")
    }

    static func describeFirstResponder() -> String {
        captured = nil
        UIApplication.shared.sendAction(#selector(UIResponder.companionCaptureFirstResponder), to: nil, from: nil, for: nil)
        return captured.map { String(describing: type(of: $0)) } ?? "none"
    }

    static func state() -> String {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let activation = scenes.map { "\($0.activationState.rawValue)" }.joined(separator: ",")
        let presented = key?.rootViewController.map(topPresented) ?? "none"
        return "responder=\(describeFirstResponder()) key=\(key.map { String(describing: type(of: $0)) } ?? "none") scenes=\(activation) top=\(presented)"
    }

    private static func topPresented(_ controller: UIViewController) -> String {
        var top = controller
        while let next = top.presentedViewController { top = next }
        return String(describing: type(of: top))
    }
}

extension UIApplication {
    @objc fileprivate func companionTracedSendEvent(_ event: UIEvent) {
        if event.type == .motion {
            let subtype = event.subtype.rawValue
            MainActor.assumeIsolated {
                CompanionShakeDiagnostics.trace("motion event subtype=\(subtype) \(CompanionShakeDiagnostics.state())")
            }
        }
        companionTracedSendEvent(event) // Swapped: calls the original implementation.
    }
}

private extension UIResponder {
    @objc func companionCaptureFirstResponder() { MainActor.assumeIsolated { CompanionShakeDiagnostics.captured = self } }
}
#endif
