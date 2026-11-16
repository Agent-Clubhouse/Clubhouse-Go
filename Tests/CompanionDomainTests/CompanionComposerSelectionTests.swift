import Foundation
import Testing
@testable import CompanionDomain

@Test func composerSelectionRestoresOnlyIndicesInTheCurrentDraft() throws {
    let original = "a🙂bc"
    let lower = original.index(after: original.startIndex)
    let upper = original.index(after: lower)
    let bookmark = try #require(CompanionComposerSelection.capture(lower..<upper, in: original))
    #expect(bookmark.lowerUTF16 == 1 && bookmark.upperUTF16 == 3)
    #expect(String(original[bookmark.range(in: original)]) == "🙂")
    let shorter = "z"
    #expect(bookmark.range(in: shorter) == shorter.endIndex..<shorter.endIndex)
    #expect(bookmark.range(in: "").isEmpty)
    let changed = "🙂"
    #expect(bookmark.range(in: changed) == changed.endIndex..<changed.endIndex, "An offset inside a new surrogate pair collapses safely")
    #expect(CompanionComposerSelection(lowerUTF16: -2, upperUTF16: 99).range(in: shorter) == shorter.startIndex..<shorter.endIndex)
    #expect(CompanionComposerSelection.capture(nil, in: original) == nil)
}

@Test func composerSelectionNeverRestoresInsideAGrapheme() {
    for text in ["\u{1F642}", "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F1FA}\u{1F1F3}", "\u{1F44D}\u{1F3FD}", "\u{20000}", "e\u{301}"] {
        for offset in 1..<text.utf16.count {
            let bookmark = CompanionComposerSelection(lowerUTF16: 0, upperUTF16: offset)
            #expect(bookmark.range(in: text) == text.endIndex..<text.endIndex,
                "A bookmark inside a surrogate pair or grapheme collapses safely to the end")
        }
    }
}
