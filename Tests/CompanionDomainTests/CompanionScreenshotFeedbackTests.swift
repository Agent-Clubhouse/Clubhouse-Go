import Foundation
import Testing
@testable import CompanionDomain

struct CompanionScreenshotFeedbackTests {
    private func decide(enabled: Bool = true, configured: Bool = true, canSubmit: Bool? = true, secure: Bool = false,
                        explained: Bool = false, busy: Bool = false) -> CompanionScreenshotFeedback.Decision {
        CompanionScreenshotFeedback.decide(enabled: enabled, configured: configured, canSubmit: canSubmit,
                                           secureFieldActive: secure, explainedThisSession: explained, busy: busy)
    }

    @Test func enrolledScreenshotOffersFeedback() {
        #expect(decide() == .offer)
        // Enrolled people are offered every time; the once-per-session rule is only for the explainer.
        #expect(decide(explained: true) == .offer)
    }

    @Test func settingOffOrNoFeedbackClientIgnores() {
        #expect(decide(enabled: false) == .ignore)
        #expect(decide(enabled: false, canSubmit: false) == .ignore)
        #expect(decide(configured: false) == .ignore)
    }

    @Test func secureFieldSuppressesPromptAndExplainer() {
        #expect(decide(secure: true) == .ignore)
        #expect(decide(canSubmit: false, secure: true) == .ignore)
    }

    @Test func unenrolledSeesExplainerOncePerSession() {
        #expect(decide(canSubmit: false) == .explainEnrollment)
        #expect(decide(canSubmit: false, explained: true) == .ignore)
    }

    @Test func unknownStatusWaitsButFeedbackAlreadyShowingIgnores() {
        #expect(decide(canSubmit: nil) == .waitForStatus)
        #expect(decide(busy: true) == .ignore)
        #expect(decide(canSubmit: false, busy: true) == .ignore)
    }

    @Test func previewDefersOfferAndRestartsItsFullLifetime() {
        var lifecycle = CompanionScreenshotPromptLifecycle()
        #expect(lifecycle.request(active: false, ready: true) == .none)
        #expect(lifecycle.pending && !lifecycle.visible)
        #expect(lifecycle.resume(active: true, ready: true) == .show)
        #expect(lifecycle.resume(active: false, ready: true) == .hide)
        #expect(lifecycle.pending && !lifecycle.visible)
        #expect(lifecycle.resume(active: true, ready: true) == .show)
        lifecycle.dismiss()
        #expect(lifecycle.resume(active: true, ready: true) == .none)
    }

    @Test func statusLoadingDoesNotConsumeAnOffer() {
        var lifecycle = CompanionScreenshotPromptLifecycle()
        #expect(lifecycle.request(active: true, ready: false) == .none)
        #expect(lifecycle.pending)
        #expect(lifecycle.resume(active: true, ready: true) == .show)
        #expect(lifecycle.request(active: true, ready: true) == .show)
        lifecycle.dismiss()
        #expect(!lifecycle.pending && !lifecycle.visible)
    }

    @Test func settingDefaultsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "screenshot-feedback-tests"))
        defaults.removePersistentDomain(forName: "screenshot-feedback-tests")
        #expect(CompanionScreenshotFeedback.isEnabled(defaults))
        defaults.set(false, forKey: CompanionScreenshotFeedback.preferenceKey)
        #expect(!CompanionScreenshotFeedback.isEnabled(defaults))
        defaults.removePersistentDomain(forName: "screenshot-feedback-tests")
    }
}
