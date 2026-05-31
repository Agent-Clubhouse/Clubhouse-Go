import Testing
import Foundation
@testable import ClubhouseGo

struct PTYInputSubmitTests {
    @Test func noNewlineDoesNotSubmit() {
        let result = PTYInputSubmit.evaluate(text: "ls")
        #expect(result.payload == nil)
        #expect(result.newBinding == "ls")
    }

    @Test func emptyTextDoesNotSubmit() {
        let result = PTYInputSubmit.evaluate(text: "")
        #expect(result.payload == nil)
        #expect(result.newBinding == "")
    }

    @Test func trailingNewlineSubmitsAndClears() {
        let result = PTYInputSubmit.evaluate(text: "ls\n")
        #expect(result.payload == "ls\r")
        #expect(result.newBinding == "")
    }

    @Test func trailingCarriageReturnSubmitsAndClears() {
        let result = PTYInputSubmit.evaluate(text: "ls\r")
        #expect(result.payload == "ls\r")
        #expect(result.newBinding == "")
    }

    @Test func newlineMidTextStillSubmits() {
        // Dictation or paste may insert \n in the middle of text.
        let result = PTYInputSubmit.evaluate(text: "ls\n-la")
        #expect(result.payload == "ls-la\r")
        #expect(result.newBinding == "")
    }

    @Test func multipleNewlinesAreStripped() {
        let result = PTYInputSubmit.evaluate(text: "echo hi\n\n\n")
        #expect(result.payload == "echo hi\r")
        #expect(result.newBinding == "")
    }

    @Test func newlineOnlyDoesNotSubmitButClears() {
        // Pressing Enter on an empty field should clear (or stay empty) — not send a blank line.
        let result = PTYInputSubmit.evaluate(text: "\n")
        #expect(result.payload == nil)
        #expect(result.newBinding == "")
    }

    @Test func whitespaceWithNewlineIsPreservedAndSubmitted() {
        // Leading/trailing spaces matter for shell input — keep them intact.
        let result = PTYInputSubmit.evaluate(text: "  ls  \n")
        #expect(result.payload == "  ls  \r")
        #expect(result.newBinding == "")
    }

    @Test func mixedCRLFSubmits() {
        let result = PTYInputSubmit.evaluate(text: "ls\r\n")
        #expect(result.payload == "ls\r")
        #expect(result.newBinding == "")
    }

    @Test func tabsAndSpecialCharsPreserved() {
        let result = PTYInputSubmit.evaluate(text: "grep\t-r\t'foo'\n")
        #expect(result.payload == "grep\t-r\t'foo'\r")
        #expect(result.newBinding == "")
    }
}
