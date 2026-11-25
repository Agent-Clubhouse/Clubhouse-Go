import Foundation
import Testing
@testable import CompanionDomain

// Synthetic text only: a Claude-like login prompt with an invented address and no real client, code or credential.
private let syntheticURL = "https://claude.example.test/oauth/authorize?code=true&client_id=SYNTH-0000-1111-2222"
    + "&response_type=code&redirect_uri=https%3A%2F%2Fclaude.example.test%2Foauth%2Fcode%2Fcallback"
    + "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference&code_challenge=SYNTHCHALLENGE0123456789abcdefghijklmnopqrs"
    + "&code_challenge_method=S256&state=SYNTHSTATE0123456789abcdefghijklmnopqrstuvwxyz"

private func linkScreen(_ text: String, cols: Int, rows: Int = 24) -> CompanionTerminalScreen {
    var screen = CompanionTerminalScreen(cols: cols, rows: rows)
    screen.feed(text)
    return screen
}

@Test func syntheticLoginURLIsLongEnoughToWrapSeveralRows() {
    #expect(syntheticURL.count > 200 && syntheticURL.count / 40 >= 5)
}

@Test(arguments: [40, 80])
func aWrappedURLIsExtractedExactly(cols: Int) {
    let screen = linkScreen("Browse to \(syntheticURL)\r\nPaste code here if prompted > ", cols: cols)
    #expect(screen.links().map(\.text) == [syntheticURL])
}

@Test(arguments: [40, 80])
func aWrappedURLIsExactWhenItsHeadHasScrolledIntoScrollback(cols: Int) {
    // Four rows only: the first rows of the URL scroll off while the last stay on screen.
    let screen = linkScreen("Browse to \(syntheticURL)\r\nPaste code here if prompted > ", cols: cols, rows: 4)
    #expect(!screen.scrollback.isEmpty, "The fixture must put part of the URL in scrollback")
    #expect(screen.links().map(\.text) == [syntheticURL])
}

@Test func aLinkLongGoneFromTheGridIsStillFoundInScrollback() {
    let filler = (1...30).map { "line \($0)" }.joined(separator: "\r\n")
    let screen = linkScreen("Browse to \(syntheticURL)\r\n\(filler)", cols: 40, rows: 5)
    #expect(screen.scrollback.count > 10)
    #expect(!screen.grid.flatMap { $0 }.map(\.text).joined().contains("client_id"), "The address is above what the grid shows")
    #expect(screen.links().map(\.text) == [syntheticURL])
}

@Test func aURLExactlyFillingTheRowIsNotJoinedToTheLineAfterIt() {
    // The program ended the line with a newline: wrapping is only deferred, and no row continues.
    let url = "https://claude.example.test/12345"
    let screen = linkScreen("\(url)\r\nmore/text", cols: url.count)
    #expect(screen.links().map(\.text) == [url])
}

@Test func aHardNewlineInsideAnAddressIsNotJoined() {
    // Two lines the program wrote, whatever their width: only the first is an address.
    let screen = linkScreen("see https://claude.example.test/oauth/auth\r\norize?code=true&client_id=SYNTH", cols: 80)
    #expect(screen.links().map(\.text) == ["https://claude.example.test/oauth/auth"])
    let narrow = linkScreen("see https://claude.example.test/oauth/auth\r\norize?code=true&client_id=SYNTH", cols: 20)
    #expect(narrow.links().map(\.text) == ["https://claude.example.test/oauth/auth"])
}

@Test func rowsThatWrapAreJoinedButTheNextHardLineIsNot() {
    // The address wraps over rows; what the program prints on the next line is its own.
    let screen = linkScreen("\(syntheticURL)\r\nhttps://claude.example.test/second", cols: 40)
    #expect(screen.links().map(\.text) == ["https://claude.example.test/second", syntheticURL])
}

@Test func textAfterAWrappedAddressDoesNotJoinIt() {
    let screen = linkScreen("\(syntheticURL) and then some words", cols: 40)
    #expect(screen.links().map(\.text) == [syntheticURL])
}

@Test func linksAreNewestFirstAndEachAddressOnce() {
    let screen = linkScreen("one https://a.example.test/1\r\ntwo https://b.example.test/2\r\nagain https://a.example.test/1", cols: 60)
    #expect(screen.links().map(\.text) == ["https://a.example.test/1", "https://b.example.test/2"])
    #expect(screen.links(limit: 1).map(\.text) == ["https://a.example.test/1"])
}

@Test func punctuationAndFramesAroundAnAddressAreNotPartOfIt() {
    let screen = linkScreen("(see https://a.example.test/x_(y).) and \"https://b.example.test/q?a=1\", then \u{2502} https://c.example.test/z \u{2502}", cols: 120)
    #expect(Set(screen.links().map(\.text)) == ["https://a.example.test/x_(y)", "https://b.example.test/q?a=1", "https://c.example.test/z"])
}

@Test func onlyWebAddressesAreLinks() {
    let screen = linkScreen("file:///etc/hosts javascript://x ftp://a.example.test/f mailto:a@b.test http:// httpx://a.test", cols: 120)
    #expect(screen.links().isEmpty)
}

