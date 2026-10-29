import Foundation

/// What an iOS screenshot taken in the app should do about feedback. Pure, so the rules are tested
/// without UIKit: offer only to an enrolled person, never while a password field is in use, and tell
/// an unenrolled person about enrollment at most once per session so ordinary screenshots aren't nagged.
enum CompanionScreenshotFeedback {
    static let preferenceKey = "framebriar.screenshotOffersFeedback"

    enum Decision: Equatable { case ignore, offer, explainEnrollment }

    /// - Parameters:
    ///   - canSubmit: nil while the feedback client's status is still loading.
    ///   - busy: feedback UI (composer, enrollment, explainer) is already on screen.
    static func decide(enabled: Bool, configured: Bool, canSubmit: Bool?, secureFieldActive: Bool,
                       explainedThisSession: Bool, busy: Bool) -> Decision {
        guard enabled, configured, let canSubmit, !secureFieldActive, !busy else { return .ignore }
        if canSubmit { return .offer }
        return explainedThisSession ? .ignore : .explainEnrollment
    }

    /// The setting defaults on: an absent value means the person never turned it off.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }
}
