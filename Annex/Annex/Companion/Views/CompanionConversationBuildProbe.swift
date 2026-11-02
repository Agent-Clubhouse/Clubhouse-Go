#if DEBUG
/// A non-observable, opt-in hook for hosted rendering regressions. It never records transcript content.
@MainActor enum CompanionConversationBuildProbe {
    enum Kind { case body, timeline }
    static var record: ((Kind, CompanionTarget) -> Void)?
}
#endif
