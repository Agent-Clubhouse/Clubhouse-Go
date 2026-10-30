import Foundation

/// One piece of a long agent reply, shown as its own row in the conversation (#188). A row thousands of points
/// tall kept the timeline's lazy stack re-estimating its layout as you scrolled past it, which stalled the main
/// thread. Slices are cut at Markdown block boundaries (or inside a very long paragraph, list or quote) so no row is
/// much taller than the screen, and the rows still read as one reply.
struct CompanionMessageSlice: Identifiable, Equatable, Sendable {
    /// The reply's row ID for the first slice, so the reply keeps its row identity as it grows past one slice.
    let id: String
    let index: Int
    let isLast: Bool
    /// True when the slice starts partway through a paragraph, list or quote cut at the end of the slice before.
    let continuesBlock: Bool
    let blocks: [CompanionMarkdownBlock]
}

enum CompanionMessageSlices {
    /// About two thirds of a phone screen of body text at the default text size.
    static let defaultBudget = 1_200

    /// The reply's slices. Earlier slices don't change as a streaming reply grows: only its last slice does, and
    /// new slices follow it, so the lazy stack keeps the sizes it has already measured.
    static func slices(messageID: String, text: String, streaming: Bool, budget: Int = defaultBudget) -> [CompanionMessageSlice] {
        let key = "\(budget)\u{0}\(streaming ? 1 : 0)\u{0}\(messageID)\u{0}\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached.slices }
        let groups = split(CompanionMarkdown.document(text, streaming: streaming).blocks, budget: budget)
        let slices = groups.enumerated().map { index, group in
            CompanionMessageSlice(id: index == 0 ? messageID : "\(messageID)#\(index)", index: index, isLast: index == groups.count - 1,
                                  continuesBlock: group.continuesBlock, blocks: group.blocks)
        }
        cache.setObject(Box(slices), forKey: key)
        return slices
    }

    struct Group: Equatable {
        var blocks: [CompanionMarkdownBlock]
        var continuesBlock = false
    }

    /// Packs blocks in order into groups of at most `budget` weight. A block heavier than the budget is cut into
    /// pieces first; a block that can't be cut (code, a table, a heading) gets a group to itself.
    static func split(_ blocks: [CompanionMarkdownBlock], budget: Int) -> [Group] {
        var groups: [Group] = []
        var current = Group(blocks: [])
        var weight = 0
        func flush() {
            if !current.blocks.isEmpty { groups.append(current) }
            current = Group(blocks: [])
            weight = 0
        }
        for block in blocks {
            let pieces = self.weight(block) > budget ? cut(block, budget: budget) : [block]
            for (index, piece) in pieces.enumerated() {
                let pieceWeight = self.weight(piece)
                if weight > 0 && weight + pieceWeight > budget { flush() }
                if current.blocks.isEmpty && index > 0 { current.continuesBlock = true }
                current.blocks.append(piece)
                weight += pieceWeight
            }
        }
        flush()
        return groups.isEmpty ? [Group(blocks: [])] : groups
    }

    /// Roughly how tall a block is, in characters of body text: a line of a code block or a table row counts as a line.
    static func weight(_ block: CompanionMarkdownBlock) -> Int {
        switch block {
        case .paragraph(let text): overhead + text.characters.count
        case .plain(let text): overhead + text.count
        case .heading: overhead * 2
        case .rule: overhead
        case .list(let list): list.items.reduce(0) { $0 + itemWeight($1) }
        case .quote(let blocks): blocks.reduce(0) { $0 + weight($1) }
        case .code(_, let code): overhead * 2 + lineWeight * min(code.split(separator: "\n", omittingEmptySubsequences: false).count, maxInlineLines)
        case .table(let table): overhead * 2 + lineWeight * min(table.rows.count + 1, maxInlineLines)
        }
    }

    private static let overhead = 40
    private static let lineWeight = 60
    /// Inline tables and code blocks show this many lines at most before "Show all…" (#186).
    private static let maxInlineLines = 16

    private static func itemWeight(_ item: CompanionMarkdownList.Item) -> Int {
        item.blocks.reduce(0) { $0 + weight($1) }
    }

