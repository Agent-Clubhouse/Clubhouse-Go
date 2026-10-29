#if DEBUG
import UIKit
import ObjectiveC
import os

/// Debug-only trace for shake delivery on a real device: every motion event UIKit dispatches, with the
/// first responder, key window and scene state at that moment, and each change of first responder.
/// Read with `log stream --predicate 'subsystem == "com.Agent-Clubhouse.Go.feedback"'`.
@MainActor enum CompanionShakeDiagnostics {
    static let log = Logger(subsystem: "com.Agent-Clubhouse.Go.feedback", category: "shake")
    private static var installed = false
    private static var lastResponder = ""
    fileprivate static weak var captured: UIResponder?

    static func install() {
        guard !installed else { return }
        installed = true
        let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:)))
        let traced = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.companionTracedSendEvent(_:)))
        if let original, let traced { method_exchangeImplementations(original, traced) }
        Task { @MainActor in
            while true {
                let now = describeFirstResponder()
                if now != lastResponder { log.notice("first responder -> \(now, privacy: .public)"); lastResponder = now }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        log.notice("shake trace installed")
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
                CompanionShakeDiagnostics.log.notice("motion event subtype=\(subtype) \(CompanionShakeDiagnostics.state(), privacy: .public)")
            }
        }
        companionTracedSendEvent(event) // Swapped: calls the original implementation.
    }
}

private extension UIResponder {
    @objc func companionCaptureFirstResponder() { MainActor.assumeIsolated { CompanionShakeDiagnostics.captured = self } }
}
#endif
