import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

// The desktop composer's `/` menu (`Composer.tsx` `slashTokenAt` and its filter), from the chat snapshot's
// `slashCommands` and the session's `commands_available` events. See `docs/mobile-control-v1.md` → Slash commands.

/// One of the session's commands: a CLI built-in, a skill, a custom command or an MCP prompt.
nonisolated struct CompanionSlashCommand: Identifiable, Sendable, Equatable, Hashable {
    /// Typed after the `/`.
    var name: String
    var description: String?
    /// The argument it takes, like `<pr>`.
    var inputHint: String?
    /// Runs only at the start of a message: the CLI's own commands (#2135).
    var startOnly = false
    var id: String { name }

    /// The most a list keeps, as the desktop's `maxCommands`.
    static let maximumCount = 200

    /// A `commands` array from the snapshot or a `commands_available` event. Entries without a usable name are skipped.
    static func list(_ value: AnnexJSON?) -> [CompanionSlashCommand] {
        var seen: Set<String> = []
        return value.arrayValue.compactMap { command -> CompanionSlashCommand? in
            guard let name = command["name"]?.string, !name.isEmpty, !name.contains(where: \.isWhitespace),
                  seen.insert(name).inserted else { return nil }
            func text(_ key: String) -> String? { command[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
            return .init(name: name, description: text("description"), inputHint: text("inputHint"), startOnly: command["startOnly"].boolValue)
        }.prefix(maximumCount).map { $0 }
    }
}

/// The `/word` the caret is in, as character offsets into the draft. `query` is the word without its slash.
nonisolated struct CompanionSlashToken: Sendable, Equatable {
    var start: Int
    var end: Int
    var query: String
}

nonisolated enum CompanionSlashMenu {
    /// The desktop shows up to 8.
    static let limit = 8

    /// The `/word` ending at `caret`: it starts the draft or follows whitespace, and no other slash is in the word,
    /// so paths like `src/app` and `/usr/bin` don't open the menu.
    static func token(in text: String, caret: Int) -> CompanionSlashToken? {
        let characters = Array(text)
        guard caret >= 0, caret <= characters.count else { return nil }
        var start = caret
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        guard start < caret, characters[start] == "/" else { return nil }
        let query = characters[(start + 1)..<caret]
        guard !query.contains("/") else { return nil }
        var end = caret
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        guard !characters[caret..<end].contains("/") else { return nil }
        return .init(start: start, end: end, query: String(query))
    }

    /// Commands whose name starts with the query, ignoring case, in the session's order. A `startOnly` command is
    /// offered only when nothing but whitespace comes before the slash.
    static func matches(_ commands: [CompanionSlashCommand], text: String, token: CompanionSlashToken) -> [CompanionSlashCommand] {
        let atStart = text.prefix(token.start).allSatisfy(\.isWhitespace)
        let query = token.query.lowercased()
        return Array(commands.lazy.filter { (atStart || !$0.startOnly) && $0.name.lowercased().hasPrefix(query) }.prefix(limit))
    }

    /// Replaces the word with `/name ` and returns the draft and the caret after the space. A space already after
    /// the word is reused rather than doubled.
    static func pick(_ command: CompanionSlashCommand, text: String, token: CompanionSlashToken) -> (text: String, caret: Int) {
        let characters = Array(text)
        var after = characters[min(token.end, characters.count)...]
        if after.first == " " { after = after.dropFirst() }
        let inserted = "/\(command.name) "
        return (String(characters[..<token.start]) + inserted + String(after), token.start + inserted.count)
    }

    /// Return picks once a name is started and isn't already typed in full, as on the desktop; Tab always picks.
    static func returnPicks(_ token: CompanionSlashToken, highlighted: CompanionSlashCommand) -> Bool {
        !token.query.isEmpty && token.query != highlighted.name
    }

    /// Return as the text view reports it: `new` is `old` with one newline typed into a `/word` the menu offers. When
    /// Return picks, the newline is dropped and the highlighted command picked instead; otherwise nil, and it stays.
    /// The caret is taken from where the newline went, since the text view may have moved it past the newline already.
    static func pickOnReturn(old: String, new: String, commands: [CompanionSlashCommand], highlighted: Int,
                             dismissedAt: Int?) -> (text: String, caret: Int)? {
        let before = Array(old), after = Array(new)
        guard after.count == before.count + 1 else { return nil }
        var at = 0
        while at < before.count, before[at] == after[at] { at += 1 }
        guard after[at] == "\n", before[at...] == after[(at + 1)...],
              let token = token(in: old, caret: at), token.start != dismissedAt else { return nil }
        let offered = matches(commands, text: old, token: token)
        guard !offered.isEmpty else { return nil }
        let command = offered[min(max(highlighted, 0), offered.count - 1)]
        guard returnPicks(token, highlighted: command) else { return nil }
        return pick(command, text: old, token: token)
    }
}
