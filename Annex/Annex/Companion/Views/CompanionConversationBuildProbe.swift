#if DEBUG
/// A non-observable, opt-in hook for hosted rendering regressions. It never records transcript content.
@MainActor enum CompanionConversationBuildProbe {
    enum Kind { case body, timeline }
    static var record: ((Kind, CompanionTarget) -> Void)?
}

/// Optional lifecycle evidence for hosted focus regressions. No draft/selection observation or focus mutation.
@MainActor enum CompanionComposerFocusProbe {
    enum Event: String {
        case appeared, disappeared, focusChanged, focusRequested, dismissalRequested, keyboardDismissed
    }
    static var record: ((Event, CompanionTarget, Bool) -> Void)?
}
#endif