    /// Cuts a block heavier than `budget` into consecutive pieces of at most about `budget` each.
    static func cut(_ block: CompanionMarkdownBlock, budget: Int) -> [CompanionMarkdownBlock] {
        switch block {
        case .paragraph(let text):
            return cut(text, budget: budget - overhead).map { .paragraph($0) }
        case .plain(let text):
            return cut(AttributedString(text), budget: budget - overhead).map { .plain(String($0.characters)) }
        case .list(let list):
            return chunks(list.items, budget: budget, weight: itemWeight).reduce(into: []) { pieces, items in
                let start = list.start.map { $0 + pieces.reduce(0) { count, piece in
                    if case .list(let list) = piece { count + list.items.count } else { count }
                } }
                pieces.append(.list(.init(start: start, items: items)))
            }
        case .quote(let blocks):
            return split(blocks, budget: budget).map { .quote($0.blocks) }
        case .heading, .rule, .code, .table:
            return [block]
        }
    }

    /// Splits `items` in order into runs of at most `budget` weight; an item heavier than that has a run to itself.
    private static func chunks<T>(_ items: [T], budget: Int, weight: (T) -> Int) -> [[T]] {
        var runs: [[T]] = []
        var run: [T] = []
        var total = 0
        for item in items {
            let itemWeight = weight(item)
            if !run.isEmpty && total + itemWeight > budget { runs.append(run); run = []; total = 0 }
            run.append(item)
            total += itemWeight
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    /// Cuts text into pieces of at most `budget` characters, preferring a line break, then the end of a sentence,
    /// then a space, in the second half of each piece. Formatting is kept; whitespace at a cut is dropped.
    static func cut(_ text: AttributedString, budget: Int) -> [AttributedString] {
        let budget = max(budget, 80)
        let characters = Array(text.characters)
        guard characters.count > budget else { return [text] }
        var pieces: [AttributedString] = []
        var start = 0
        while start < characters.count {
            var end = min(start + budget, characters.count)
            if end < characters.count {
                let floor = start + budget / 2
                let candidates: [(Character, Character?) -> Bool] = [
                    { c, _ in c == "\n" },
                    { c, next in ".!?".contains(c) && (next?.isWhitespace ?? true) },
                    { c, _ in c.isWhitespace }
                ]
                for matches in candidates {
                    if let cut = (floor..<end).last(where: { matches(characters[$0], $0 + 1 < characters.count ? characters[$0 + 1] : nil) }) {
                        end = cut + 1
                        break
                    }
                }
            }
            var pieceEnd = end
            while pieceEnd > start && characters[pieceEnd - 1].isWhitespace { pieceEnd -= 1 }
            if pieceEnd > start {
                let lower = text.characters.index(text.startIndex, offsetBy: start)
                let upper = text.characters.index(text.startIndex, offsetBy: pieceEnd)
                pieces.append(AttributedString(text[lower..<upper]))
            }
            start = end
            while start < characters.count && characters[start].isWhitespace { start += 1 }
        }
        return pieces
    }

    private final class Box: NSObject {
        let slices: [CompanionMessageSlice]
        init(_ slices: [CompanionMessageSlice]) { self.slices = slices }
    }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()
}

/// A row the conversation lays out: a timeline row, or one slice of an agent reply.
enum CompanionTimelineEntry: Identifiable, Equatable, Sendable {
    case row(CompanionTimelineRow)
    case slice(CompanionMessage, CompanionMessageSlice)

    var id: String {
        switch self {
        case .row(let row): row.id
        case .slice(_, let slice): slice.id
        }
    }
    /// The timeline row this entry shows all or part of.
    var rowID: String {
        switch self {
        case .row(let row): row.id
        case .slice(let message, _): CompanionTimelineItem.message(message).id
        }
    }
    /// True for the entry that finishes its timeline row, where links and hints for the row go.
    var endsRow: Bool {
        switch self {
        case .row: true
        case .slice(_, let slice): slice.isLast
        }
    }

    /// Agent replies and activity become one entry per slice; everything else stays one entry per row.
    static func entries(for rows: [CompanionTimelineRow], budget: Int = CompanionMessageSlices.defaultBudget) -> [CompanionTimelineEntry] {
        rows.flatMap { row -> [CompanionTimelineEntry] in
            guard case .item(.message(let message)) = row, message.role != .user else { return [.row(row)] }
            return CompanionMessageSlices.slices(messageID: row.id, text: message.text, streaming: message.isStreaming, budget: budget)
                .map { .slice(message, $0) }
        }
    }
}
