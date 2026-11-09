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

    @Test func chunksPreserveLinesIncludingEmptyLinesAndNeverSplitALongLine() throws {
        let text = "\nshort\n\n" + String(repeating: "long", count: 100) + "\nlast\n"
        let chunks = try CompanionFullEventDocument.lineChunks(text, targetSize: 12)
        #expect(chunks.count > 1)
        #expect(chunks.joined(separator: "\n") == text)
        #expect(chunks.contains(String(repeating: "long", count: 100)))
        let value: AnnexJSON = .object(["path": .string("/work/a")])
        #expect(!value.displayText.contains("\\/"))
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
