import Foundation

/// Pure logic for deciding what a terminal input-field change means.
///
/// SwiftUI's `TextField.onSubmit` is unreliable on iOS — autocorrect commits,
/// dictation, pasted content, and some keyboard configurations can insert a
/// literal newline into the binding without firing `.onSubmit`. So the views
/// also watch the binding via `.onChange` and route every change through here.
///
/// The old implementation treated *any* `\n`/`\r` anywhere in the text as
/// "submit now", which mangled multi-line pastes (it flattened them into one
/// line and auto-sent without the user pressing Send — see issue #95). We need
/// the *intent* behind a change, which requires the previous value too:
///
///   - Pressing Return appends a newline (or `\r\n`) to the **end** of the
///     existing text and nothing else → that is an explicit submit.
///   - A paste/dictation drops a chunk that contains newlines somewhere in the
///     middle, or replaces the field wholesale → that is *not* a submit; the
///     newlines are stripped so the single-line field stays usable and the user
///     decides when to press Send.
enum PTYInputSubmit {
    /// The action a view should take in response to a binding change.
    enum Action: Equatable {
        /// Ordinary edit — leave the binding as-is, send nothing.
        case none
        /// The change was newline-only on an empty command — clear the field,
        /// send nothing (don't transmit a blank line to the PTY).
        case clear
        /// Pasted/dictated content with embedded newlines — replace the binding
        /// with this cleaned (newline-free) value but send nothing.
        case replace(String)
        /// The user pressed Return — submit this command (without a trailing
        /// newline). The caller appends the PTY line terminator and clears the
        /// field.
        case submit(String)
    }

    private static func isNewline(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r"
    }

    private static func stripNewlines(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isNewline($0) }))
    }

    /// Evaluate a binding change.
    ///
    /// - Parameters:
    ///   - previous: The binding value *before* this change.
    ///   - current: The binding value *after* this change.
    /// - Returns: The `Action` the view should take.
    static func evaluate(previous: String, current: String) -> Action {
        let hasNewline = current.unicodeScalars.contains(where: isNewline)
        guard hasNewline else {
            // No newline anywhere: ordinary typing or a single-line paste.
            return .none
        }

        // Return-key press: `current` is `previous` followed only by newline
        // characters, with no other edit. This is the one case that submits.
        if current.hasPrefix(previous) {
            let appended = current.unicodeScalars.dropFirst(previous.unicodeScalars.count)
            if !appended.isEmpty, appended.allSatisfy(isNewline) {
                let command = previous
                return command.isEmpty ? .clear : .submit(command)
            }
        }

        // Otherwise the newline(s) came from a paste/dictation, not a Return.
        // Strip them so the single-line field stays usable; do not submit.
        let cleaned = stripNewlines(current)
        return cleaned.isEmpty ? .clear : .replace(cleaned)
    }
}
