/// One physical Return press, including repeats until release. Software keyboard edits never enter this path.
nonisolated struct CompanionComposerReturnKey {
    enum Action: Equatable { case system, submit, newline, consume }
    private var held: Action?

    mutating func began(shift: Bool, otherModifiers: Bool, markedText: Bool, canSubmit: Bool) -> Action {
        if let held { return held == .system ? .system : .consume }
        let action: Action
        if markedText || otherModifiers { action = .system }
        else if shift { action = .newline }
        else { action = canSubmit ? .submit : .consume }
        held = action
        return action
    }

    /// Returns whether UIKit should receive the release of a press it handled.
    mutating func ended() -> Bool {
        defer { held = nil }
        return held == nil || held == .system
    }
}