@Test func aLinkOnTheMainScreenSurvivesAFullScreenProgram() {
    var screen = linkScreen("Browse to \(syntheticURL)\r\n", cols: 40, rows: 6)
    screen.feed("\u{1B}[?1049hfull screen app https://alt.example.test/a")
    #expect(screen.links().map(\.text) == ["https://alt.example.test/a", syntheticURL])
}

@Test func resizingKeepsWhatWasAlreadyWrapped() {
    var screen = linkScreen("Browse to \(syntheticURL)\r\n", cols: 40)
    screen.resize(cols: 40, rows: 10)
    #expect(screen.links().map(\.text) == [syntheticURL])
}

// MARK: OSC 8

@Test func anOSC8HyperlinkIsListedByItsTarget() {
    let screen = linkScreen("\u{1B}]8;;\(syntheticURL)\u{07}Open the login page\u{1B}]8;;\u{07}\r\n", cols: 40)
    #expect(screen.links().map(\.text) == [syntheticURL], "The target, not the drawn text, even when the text isn't an address")
}

@Test func anOSC8HyperlinkWithAStringTerminatorAndParameters() {
    let screen = linkScreen("\u{1B}]8;id=1;https://a.example.test/x?y=1\u{1B}\\here\u{1B}]8;;\u{1B}\\ after", cols: 40)
    #expect(screen.links().map(\.text) == ["https://a.example.test/x?y=1"])
}

@Test func anOSC8HyperlinkBrokenByHardNewlinesIsStillOneLink() {
    // A program that wraps the text itself still names the whole address in the hyperlink.
    let lines = stride(from: 0, to: syntheticURL.count, by: 40).map { start -> String in
        let chunk = syntheticURL.dropFirst(start).prefix(40)
        return String(chunk)
    }
    let screen = linkScreen("\u{1B}]8;;\(syntheticURL)\u{07}" + lines.joined(separator: "\r\n") + "\u{1B}]8;;\u{07}", cols: 80)
    #expect(screen.links().first?.text == syntheticURL, "The whole target comes first; the first line's own text is a shorter address")
}

@Test func anOSC8TargetThatIsNotWebOrIsCutShortIsIgnored() {
    #expect(linkScreen("\u{1B}]8;;file:///etc/hosts\u{07}a\u{1B}]8;;\u{07}", cols: 40).links().isEmpty)
    #expect(linkScreen("\u{1B}]8;;javascript:alert(1)\u{07}a\u{1B}]8;;\u{07}", cols: 40).links().isEmpty)
    #expect(linkScreen("\u{1B}]8;;https://a.example.test/\(String(repeating: "x", count: CompanionTerminalScreen.stringLimit))\u{07}a", cols: 40).links().isEmpty,
            "A target longer than the buffer would be a different address, so it is dropped")
    #expect(linkScreen("\u{1B}]8;;https://a.example.test/x with space\u{07}a\u{1B}]8;;\u{07}", cols: 40).links().isEmpty)
}

@Test func textAfterTheHyperlinkEndsIsNotLinked() {
    let screen = linkScreen("\u{1B}]8;;https://a.example.test/x\u{07}in\u{1B}]8;;\u{07}out", cols: 40)
    let cells = screen.logicalLines()[0]
    #expect(cells.prefix(2).allSatisfy { $0.link != 0 } && cells.dropFirst(2).allSatisfy { $0.link == 0 })
}

@Test func titlesStillWorkAlongsideHyperlinks() {
    var screen = linkScreen("\u{1B}]0;My title\u{07}", cols: 40)
    screen.feed("\u{1B}]8;;https://a.example.test/x\u{07}t\u{1B}]8;;\u{07}")
    #expect(screen.title == "My title" && screen.links().count == 1)
}

// MARK: Wrapped rows

@Test func wrappedRowsAreMarkedWhereAutowrapMovesOn() {
    let screen = linkScreen("abcdef", cols: 4, rows: 3)
    #expect(screen.grid[0].last?.wrapsToNextRow == true)
    #expect(screen.grid[1].last?.wrapsToNextRow == false)
    #expect(screen.logicalLines().map { $0.map(\.text).joined() } == ["abcdef"])
}

@Test func aNewlineAfterAFullRowDoesNotMarkItWrapped() {
    let screen = linkScreen("abcd\r\nef", cols: 4, rows: 3)
    #expect(screen.grid[0].last?.wrapsToNextRow == false)
    #expect(screen.logicalLines().map { $0.map(\.text).joined() } == ["abcd", "ef"])
}

@Test func erasingTheEndOfAWrappedRowUnmarksIt() {
    var screen = linkScreen("abcdef", cols: 4, rows: 3)
    screen.feed("\u{1B}[1;4H\u{1B}[K")
    #expect(screen.grid[0].last?.wrapsToNextRow == false)
}

@Test func withoutAutowrapNothingIsMarked() {
    let screen = linkScreen("\u{1B}[?7labcdef", cols: 4, rows: 3)
    #expect(screen.grid[0].last?.wrapsToNextRow == false)
}
