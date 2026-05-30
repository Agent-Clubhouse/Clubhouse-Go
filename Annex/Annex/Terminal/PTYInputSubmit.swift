import Foundation

/// Pure logic for deciding when terminal input should be submitted to the remote PTY.
///
/// SwiftUI's `TextField.onSubmit` is unreliable on iOS — autocorrect commits, dictation,
/// pasted content, and some keyboard configurations can insert a literal newline into the
/// binding without firing `.onSubmit`. Treat any `\n` or `\r` appearing in the text as the
/// user's intent to submit.
enum PTYInputSubmit {
    /// Result of evaluating an input change.
    struct Result: Equatable {
        /// Text to transmit to the remote PTY, terminated with `\r`. `nil` if nothing should
        /// be sent (no newline was inserted, or the line was empty).
        let payload: String?
        /// New value for the input binding. Always empty when `payload` is non-nil so the
        /// field clears after submit; otherwise the original text unchanged.
        let newBinding: String
    }

    /// Evaluate a text-binding change for newline-triggered submission.
    ///
    /// - Parameter text: The current value of the input binding (after the user's edit).
    /// - Returns: `payload` to send (or nil) and the value the binding should be reset to.
    static func evaluate(text: String) -> Result {
        // Operate on Unicode scalars so that "\r\n" (which is a single Character grapheme
        // cluster in Swift) is detected correctly.
        let hasNewline = text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        guard hasNewline else {
            return Result(payload: nil, newBinding: text)
        }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != "\n" && scalar != "\r" {
            scalars.append(scalar)
        }
        let stripped = String(scalars)
        if stripped.isEmpty {
            return Result(payload: nil, newBinding: "")
        }
        return Result(payload: stripped + "\r", newBinding: "")
    }
}
