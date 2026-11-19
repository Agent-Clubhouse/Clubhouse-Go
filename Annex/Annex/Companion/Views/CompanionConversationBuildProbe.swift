#if DEBUG
/// A non-observable, opt-in hook for hosted rendering regressions. It never records transcript content.
@MainActor enum CompanionConversationBuildProbe {
    enum Kind { case body, timeline }
    static var record: ((Kind, CompanionTarget) -> Void)?
}

/// Opt-in, read-only evidence of the exact values passed to actual transcript row constructors.
/// It provides no alternative activation path and is nil outside the serialized hosted proof.
@MainActor enum CompanionTranscriptActionProbe {
    enum Availability: Equatable {
        case approval(canRespond: Bool)
        case queued(canRemove: Bool, hasAction: Bool)
    }
    static var record: ((CompanionTarget, String, Availability) -> Void)?
}

/// Optional lifecycle evidence for hosted focus regressions. No draft/selection observation or focus mutation.
@MainActor enum CompanionComposerFocusProbe {
    enum Event: String {
        case appeared, disappeared, focusChanged, focusRequested, dismissalRequested, keyboardDismissed
    }
    static var record: ((Event, CompanionTarget, Bool) -> Void)?
}
#endif
