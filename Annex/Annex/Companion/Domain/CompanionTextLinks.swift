import Foundation
import Markdown

/// Adds destinations without rewriting the displayed text. Only explicit web URLs are detected;
/// files and other schemes still need their existing explicit link and desktop authorization path.
nonisolated enum CompanionTextLinks {
    // Explicit schemes, independent of detector language/TLD heuristics (which can miss a whole
    // code-adjacent paragraph). URI validation and Markdown exclusions are applied below.
    private static let webURL = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}:/])https?://[^\s<>"`|]+"#)

    private static func webLinks(in source: String) -> [(range: NSRange, url: URL)] {
        var links: [(NSRange, URL)] = []
        for match in webURL.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            var destination = String(source[range])
            let before = range.lowerBound == source.startIndex ? nil : source[source.index(before: range.lowerBound)]
            var excess: [Character: Int] = [")": 0, "]": 0, "}": 0]
            for character in destination {
                switch character {
                case "(": excess[")", default: 0] -= 1
                case "[": excess["]", default: 0] -= 1
                case "{": excess["}", default: 0] -= 1
                case ")", "]", "}": excess[character, default: 0] += 1
                default: break
                }
            }
            var quote: Character? = switch before { case "'": "'"; case "“": "”"; case "‘": "’"; default: nil }
            while let last = destination.last {
                if ".,;:!?".contains(last) { destination.removeLast() }
                else if excess[last, default: 0] > 0 {
                    excess[last, default: 0] -= 1
                    destination.removeLast()
                } else if last == quote {
                    quote = nil
                    destination.removeLast()
                } else { break }
            }
            guard destination.lowercased().hasPrefix("https://") || destination.lowercased().hasPrefix("http://"),
                  let url = URL(string: destination), url.host?.isEmpty == false else { continue }
            links.append((NSRange(location: match.range.location, length: destination.utf16.count), url))
        }
        return links
    }

    /// Sent/relayed messages keep every character, including Markdown delimiters and CRLFs.
    /// Syntax positions identify prose and explicit links, so code/HTML/image source stays literal.
    static func literal(_ source: String) -> AttributedString {
        var result = AttributedString(source)
        let spans = spans(in: source)
        for (span, url) in spans.links {
            if let textRange = Range(span, in: source), let target = Range(textRange, in: result) { result[target].link = url }
        }
        for match in bareLinks(in: source, spans: spans) {
            if let textRange = Range(match.range, in: source), let target = Range(textRange, in: result) { result[target].link = match.url }
        }
        return result
    }

    /// cmark does not enable GFM's autolink extension. Protect prose URLs as CommonMark autolinks
    /// before its smart punctuation pass; surrounding prose keeps its existing typography.
    static func markdownSource(_ source: String) -> String {
        guard source.localizedCaseInsensitiveContains("http") else { return source }
        let links = bareLinks(in: source, spans: spans(in: source))
        guard !links.isEmpty else { return source }
        let result = NSMutableString(string: source)
        for match in links.reversed() {
            let original = (source as NSString).substring(with: match.range)
            // Entity syntax inside a bare URL is part of its exact destination, not Markdown markup.
            result.replaceCharacters(in: match.range, with: "<\(original.replacingOccurrences(of: "&", with: "&amp;"))>")
        }
        return result as String
    }

    private struct Spans {
        var excluded: [NSRange] = []
        var links: [(NSRange, URL)] = []
        var formatting: [(range: NSRange, delimiter: Int)] = []
    }

    private static func bareLinks(in source: String, spans: Spans) -> [(range: NSRange, url: URL)] {
        guard source.localizedCaseInsensitiveContains("http") else { return [] }
        let raw = source as NSString
        return webLinks(in: source).compactMap { match in
            guard !spans.excluded.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
            if match.range.location > 0, raw.character(at: match.range.location - 1) == 95 {
                // An underscore in an identifier is not an opening delimiter. Admit it only
                // when cmark identifies an actual emphasis/strong opening at this position.
                guard spans.formatting.contains(where: {
                    $0.range.location + $0.delimiter == match.range.location
                        && raw.substring(with: NSRange(location: $0.range.location, length: $0.delimiter)).allSatisfy { $0 == "_" }
                }) else { return nil }
            }
            var range = match.range
            // A surrounding emphasis delimiter is prose markup. Delimiters *inside* a URL are
            // URL characters, even if the first parse mistook them for emphasis.
            for format in spans.formatting where format.range.location < range.location && NSMaxRange(range) <= NSMaxRange(format.range) {
                let end = NSMaxRange(format.range) - format.delimiter
                if NSMaxRange(range) > end { range.length = max(0, end - range.location) }
            }
            guard range.length > 0, let url = URL(string: raw.substring(with: range)), url.host?.isEmpty == false else { return nil }
            return (range, url)
        }
    }

    private static func spans(in source: String) -> Spans {
        guard source.localizedCaseInsensitiveContains("http") || source.contains("[") || source.contains("<") else { return .init() }
        var spans = Spans()
        let bytes = Array(source.utf8)
        var starts = [0]
        for index in bytes.indices where bytes[index] == 10 || (bytes[index] == 13 && (index + 1 == bytes.count || bytes[index + 1] != 10)) {
            starts.append(index + 1)
        }
        func index(_ location: SourceLocation) -> String.Index? {
            guard location.line > 0, location.line <= starts.count, location.column > 0 else { return nil }
            let offset = starts[location.line - 1] + location.column - 1
            guard offset <= bytes.count else { return nil }
            return String.Index(source.utf8.index(source.utf8.startIndex, offsetBy: offset), within: source)
        }
        func range(_ markup: Markup) -> Range<String.Index>? {
            guard let span = markup.range, let start = index(span.lowerBound), let end = index(span.upperBound), start <= end else { return nil }
            return start..<end
        }
        func visit(_ markup: Markup) {
            switch markup {
            case is CodeBlock, is InlineCode, is HTMLBlock, is InlineHTML, is Markdown.Image:
                if let span = range(markup) { spans.excluded.append(NSRange(span, in: source)) }
                return
            case let link as Markdown.Link:
                guard let destination = link.destination, let url = URL(string: destination),
                      let span = range(link) else { return }
                spans.excluded.append(NSRange(span, in: source))
                spans.links.append((NSRange(span, in: source), url))
            default:
                if markup is Strong || markup is Emphasis || markup is Strikethrough, let span = range(markup) {
                    spans.formatting.append((NSRange(span, in: source), markup is Emphasis ? 1 : 2))
                }
                for child in markup.children { visit(child) }
            }
        }
        visit(Document(parsing: source))
        return spans
    }
}
