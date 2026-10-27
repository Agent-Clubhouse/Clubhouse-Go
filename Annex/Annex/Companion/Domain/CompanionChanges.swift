import Foundation

/// The project root's uncommitted files, as the desktop's Changes view lists them (Clubhouse `ProjectChanges.tsx`).
/// Read-only on the phone: nothing here stages, commits or discards.
struct CompanionChanges: Sendable, Equatable {
    /// False when the project folder isn't a git repository.
    var isRepository: Bool
    var branch: String
    var files: [CompanionChangedFile]
    var ahead = 0
    var behind = 0
    var hasConflicts = false
}

/// One uncommitted file. The status follows the desktop's `statusFile` in `ChangesReview.tsx`.
struct CompanionChangedFile: Identifiable, Sendable, Equatable {
    enum Status: String, Sendable, CaseIterable {
        case added, modified, deleted, renamed
        /// The desktop's `STATUS_LETTER`.
        var letter: String {
            switch self { case .added: "A"; case .modified: "M"; case .deleted: "D"; case .renamed: "R" }
        }
        var label: String {
            switch self { case .added: "Added"; case .modified: "Modified"; case .deleted: "Deleted"; case .renamed: "Renamed" }
        }
    }

    var path: String
    /// The path before a rename or copy.
    var originalPath: String?
    var status: Status
    var staged: Bool
    var untracked: Bool
    var id: String { path }

    /// A `git status --porcelain` code, trimmed as the desktop sends it (`M`, `MM`, `A`, `D`, `R`, `??`).
    /// Untracked or added is Added, then deleted, then renamed; anything else is Modified.
    init(path: String, originalPath: String? = nil, code: String, staged: Bool) {
        self.path = path
        self.originalPath = originalPath
        self.staged = staged
        untracked = code == "??"
        status = untracked || code.contains("A") ? .added : code.contains("D") ? .deleted : code.contains("R") ? .renamed : .modified
    }

    /// The desktop diffs a staged file against the index, and anything else (untracked included) against the working tree.
    var diffsStaged: Bool { staged && !untracked }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "" : folder + "/"
    }
}

// MARK: - Diffs

/// One row of a diff: a line added, removed or unchanged, or a hunk header between folded runs.
struct CompanionDiffLine: Sendable, Equatable {
    enum Kind: Sendable { case added, removed, context, hunk }
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
}

/// A file's changes, worked out on the phone from its two versions (`git/diff` sends whole texts, not a patch).
struct CompanionFileDiff: Sendable, Equatable {
    enum Body: Sendable, Equatable {
        case lines([CompanionDiffLine])
        /// A NUL byte in either version. The desktop collapses binary files too.
        case binary
        /// Both versions are the same, as for a mode change.
        case unchanged
    }

    var path: String
    var body: Body
    var added: Int
    var removed: Int
    /// No version at the base: a new or untracked file.
    var isCreated: Bool
    /// No version in the working tree.
    var isDeleted: Bool

    /// Unchanged lines kept around each change, as in `git diff`.
    static let contextLines = 3

    /// `original` is the base version ("" when the file is new); `modified` is nil for a deleted file.
    /// The desktop's loader does the same (`loadUncommittedDiff`): an empty base means created.
    static func make(path: String, original: String, modified: String?, context: Int = contextLines) -> Self {
        let isCreated = original.isEmpty, isDeleted = modified == nil
        let new = modified ?? ""
        if original.contains("\0") || new.contains("\0") {
            return .init(path: path, body: .binary, added: 0, removed: 0, isCreated: isCreated, isDeleted: isDeleted)
        }
        let all = CompanionDiff.lines(old: original, new: new)
        let added = all.count { $0.kind == .added }, removed = all.count { $0.kind == .removed }
        let body: Body = added + removed == 0 ? .unchanged : .lines(CompanionDiff.hunks(all, context: context))
        return .init(path: path, body: body, added: added, removed: removed, isCreated: isCreated, isDeleted: isDeleted)
    }
}

