import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

struct CompanionFullEventDocumentTests {
    @Test func stringLeavesAreReadableAndFormattingControlsCannotHidePayload() throws {
        let content = "first line\n\nlast line\u{202E}/secret\u{200B}"
        let event: AnnexJSON = .object(["data": .object([
            "rawInput": .object(["file_path": .string("/work/a.swift"), "content": .string(content)]),
            "content": .array([.object(["type": .string("terminal"), "command": .string("cat /work/a.swift\necho done"), "output": .string("hello\nworld")])]),
            "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow")])])])])
        let sections = try CompanionFullEventDocument.sections(event)
        let strings = Dictionary(sections.map { ($0.heading, $0.chunks.joined(separator: "\n")) }, uniquingKeysWith: { first, _ in first })
        #expect(strings["data.rawInput.file_path"] == "/work/a.swift")
        #expect(strings["data.rawInput.content"] == "first line\n\nlast line⟨U+202E⟩/secret⟨U+200B⟩")
        #expect(strings["data.content[0].command"] == "cat /work/a.swift\necho done")
        #expect(strings["data.content[0].output"] == "hello\nworld")
        #expect(strings["data.options[0].label"] == "Allow")
        #expect(event["data"]?["rawInput"]?["content"] == .string(content), "Presentation must not mutate the digest's source event")
        #expect(CompanionFullEventDocument.visibleFormatting("a\u{061C}\u{FEFF}b") == "a⟨U+061C⟩⟨U+FEFF⟩b")
    }

    @Test func chunksPreserveOrdinaryLinesIncludingEmptyLines() throws {
        let text = "\nshort\n\nanother line\nlast\n"
        let chunks = try CompanionFullEventDocument.lineChunks(text, targetSize: 12)
        #expect(chunks.count > 1)
        #expect(chunks.joined(separator: "\n") == text)
        #expect(chunks.contains("another line"))
        let value: AnnexJSON = .object(["path": .string("/work/a")])
        #expect(!value.displayText.contains("\\/"))
    }

    @Test func crlfTerminalOutputIsChunkedLikeLFOutput() throws {
        let text = String(repeating: "let value = 1 // windows line\r\n", count: 20_000)
        let chunks = try CompanionFullEventDocument.lineChunks(text)
        #expect(chunks.count > 1)
        #expect((chunks.map { $0.utf8.count }.max() ?? 0) <= 16_384)
        let normalized = String(repeating: "let value = 1 // windows line\n", count: 20_000)
        #expect(chunks.joined(separator: "\n") == normalized)
    }

    @Test(arguments: ["\r", "\u{2028}"])
    func otherNewlinesProduceBoundedChunks(separator: String) throws {
        let line = "let value = 1 // another line"
        let text = String(repeating: line + separator, count: 20_000)
        let chunks = try CompanionFullEventDocument.lineChunks(text)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.utf8.count <= 16_384 })
        #expect(chunks.joined(separator: "\n") == String(repeating: line + "\n", count: 20_000))
    }

    @Test func hugeSingleLinesStayWithinTheUTF8BudgetWithoutLosingScalars() throws {
        for text in [String(repeating: "x", count: 60_000), String(repeating: "界🦊", count: 10_000), "e" + String(repeating: "\u{301}", count: 20_000)] {
            let chunks = try CompanionFullEventDocument.lineChunks(text)
            #expect(chunks.count > 1)
            #expect(chunks.allSatisfy { $0.utf8.count <= 16_384 })
            #expect(chunks.joined().utf8.elementsEqual(text.utf8))
        }
    }

    @Test func reviewLabelsAndTimeoutsExplainTheNextAction() throws {
        for (type, label) in [("tool_call", "Review full input"), ("tool_call_update", "Review full output"), ("permission_request", "Review full request")] {
            let reference = try #require(CompanionEventReference(event: .object(["sessionId": .string("s"), "seq": .integer(1), "type": .string(type)])))
            #expect(reference.reviewLabel == label)
        }
        #expect(CompanionFullReview.reason(URLError(.timedOut)).contains("timed out"))
        #expect(CompanionFullReview.reason(URLError(.timedOut)).contains("desktop"))
    }
}
