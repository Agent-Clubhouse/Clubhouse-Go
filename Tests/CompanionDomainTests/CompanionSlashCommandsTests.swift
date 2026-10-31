import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// The composer's `/` menu, matching the desktop's `slashTokenAt` and filter (`Composer.tsx`, #2135).

private func json(_ text: String) -> AnnexJSON { try! JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8)) }
private func event(_ type: String, _ seq: Int64, session: String = "s1", _ data: String) -> AnnexJSON {
    json(#"{"sessionId":"\#(session)","seq":\#(seq),"type":"\#(type)","data":\#(data)}"#)
}
private let compact = CompanionSlashCommand(name: "compact", description: "Compact the context", startOnly: true)
private let clear = CompanionSlashCommand(name: "clear", startOnly: true)
private let review = CompanionSlashCommand(name: "review", inputHint: "<pr>")
private let commands = [compact, clear, review, .init(name: "Code-review")]

/// The draft with `|` marking the caret.
private func token(_ marked: String) -> CompanionSlashToken? {
    let caret = marked.distance(from: marked.startIndex, to: marked.firstIndex(of: "|")!)
    return CompanionSlashMenu.token(in: marked.replacingOccurrences(of: "|", with: ""), caret: caret)
}

struct CompanionSlashTokenTests {
    @Test func aSlashWordAtTheStartOrAfterWhitespaceIsAToken() {
        #expect(token("/|") == .init(start: 0, end: 1, query: ""))
        #expect(token("/com|") == .init(start: 0, end: 4, query: "com"))
        #expect(token("yes and /re|") == .init(start: 8, end: 11, query: "re"))
        #expect(token("first line\n/c|") == .init(start: 11, end: 13, query: "c"))
        // The caret inside the word: the whole word is replaced on a pick.
        #expect(token("/co|mpact now") == .init(start: 0, end: 8, query: "co"))
    }

    @Test func pathsAndMidWordSlashesAreNotTokens() {
        #expect(token("src/app|") == nil)
        #expect(token("/usr/bin|") == nil)
        #expect(token("/usr|/bin") == nil)
        #expect(token("and/|") == nil)
        #expect(token("/compact |") == nil, "A space ends the word")
        #expect(token("|/compact") == nil, "The caret before the slash")
        #expect(token("plain text|") == nil)
        #expect(CompanionSlashMenu.token(in: "/x", caret: 5) == nil)
    }

    @Test func emojiAndAccentsCountAsOneCharacter() {
        #expect(token("👋🏽 /é|") == .init(start: 2, end: 4, query: "é"))
    }
}

struct CompanionSlashMatchTests {
    private func names(_ marked: String, _ list: [CompanionSlashCommand] = commands) -> [String] {
        let text = marked.replacingOccurrences(of: "|", with: "")
        guard let token = token(marked) else { return [] }
        return CompanionSlashMenu.matches(list, text: text, token: token).map(\.name)
    }

    @Test func prefixMatchesIgnoreCaseInTheSessionsOrder() {
        #expect(names("/|") == ["compact", "clear", "review", "Code-review"])
        #expect(names("/c|") == ["compact", "clear", "Code-review"])
        #expect(names("/CO|") == ["compact", "Code-review"])
        #expect(names("/view|").isEmpty, "Prefix, not substring")
    }

    @Test func startOnlyCommandsAreOfferedOnlyAtTheStart() {
        #expect(names("   /c|") == ["compact", "clear", "Code-review"], "Leading whitespace is still the start")
        #expect(names("please /c|") == ["Code-review"])
        #expect(names("line\n/|") == ["review", "Code-review"])
    }

    @Test func atMostEight() {
        let many = (0..<20).map { CompanionSlashCommand(name: "skill-\($0)") }
        #expect(names("/s|", many) == (0..<8).map { "skill-\($0)" })
    }
}

struct CompanionSlashPickTests {
    private func pick(_ command: CompanionSlashCommand, _ marked: String) -> String {
        let text = marked.replacingOccurrences(of: "|", with: "")
        let result = CompanionSlashMenu.pick(command, text: text, token: token(marked)!)
        var shown = result.text
        shown.insert("|", at: shown.index(shown.startIndex, offsetBy: result.caret))
        return shown
    }

    @Test func pickingInsertsTheNameAndASpaceWithTheCaretAfterIt() {
        #expect(pick(compact, "/co|") == "/compact |")
        #expect(pick(review, "yes and /r|") == "yes and /review |")
        #expect(pick(review, "/|") == "/review |")
    }

    @Test func theWholeWordIsReplacedAndAFollowingSpaceIsReused() {
        #expect(pick(compact, "/co|mp now") == "/compact |now")
        #expect(pick(review, "/r| 42") == "/review |42")
        #expect(pick(review, "/r|\nmore") == "/review |\nmore")
    }

    @Test func returnPicksOnlyOnceANameIsStartedAndNotComplete() {
        #expect(!CompanionSlashMenu.returnPicks(.init(start: 0, end: 1, query: ""), highlighted: compact), "\"yes and /\" sends as typed")
        #expect(CompanionSlashMenu.returnPicks(.init(start: 0, end: 3, query: "co"), highlighted: compact))
        #expect(!CompanionSlashMenu.returnPicks(.init(start: 0, end: 8, query: "compact"), highlighted: compact))
    }
}

struct CompanionSlashCommandDecodingTests {
    @Test func listsKeepUsableNamesOnceAndOptionalText() {
        let list = CompanionSlashCommand.list(json(#"""
        [{"name":"compact","description":"Compact","inputHint":"<how>","startOnly":true},
         {"name":"review","description":"","startOnly":"yes"},{"name":""},{"name":"two words"},{"description":"no name"},
         {"name":"compact","description":"duplicate"},7,null]
        """#))
        #expect(list == [.init(name: "compact", description: "Compact", inputHint: "<how>", startOnly: true), .init(name: "review")])
        #expect(CompanionSlashCommand.list(json(#"{"name":"x"}"#)).isEmpty)
        #expect(CompanionSlashCommand.list(nil).isEmpty)
    }

    @Test func listsAreCapped() {
        let many = (0..<300).map { #"{"name":"c\#($0)"}"# }.joined(separator: ",")
        #expect(CompanionSlashCommand.list(json("[\(many)]")).count == CompanionSlashCommand.maximumCount)
    }

    @Test func commandsAvailableReplacesTheListAndANewSessionClearsIt() {
        var projection = CompanionChatProjector()
        projection.apply(event("session_started", 1, #"{"capabilities":{"slashCommands":true}}"#))
        #expect(projection.capabilities.contains(.slashCommands) && projection.slashCommands.isEmpty)
        projection.apply(event("commands_available", 2, #"{"commands":[{"name":"compact","startOnly":true},{"name":"review"}]}"#))
        #expect(projection.slashCommands.map(\.name) == ["compact", "review"])
        projection.apply(event("commands_available", 3, #"{"commands":[{"name":"review"}]}"#))
        #expect(projection.slashCommands.map(\.name) == ["review"])
        projection.apply(event("session_info", 4, #"{"capabilities":{"slashCommands":false}}"#))
        #expect(!projection.capabilities.contains(.slashCommands))
        projection.apply(event("session_started", 1, session: "s2", #"{}"#))
        #expect(projection.slashCommands.isEmpty)
    }
}

struct CompanionSlashCommandGatingTests {
    private func caps(_ extra: String, commands: String = #""chat.send""#) throws -> AnnexCapabilities {
        try json(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[\#(commands)],"idempotency":{"scope":"peer-and-epoch","maxEntries":1,"ttlMs":1}\#(extra)}"#)
            .decode(AnnexCapabilities.self)
    }
    private let session: CompanionCapabilities = [.chat, .slashCommands]

    @Test func olderDesktopsGetNoMenu() throws {
        #expect(CompanionLiveService.slashCommands(commands, live: true, session: session, capabilities: try caps("")) == nil)
        #expect(CompanionLiveService.slashCommands(commands, live: true, session: session, capabilities: nil) == nil)
        #expect(CompanionLiveService.slashCommands(commands, live: true, session: session,
                                                   capabilities: try caps(#","slashCommands":{"version":1}"#, commands: "")) == nil, "No chat.send")
    }

    @Test func currentDesktopsGetTheListWhileALiveSessionReportsCommands() throws {
        let current = try caps(#","slashCommands":{"version":1,"snapshotField":"slashCommands"}"#)
        #expect(CompanionLiveService.slashCommands(commands, live: true, session: session, capabilities: current) == commands)
        #expect(CompanionLiveService.slashCommands([], live: true, session: session, capabilities: current) == [])
        #expect(CompanionLiveService.slashCommands(commands, live: false, session: session, capabilities: current) == nil, "Asleep")
        #expect(CompanionLiveService.slashCommands(commands, live: true, session: [.chat], capabilities: current) == nil, "The session has none")
    }
}
