import Foundation

/// Values name content on the paired desktop. They are never URLs to load on iOS.
enum CompanionContentReference: Hashable, Sendable, Identifiable {
    case image(String)
    case file(String)
    /// An image this phone sent, shown from its own copy (`CompanionMessageImage.id`).
    case localImage(String)
    var id: String { switch self { case .image(let v): "image:" + v; case .file(let v): "file:" + v; case .localImage(let v): "local-image:" + v } }
    var label: String { switch self { case .image, .localImage: "View image"; case .file(let p): p } }
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
            guard !value.contains("://"), isInsideAgentFolders(value) || isAbsolute(value),
                  !value.contains("\0"), (value.contains("/") || !URL(fileURLWithPath: value).pathExtension.isEmpty), seen.insert(value).inserted else { continue }
            result.append(.file(value))
        }
        return result
    }
    /// The desktop serves files only from the agent's own folders. Relative paths resolve inside them;
    /// absolute and drive paths need `CompanionContentRoots` to cover them, and home paths (`~/x.png`) are never offered.
    static func isInsideAgentFolders(_ path: String) -> Bool {
        guard let first = path.first, first != "/", first != "\\", first != "~" else { return false }
        let drive = path.prefix(3)
        return !(drive.count == 3 && drive.first!.isLetter && drive.dropFirst().first == ":" && ["/", "\\"].contains(drive.last!))
    }
    /// `/a/x` or `C:\a\x`. Network shares (`//host/share`, `\\host\share`) don't count.
    static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("//") || path.hasPrefix("\\\\") { return false }
        if path.hasPrefix("/") || path.hasPrefix("\\") { return true }
        let drive = path.prefix(3)
        return drive.count == 3 && drive.first!.isLetter && drive.dropFirst().first == ":" && ["/", "\\"].contains(drive.last!)
    }
    /// What a timeline item could open on the desktop, once each, in a stable order.
    static func references(in item: CompanionTimelineItem) -> [Self] {
        switch item {
        case .message(let message) where message.role == .assistant: unique(files(in: message.text))
        case .tool(let tool): unique(tool.images + files(in: tool.output ?? ""))
        default: []
        }
    }
    static func references(in row: CompanionTimelineRow) -> [Self] {
        switch row {
        case .item(let item): references(in: item)
        case .tools(let tools): unique(tools.flatMap { references(in: .tool($0)) })
        }
    }
    /// Without the desktop's Rich chat content setting every fetch fails, so no link is offered.
    /// Absolute paths are offered only inside the agent's content roots.
    static func offered(_ references: [Self], richContentAvailable: Bool, roots: CompanionContentRoots = .init()) -> [Self] {
        richContentAvailable ? references.filter { $0.isOffered(roots: roots) } : []
    }
    func isOffered(roots: CompanionContentRoots) -> Bool {
        guard case .file(let path) = self else { return true }
        return Self.isInsideAgentFolders(path) || roots.covers(path)
    }
    static let richContentOffHint = "Turn on Rich chat content in the desktop's Experimental settings to preview images and files on your phone."
    /// With Rich chat content off, one hint replaces every link: under the latest row that would have had some.
    static func hintRowID(in rows: [CompanionTimelineRow], richContentAvailable: Bool) -> String? {
        guard !richContentAvailable else { return nil }
        return rows.last { !offered(references(in: $0), richContentAvailable: true).isEmpty }?.id
    }
    private static func unique(_ references: [Self]) -> [Self] {
        Array(Set(references)).sorted { $0.id < $1.id }
    }
}

/// The folders the desktop serves `/content?path=` from for one agent (`contentRoots` in its chat snapshot).
/// Only a hint: the desktop still resolves each path, symlinks included, and may refuse it.
struct CompanionContentRoots: Equatable, Sendable {
    var paths: [String] = []
    /// A Windows desktop (`ptyHost.platform == "win32"`): `/` and `\` are both separators and case doesn't matter.
    var windows = false

    /// True for a root itself or a path below one, comparing whole segments so `/a/proj` doesn't cover `/a/project`.
    func covers(_ path: String) -> Bool {
        guard CompanionContentReference.isAbsolute(path), !path.contains("\0") else { return false }
        let path = normalized(path)
        guard !path.split(separator: separator).contains("..") else { return false }
        return paths.contains { root in
            let root = normalized(root)
            // A bare `/` normalises to "" and covers nothing.
            return !root.isEmpty && CompanionContentReference.isAbsolute(root + String(separator)) && (path == root || path.hasPrefix(root + String(separator)))
        }
    }
    private var separator: Character { windows ? "\\" : "/" }
    /// Windows paths use `\` and lower case. Trailing separators go, so `/a/proj/` matches `/a/proj` and `C:\` becomes `c:`.
    private func normalized(_ path: String) -> String {
        var value = windows ? path.replacingOccurrences(of: "/", with: "\\").lowercased() : path
        while value.last == separator { value.removeLast() }
        return value
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
