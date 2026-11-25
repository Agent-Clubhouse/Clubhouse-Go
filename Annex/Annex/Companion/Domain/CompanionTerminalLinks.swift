import Foundation

/// A web link found in a terminal's output, kept exactly as the program wrote it.
struct CompanionTerminalLink: Hashable, Identifiable, Sendable {
    /// The exact text: what Copy puts on the pasteboard.
    let text: String
    let url: URL
    var id: String { text }
    var host: String { url.host() ?? "" }

    /// Only a complete http or https address with a host: the in-app browser raises on anything else.
    init?(_ text: String) {
        guard text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) || $0.value > 0x9F }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false else { return nil }
        self.text = text; self.url = url
    }
}

extension CompanionTerminalScreen {
    /// Web links in scrollback and on screen, newest first, each address once. A link is an `http(s)://` address in
    /// the text (joined across rows the screen wrapped, never across a hard newline) or the target of an OSC 8
    /// hyperlink, which is listed by its target rather than by the text drawn over it.
    func links(limit: Int = 8) -> [CompanionTerminalLink] {
        var found: [(link: CompanionTerminalLink, line: Int, offset: Int)] = []
        for (lineIndex, line) in logicalLines().enumerated() {
            var seen: Set<UInt32> = []
            for (offset, cell) in line.enumerated() where cell.link != 0 && seen.insert(cell.link).inserted {
                if let target = linkTarget(cell.link), let link = CompanionTerminalLink(target) {
                    found.append((link, lineIndex, offset))
                }
            }
            let text = line.map(\.text).joined()
            guard text.contains("://") else { continue }
            for match in Self.webURL.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text),
                      let link = CompanionTerminalLink(Self.trimmed(text[range])) else { continue }
                found.append((link, lineIndex, match.range.location))
            }
        }
        // Later lines first; later on a line first. A link seen again counts where it was last seen.
        found.sort { ($0.line, $0.offset) > ($1.line, $1.offset) }
        var result: [CompanionTerminalLink] = []
        for entry in found where !result.contains(entry.link) {
            result.append(entry.link)
            if result.count == limit { break }
        }
        return result
    }

    private func linkTarget(_ id: UInt32) -> String? {
        linkTargets.indices.contains(Int(id) - 1) ? linkTargets[Int(id) - 1] : nil
    }

    /// An address runs to whitespace, a quote or bracket that can't be in one, or the box-drawing characters a
    /// program draws its frames with.
    private static let webURL = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])https?://[^\s<>"`|─-╿]+"#)

    /// Without the punctuation a sentence puts after an address, and a closing bracket its address never opened.
    private static func trimmed(_ match: Substring) -> String {
        var url = match
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = url.last {
            if ".,;:!?'".contains(last) {
                url.removeLast()
            } else if let open = pairs[last], url.filter({ $0 == last }).count > url.filter({ $0 == open }).count {
                url.removeLast()
            } else {
                break
            }
        }
        return String(url)
    }
}
