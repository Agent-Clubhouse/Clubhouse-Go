import Foundation

/// What an iOS screenshot taken in the app should do about feedback. Pure, so the rules are tested
/// without UIKit: offer only to an enrolled person, never while a password field is in use, and tell
/// an unenrolled person about enrollment at most once per session so ordinary screenshots aren't nagged.
enum CompanionScreenshotFeedback {
    static let preferenceKey = "framebriar.screenshotOffersFeedback"

    enum Decision: Equatable { case ignore, waitForStatus, offer, explainEnrollment }

    /// - Parameters:
    ///   - canSubmit: nil while the feedback client's status is still loading.
    ///   - busy: feedback UI (composer, enrollment, explainer) is already on screen.
    static func decide(enabled: Bool, configured: Bool, canSubmit: Bool?, secureFieldActive: Bool,
                       explainedThisSession: Bool, busy: Bool) -> Decision {
        guard enabled, configured, !secureFieldActive, !busy else { return .ignore }
        guard let canSubmit else { return .waitForStatus }
        if canSubmit { return .offer }
        return explainedThisSession ? .ignore : .explainEnrollment
    }

    /// The setting defaults on: an absent value means the person never turned it off.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }
}

/// An offer's lifetime counts only time when its scene is active. UIKit owns the timer; this
/// policy tells it when to cancel or start a fresh eight-second interval after a system preview.
struct CompanionScreenshotPromptLifecycle {
    private(set) var pending = false
    private(set) var visible = false
    enum Effect: Equatable { case none, show, hide }
    mutating func request(active: Bool, ready: Bool) -> Effect {
        pending = true
        return resume(active: active, ready: ready)
    }
    mutating func resume(active: Bool, ready: Bool) -> Effect {
        guard pending else { return .none }
        guard active, ready else {
            let wasVisible = visible
            visible = false
            return wasVisible ? .hide : .none
        }
        visible = true
        return .show
    }
    mutating func dismiss() { pending = false; visible = false }
}
