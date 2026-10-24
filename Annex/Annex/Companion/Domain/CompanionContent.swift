import Foundation

/// Values name content on the paired desktop. They are never URLs to load on iOS.
enum CompanionContentReference: Hashable, Sendable, Identifiable {
    case image(String)
    case file(String)
    var id: String { switch self { case .image(let v): "image:" + v; case .file(let v): "file:" + v } }
    var label: String { switch self { case .image: "View image"; case .file(let p): p } }
    static func validMediaReference(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].count == 64 && parts[0].allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
            && ["png", "jpg", "gif", "webp", "svg"].contains(String(parts[1]))
    }
    /// Explicit paths in code spans and Markdown links only. No filesystem scan
    /// or network load happens until the user asks for a preview.
    static func files(in text: String) -> [Self] {
        guard let regex = try? NSRegularExpression(pattern: #"`([^`\n]{1,1024})`|\]\(([^)\n]{1,1024})\)"#) else { return [] }
        let bounded = String(text.prefix(64 * 1024)) as NSString
        var seen = Set<String>(); var result: [Self] = []
        for match in regex.matches(in: bounded as String, range: NSRange(location: 0, length: bounded.length)).prefix(40) {
            let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            let value = bounded.substring(with: range)
            guard !value.contains("://"), !value.hasPrefix("//"), !value.hasPrefix("\\"),
                  !value.contains("\0"), (value.contains("/") || !URL(fileURLWithPath: value).pathExtension.isEmpty), seen.insert(value).inserted else { continue }
            result.append(.file(value))
        }
        return result
    }
}

struct CompanionContent: Sendable {
    var kind: String
    var name: String
    var mimeType: String?
    var bytes: Data?
    var text: String?
    var truncated = false
    var tooLarge = false
}
