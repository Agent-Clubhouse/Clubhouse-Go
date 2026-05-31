import Testing
import Foundation
@testable import ClubhouseGo

struct PTYInputSubmitTests {

    // MARK: - Ordinary typing (no submit)

    @Test func typingDoesNotSubmit() {
        #expect(PTYInputSubmit.evaluate(previous: "l", current: "ls") == .none)
    }

    @Test func emptyTextDoesNotSubmit() {
        #expect(PTYInputSubmit.evaluate(previous: "", current: "") == .none)
    }

    @Test func singleLinePasteDoesNotSubmit() {
        // A paste with no newline is just text — populate the field, send nothing.
        #expect(PTYInputSubmit.evaluate(previous: "", current: "git status") == .none)
    }

    // MARK: - Return key (submit)

    @Test func returnKeySubmitsAndStripsTrailingNewline() {
        #expect(PTYInputSubmit.evaluate(previous: "ls", current: "ls\n") == .submit("ls"))
    }

    @Test func returnKeyCarriageReturnSubmits() {
        #expect(PTYInputSubmit.evaluate(previous: "ls", current: "ls\r") == .submit("ls"))
    }

    @Test func returnKeyCRLFSubmits() {
        #expect(PTYInputSubmit.evaluate(previous: "ls", current: "ls\r\n") == .submit("ls"))
    }

    @Test func multipleTrailingNewlinesSubmitOnce() {
        #expect(PTYInputSubmit.evaluate(previous: "echo hi", current: "echo hi\n\n\n") == .submit("echo hi"))
    }

    @Test func leadingAndTrailingSpacesPreservedOnSubmit() {
        // Whitespace is significant for shell input — keep it intact, only the
        // appended newline is removed.
        #expect(PTYInputSubmit.evaluate(previous: "  ls  ", current: "  ls  \n") == .submit("  ls  "))
    }

    @Test func tabsAndSpecialCharsPreservedOnSubmit() {
        #expect(
            PTYInputSubmit.evaluate(previous: "grep\t-r\t'foo'", current: "grep\t-r\t'foo'\n")
                == .submit("grep\t-r\t'foo'")
        )
    }

    @Test func submitPayloadHasNoTrailingTerminator() {
        // The view is responsible for appending the PTY line terminator; the
        // action must carry the bare command so it isn't double-terminated.
        guard case .submit(let command) = PTYInputSubmit.evaluate(previous: "pwd", current: "pwd\n") else {
            Issue.record("expected .submit")
            return
        }
        #expect(!command.contains("\r"))
        #expect(!command.contains("\n"))
    }

    // MARK: - Return on empty (clear, don't transmit a blank line)

    @Test func returnOnEmptyFieldClearsWithoutSubmitting() {
        #expect(PTYInputSubmit.evaluate(previous: "", current: "\n") == .clear)
    }

    // MARK: - Paste / dictation with embedded newlines (issue #95 regression)

    @Test func multiLinePasteDoesNotSubmit() {
        // Regression for #95: a multi-line paste used to be flattened and
        // auto-sent. Now it only populates the field (newlines stripped).
        #expect(PTYInputSubmit.evaluate(previous: "", current: "echo one\necho two") == .replace("echo oneecho two"))
    }

    @Test func multiLinePasteWithTrailingNewlineDoesNotSubmit() {
        // Even with a trailing newline, an embedded-newline paste is not a
        // Return-key press, so it must not submit.
        #expect(PTYInputSubmit.evaluate(previous: "", current: "echo one\necho two\n") == .replace("echo oneecho two"))
    }

    @Test func singleLinePasteWithTrailingNewlineDoesNotSubmit() {
        // Pasting copied text that happened to include a trailing newline should
        // populate the field for review, not auto-run.
        #expect(PTYInputSubmit.evaluate(previous: "", current: "deploy --prod\n") == .replace("deploy --prod"))
    }

    @Test func pasteIntoExistingTextDoesNotSubmit() {
        // Pasting a chunk that contains a newline into existing text is not a
        // trailing-only newline append, so it must not submit.
        #expect(PTYInputSubmit.evaluate(previous: "ls", current: "ls && echo\ndone") == .replace("ls && echodone"))
    }

    @Test func pasteOfOnlyNewlinesClears() {
        // Pasting nothing but newlines leaves an empty command — clear, no send.
        #expect(PTYInputSubmit.evaluate(previous: "", current: "\n\n") == .clear)
    }
}
