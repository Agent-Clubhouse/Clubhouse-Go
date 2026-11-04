import Foundation

/// What a composer holds for its image, in memory only. It's never in a draft, a report, the queue or a log:
/// `source` and `marks` have no path out of this value, and only `bytesToSend` goes in a report.
///
/// Edits stay reversible until the first Send tap. `endReversibility()` makes the flattened bytes the new
/// source, so if that save fails, what was covered can't come back. Replace and Remove start a new value.
struct ScreenshotAttachment: Sendable, Equatable {
    let isCapture: Bool
    private(set) var source: Data
    private(set) var marks: [ScreenshotMark] = []
    /// `source` with `marks` flattened in, or `source` itself if it was never edited.
    private(set) var image: Data
    /// `source` already has edits flattened into it that can't be taken out.
    private(set) var editsAreFinal = false
    /// Whether it goes out. While off it stays here, with its edits, and re-checking restores it.
    var included = true

    init(png: Data, isCapture: Bool = false) { source = png; image = png; self.isCapture = isCapture }

    var bytesToSend: Data? { included ? image : nil }
    var hasEdits: Bool { !marks.isEmpty || editsAreFinal }

    /// `image` must be `source` flattened with `marks`, which is what the editor's Done hands back.
    mutating func edit(image: Data, marks: [ScreenshotMark]) { self.image = image; self.marks = marks }
    /// On the first Send tap, whether or not the image is included.
    mutating func endReversibility() {
        editsAreFinal = hasEdits
        source = image; marks = []
    }
}
