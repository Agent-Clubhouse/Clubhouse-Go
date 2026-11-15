import Foundation
import Markdown

/// File-only policy. Chat links keep their existing desktop resolution behavior.
nonisolated enum CompanionMarkdownFilePolicy {
    enum Link: Equatable {
        case external(URL)
        case fragment(String)
        case blocked
    }
    enum Image: Equatable, Sendable {
        case remote(URL)
        case data(Data)
        case blocked
    }
    static let maximumImageBytes = 2 * 1024 * 1024
    static let rasterMIMETypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    static func link(_ destination: String) -> Link {
        guard !destination.isEmpty, !destination.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else { return .blocked }
        if destination.hasPrefix("#"), let fragment = destination.dropFirst().removingPercentEncoding, !fragment.isEmpty {
            return .fragment(fragment)
        }
        guard let components = URLComponents(string: destination), let url = components.url else { return .blocked }
        switch components.scheme?.lowercased() {
        case "http", "https":
            guard components.host?.isEmpty == false, components.user == nil, components.password == nil else { return .blocked }
            return .external(url)
        case "mailto":
            return components.path.isEmpty ? .blocked : .external(url)
        default: return .blocked
        }
    }

    static func image(_ destination: String?) -> Image {
        guard let destination else { return .blocked }
        if case .external(let url) = link(destination), url.scheme?.lowercased() == "https",
           !url.pathExtension.lowercased().hasPrefix("svg") {
            return .remote(url)
        }
        // Raster only: SVG is never handed to a document/web renderer, even inside a data URI.
        guard destination.utf8.count <= maximumImageBytes * 4 / 3 + 128,
              let comma = destination.firstIndex(of: ","),
              rasterMIMETypes.map({ "data:\($0);base64" }).contains(destination[..<comma].lowercased()),
              let data = Data(base64Encoded: String(destination[destination.index(after: comma)...])),
              !data.isEmpty, data.count <= maximumImageBytes else { return .blocked }
        return .data(data)
    }
}

nonisolated struct CompanionMarkdownFilePreview: Sendable {
    enum Element: Equatable, Sendable {
        case block(CompanionMarkdownBlock)
        case image(alt: String, resource: CompanionMarkdownFilePolicy.Image)
    }
    enum Mode: String, CaseIterable, Sendable { case preview, source }
    let source: String
    let elements: [Element]
    let anchors: [String: Int]
    /// Candidate dictionary lookups, including collisions, for deterministic complexity regressions.
    let anchorCandidateChecks: Int

    init(source: String) {
        self.init(source: source, checkCancellation: {})
    }

    init(source: String, checkCancellation: () throws -> Void) rethrows {
        self.source = source
        var elements: [Element] = []
        var anchors: [String: Int] = [:]
        var nextSuffix: [String: Int] = [:]
        var anchorCandidateChecks = 0
        try checkCancellation()
        for markup in Document(parsing: source).children {
            try checkCancellation()
            if let paragraph = markup as? Paragraph, paragraph.childCount == 1,
               let image = paragraph.child(at: 0) as? Markdown.Image {
                elements.append(.image(alt: image.plainText, resource: CompanionMarkdownFilePolicy.image(image.source)))
            } else {
                let blocks = CompanionMarkdown.blocks(from: markup, imagesAsPlaceholders: true).map(Self.safe)
                for block in blocks {
                    if case .heading(_, let text) = block {
                        let slug = String(text.characters).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0.isWhitespace }
                            .map { $0.isWhitespace ? "-" : String($0) }.joined()
                        var unique = slug
                        anchorCandidateChecks += 1
                        if anchors[unique] != nil {
                            var suffix = nextSuffix[slug] ?? 1
                            repeat {
                                unique = "\(slug)-\(suffix)"
                                suffix += 1
                                anchorCandidateChecks += 1
                            } while anchors[unique] != nil
                            nextSuffix[slug] = suffix
                        }
                        anchors[unique] = elements.count
                    }
                    elements.append(.block(block))
                }
            }
        }
        self.elements = elements
        self.anchors = anchors
        self.anchorCandidateChecks = anchorCandidateChecks
    }

    /// cmark's initial parse is synchronous; cancellation is checked before it and between native blocks.
    static func load(_ source: String) async throws -> Self {
        let worker = Task.detached(priority: .userInitiated) {
            try Self(source: source, checkCancellation: { try Task.checkCancellation() })
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }

    static func isMarkdown(_ content: CompanionContent) -> Bool {
        content.kind == "text" && !content.tooLarge && content.text != nil
            && ["md", "markdown", "mdx"].contains((content.name as NSString).pathExtension.lowercased())
    }

    /// UTF-16 selection used by the native read-only text view; never rewrites line endings or whitespace.
    func sourceRange(line: Int) -> NSRange {
        Self.sourceRange(in: source, line: line)
    }
    static func sourceRange(in source: String, line: Int) -> NSRange {
        let text = source as NSString
        var range = NSRange(location: 0, length: 0)
        for _ in 1..<max(1, line) {
            let next = NSMaxRange(text.lineRange(for: range))
            if next >= text.length { return NSRange(location: text.length, length: 0) }
            range.location = next
        }
        return range
    }

    private static func safe(_ text: AttributedString) -> AttributedString {
        var result = text
        for run in text.runs {
            if let url = run.link, CompanionMarkdownFilePolicy.link(url.absoluteString) == .blocked {
                result[run.range].link = nil
            }
        }
        return result
    }
    private static func safe(_ block: CompanionMarkdownBlock) -> CompanionMarkdownBlock {
        switch block {
        case .paragraph(let text): return .paragraph(safe(text))
        case .heading(let level, let text): return .heading(level: level, text: safe(text))
        case .quote(let blocks): return .quote(blocks.map(safe))
        case .list(var list):
            list.items = list.items.map { .init(checkbox: $0.checkbox, blocks: $0.blocks.map(safe)) }
            return .list(list)
        case .table(var table):
            table.header = table.header.map(safe)
            table.rows = table.rows.map { $0.map(safe) }
            return .table(table)
        default: return block
        }
    }
}

extension CompanionContentReference {
    /// Explicit line targets are local presentation metadata, not an addition to the desktop contract.
    var markdownLineTarget: (reference: Self, line: Int)? {
        let value: String
        switch self { case .file(let path), .link(let path): value = path; default: return nil }
        guard let regex = try? NSRegularExpression(pattern: #"^(.+\.(?:md|markdown|mdx))(?::([1-9][0-9]*)(?::[1-9][0-9]*)?|#L([1-9][0-9]*)(?:-L[1-9][0-9]*)?)$"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let pathRange = Range(match.range(at: 1), in: value),
              let lineRange = Range(match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2), in: value),
              let line = Int(value[lineRange]) else { return nil }
        let path = String(value[pathRange])
        switch self {
        case .file: return (.file(path), line)
        case .link: return (.link(path), line)
        default: return nil
        }
    }
}
