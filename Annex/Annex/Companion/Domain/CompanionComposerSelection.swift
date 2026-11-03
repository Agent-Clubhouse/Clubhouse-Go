import Foundation

/// A selection bookmark can outlive the text it came from. Keep offsets, never old String indices.
struct CompanionComposerSelection: Equatable, Sendable {
    let lowerUTF16: Int
    let upperUTF16: Int

    static func capture(_ range: Range<String.Index>?, in text: String) -> Self? {
        guard let range, let lower = String.Index(range.lowerBound, within: text),
              let upper = String.Index(range.upperBound, within: text), lower <= upper else { return nil }
        return Self(lowerUTF16: lower.utf16Offset(in: text), upperUTF16: upper.utf16Offset(in: text))
    }

    func range(in text: String) -> Range<String.Index> {
        let length = text.utf16.count
        let lower = min(length, max(0, lowerUTF16))
        let upper = max(lower, min(length, max(0, upperUTF16)))
        // A changed draft can put an old offset inside a surrogate pair. Never hand that to SwiftUI.
        return Range(NSRange(location: lower, length: upper - lower), in: text) ?? text.endIndex..<text.endIndex
    }
}
