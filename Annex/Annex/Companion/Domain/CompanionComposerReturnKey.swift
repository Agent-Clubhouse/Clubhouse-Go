/// Physical Return presses, including repeats until each key's own release.
nonisolated struct CompanionComposerReturnKey {
    enum Key { case returnOrEnter, keypadEnter }
    enum Action: Equatable { case system, submit, newline, consume }
    private var held: [Key: Action] = [:]

    mutating func began(key: Key = .returnOrEnter, shift: Bool, otherModifiers: Bool, markedText: Bool, canSubmit: Bool) -> Action {
        if let action = held[key] { return action == .system ? .system : .consume }
        let action: Action
        if markedText || otherModifiers { action = .system }
        else if !held.isEmpty { action = .consume }
        else if shift { action = .newline }
        else { action = canSubmit ? .submit : .consume }
        held[key] = action
        return action
    }

    /// Returns whether UIKit should receive the release of a press it handled.
    mutating func ended(key: Key = .returnOrEnter) -> Bool {
        let action = held.removeValue(forKey: key)
        return action == nil || action == .system
    }
}