enum CompanionDiff {
    /// Past this many cells, the middle of a file is shown as replaced rather than diffed line by line,
    /// as the desktop's `diffTexts` does.
    static let maximumCells = 4_000_000

    /// A text's lines. A final newline ends the last line rather than starting an empty one (`textLines`).
    /// Split by UTF-16 unit: Swift reads "\r\n" as one character, which a split on "\n" would miss.
    static func textLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Every line of both versions in order: a longest-common-subsequence diff, removals before additions,
    /// as the desktop's `diffTexts`. Lines both versions start and end with are matched first, so a small
    /// edit to a long file costs little.
    static func lines(old: String, new: String) -> [CompanionDiffLine] {
        let a = textLines(old), b = textLines(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var out: [CompanionDiffLine] = []
        out.reserveCapacity(max(a.count, b.count))
        func context(_ i: Int, _ j: Int) { out.append(.init(kind: .context, text: display(a[i]), oldNumber: i + 1, newNumber: j + 1)) }
        func removed(_ i: Int) { out.append(.init(kind: .removed, text: display(a[i]), oldNumber: i + 1)) }
        func added(_ j: Int) { out.append(.init(kind: .added, text: display(b[j]), newNumber: j + 1)) }

        for i in 0..<prefix { context(i, i) }
        let aEnd = a.count - suffix, bEnd = b.count - suffix
        let n = aEnd - prefix, m = bEnd - prefix
        if n * m > maximumCells {
            for i in prefix..<aEnd { removed(i) }
            for j in prefix..<bEnd { added(j) }
        } else if n > 0 || m > 0 {
            // Compare numbers, not strings, in the n × m loop.
            var ids: [String: Int] = [:]
            let x = a[prefix..<aEnd].map { line -> Int in
                if let id = ids[line] { return id }
                ids[line] = ids.count
                return ids.count - 1
            }
            let y = b[prefix..<bEnd].map { ids[$0] ?? -1 }
            // dp[i][j]: the common subsequence length of x[i...] and y[j...].
            let width = m + 1
            var dp = [Int32](repeating: 0, count: (n + 1) * width)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        dp[i * width + j] = x[i] == y[j] ? dp[(i + 1) * width + j + 1] + 1 : max(dp[(i + 1) * width + j], dp[i * width + j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < n || j < m {
                if i < n, j < m, x[i] == y[j] {
                    context(prefix + i, prefix + j); i += 1; j += 1
                } else if i < n, j >= m || dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
                    removed(prefix + i); i += 1
                } else {
                    added(prefix + j); j += 1
                }
            }
        }
        for k in 0..<suffix { context(aEnd + k, bEnd + k) }
        return out
    }

    /// Changes with `context` unchanged lines around each, and a `@@ -a,b +c,d @@` header before every hunk.
    static func hunks(_ lines: [CompanionDiffLine], context: Int) -> [CompanionDiffLine] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        // Ranges of rows to keep, merged when their context touches.
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let range = max(0, index - context)...min(lines.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        var out: [CompanionDiffLine] = []
        for range in ranges {
            let rows = lines[range]
            let oldCount = rows.count { $0.kind != .added }, newCount = rows.count { $0.kind != .removed }
            // A side with no lines in the hunk starts at the line before it, as git writes it.
            let oldStart = rows.first { $0.oldNumber != nil }?.oldNumber ?? previousNumber(lines, before: range.lowerBound, \.oldNumber)
            let newStart = rows.first { $0.newNumber != nil }?.newNumber ?? previousNumber(lines, before: range.lowerBound, \.newNumber)
            out.append(.init(kind: .hunk, text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"))
            out.append(contentsOf: rows)
        }
        return out
    }

    private static func previousNumber(_ lines: [CompanionDiffLine], before index: Int, _ number: KeyPath<CompanionDiffLine, Int?>) -> Int {
        lines[..<index].last { $0[keyPath: number] != nil }?[keyPath: number] ?? 0
    }

    /// A Windows line ending isn't part of what a person reads.
    private static func display(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}
