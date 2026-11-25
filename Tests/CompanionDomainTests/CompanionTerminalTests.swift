import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// MARK: ANSI screen

private func screen(_ text: String, cols: Int = 20, rows: Int = 5) -> CompanionTerminalScreen {
    var screen = CompanionTerminalScreen(cols: cols, rows: rows)
    screen.feed(text)
    return screen
}

@Test func plainTextLinesAndCarriageReturns() {
    #expect(screen("hello\r\nworld").plainText() == "hello\nworld")
    #expect(screen("abc\rX").plainText() == "Xbc")
    #expect(screen("ab\u{08}\u{08}Z").plainText() == "Zb")
    #expect(screen("a\tb").plainText() == "a       b")
}

@Test func sgrColorsAndAttributes() {
    let s = screen("\u{1B}[1;31mred\u{1B}[0m \u{1B}[38;5;208mo\u{1B}[48;2;1;2;3mx\u{1B}[94mb")
    let runs = s.renderedLines(showCursor: false)[0]
    #expect(runs[0] == .init(text: "red", style: .init(foreground: .indexed(1), bold: true)))
    #expect(runs[1].text == " " && runs[1].style == .init())
    #expect(runs[2].style.foreground == .indexed(208))
    #expect(runs[3].style.background == .rgb(1, 2, 3))
    #expect(runs[4].style.foreground == .indexed(12))
}

@Test func cursorMovementAndErase() {
    var s = screen("line one\r\nline two\r\nline three")
    s.feed("\u{1B}[2;6H\u{1B}[K2")
    #expect(s.plainText() == "line one\nline 2\nline three")
    s.feed("\u{1B}[2J\u{1B}[H")
    #expect(s.plainText() == "")
    s.feed("abc\u{1B}[2D\u{1B}[P")
    #expect(s.plainText() == "ac")
    s.feed("\u{1B}[1G\u{1B}[2@")
    #expect(s.plainText() == "  ac")
}

@Test func wrapIsDeferredUntilTheNextCharacter() {
    var s = screen("abcde", cols: 5, rows: 3)
    #expect(s.cursorRow == 0, "Filling the last column doesn't move to the next line yet")
    s.feed("\r\n")
    #expect(s.cursorRow == 1, "Return after a full line moves down once, not twice")
    s.feed("123456")
    #expect(s.plainText() == "abcde\n12345\n6")
}

@Test func linesScrolledOffTheTopGoToScrollback() {
    let s = screen((1...7).map { "row \($0)" }.joined(separator: "\r\n"), rows: 3)
    #expect(s.scrollback.count == 4)
    #expect(s.plainText() == (1...7).map { "row \($0)" }.joined(separator: "\n"))
}

@Test func scrollRegionKeepsTheLinesOutsideIt() {
    var s = screen("top\r\nb\r\nc\r\nd\r\nstatus", rows: 5)
    s.feed("\u{1B}[2;4r\u{1B}[4;1H\nnew")
    #expect(s.plainText() == "top\nc\nd\nnew\nstatus")
    #expect(s.scrollback.isEmpty, "A region below the top row doesn't feed scrollback")
}

@Test func alternateScreenRestoresTheShell() {
    var s = screen("$ less file")
    s.feed("\u{1B}[?1049h\u{1B}[Hpager text")
    #expect(s.isAlternateScreen)
    #expect(s.plainText() == "pager text")
    s.feed("\u{1B}[?1049l")
    #expect(!s.isAlternateScreen)
    #expect(s.plainText() == "$ less file")
    #expect(s.cursorCol == 11)
}

@Test func sequencesSplitAcrossFramesStillParse() {
    var s = CompanionTerminalScreen(cols: 20, rows: 3)
    s.feed("\u{1B}")
    s.feed("[3")
    s.feed("2mgreen")
    #expect(s.renderedLines(showCursor: false)[0][0].style.foreground == .indexed(2))
    #expect(s.plainText() == "green")
}

@Test func oscTitlesEndAtBellOrStringTerminator() {
    var s = screen("\u{1B}]0;first\u{07}a")
    #expect(s.title == "first")
    s.feed("\u{1B}]2;second\u{1B}\\b")
    #expect(s.title == "second")
    #expect(s.plainText() == "ab", "Neither the title nor the backslash of ST is drawn")
}

@Test func modesTheKeyboardFollows() {
    var s = screen("\u{1B}[?1h\u{1B}[?2004h\u{1B}[?25l")
    #expect(s.applicationCursorKeys && s.bracketedPaste && !s.cursorVisible)
    s.feed("\u{1B}[?1l\u{1B}[?2004l\u{1B}[?25h")
    #expect(!s.applicationCursorKeys && !s.bracketedPaste && s.cursorVisible)
}

@Test func statusQueriesAreAnswered() {
    var s = screen("ab\u{1B}[6n\u{1B}[c")
    #expect(s.takeReplies() == ["\u{1B}[1;3R", "\u{1B}[?1;2c"])
    #expect(s.takeReplies().isEmpty)
}

@Test func combiningMarksJoinTheirCharacter() {
    let s = screen("e\u{0301}x")
    #expect(s.plainText() == "e\u{0301}x")
    #expect(s.cursorCol == 2)
}

@Test func theCursorCellIsMarked() {
    let s = screen("ab")
    let runs = s.renderedLines()[0]
    #expect(runs.last == .init(text: " ", style: .init(), isCursor: true))
}

@Test func resizeKeepsTheCursorLineOnScreen() {
    var s = screen("one\r\ntwo\r\nthree\r\nfour", rows: 4)
    s.resize(cols: 3, rows: 2)
    #expect(s.cursorRow == 1)
    #expect(s.scrollback.map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) } == ["one", "two"])
    #expect(s.plainText() == "one\ntwo\nthr\nfou")
}

@Test func garbageNeverCrashes() {
    var s = CompanionTerminalScreen(cols: 4, rows: 2)
    s.feed("\u{1B}[999;999H\u{1B}[99L\u{1B}[99M\u{1B}[99P\u{1B}[99@\u{1B}[99X\u{1B}[5;2r\u{1B}[0;0r\u{1B}[99S\u{1B}[99T\u{1B}[3b")
    s.feed(String(repeating: "\u{1B}[" + String(repeating: "1;", count: 100), count: 2) + "m\u{1B}[38;5m\u{1B}[48;2;1m")
    s.resize(cols: 1, rows: 1)
    s.feed("wrapped text\u{1B}7\u{1B}8\u{1B}M\u{1B}c")
    #expect(s.cols == 1)
}

// MARK: Keys and input

@Test func controlCodesAndKeySequences() {
    #expect(CompanionTerminalInput.control("c") == "\u{03}")
    #expect(CompanionTerminalInput.control("D") == "\u{04}")
    #expect(CompanionTerminalInput.control("[") == "\u{1B}")
    #expect(CompanionTerminalInput.control("1") == "1")
    #expect(CompanionTerminalKey.up.sequence(applicationCursorKeys: false) == "\u{1B}[A")
    #expect(CompanionTerminalKey.up.sequence(applicationCursorKeys: true) == "\u{1B}OA")
    #expect(CompanionTerminalKey.interrupt.sequence(applicationCursorKeys: false) == "\u{03}")
    #expect(CompanionTerminalInput.typed("ls\n") == "ls\r")
}

@Test func bracketedPasteCannotEndItsOwnBracket() {
    let pasted = CompanionTerminalInput.paste("a\n\u{1B}[201~rm -rf /\r\n", bracketed: true)
    #expect(pasted == "\u{1B}[200~a\r[201~rm -rf /\r\u{1B}[201~")
    #expect(CompanionTerminalInput.paste("a\r\nb", bracketed: false) == "a\rb")
}

// MARK: Colors

@Test func desktopTerminalColorsAreUsedAndCompleted() {
    let theme = CompanionDesktopTheme.transported(["base": "#101010", "accent": "#8b7fff", "text": "#eeeeee"],
                                                  terminal: ["background": "#000011", "foreground": "#ddeeff", "red": "#ff0000", "brightBlue": "nope"])!
    let colors = theme.terminal
    #expect(colors.background == CompanionRGB(hex: "#000011"))
    #expect(colors.foreground == CompanionRGB(hex: "#ddeeff"))
    #expect(colors.ansi[1] == CompanionRGB(hex: "#ff0000"))
    #expect(colors.ansi[12] == CompanionRGB(hex: "#5c5cff"), "An unreadable color falls back to xterm's")
    // Without terminal colors, the theme's own grounds.
    let plain = CompanionDesktopTheme.transported(["base": "#101010", "accent": "#8b7fff", "text": "#eeeeee"])!.terminal
    #expect(plain.background == CompanionRGB(hex: "#101010"))
    #expect(plain.foreground == CompanionRGB(hex: "#eeeeee"))
}

@Test func paletteIndexesAndInverse() {
    let colors = CompanionDesktopTheme.clubhouse.terminal
    #expect(colors.rgb(.indexed(16)) == CompanionRGB(red: 0, green: 0, blue: 0))
    #expect(colors.rgb(.indexed(231)) == CompanionRGB(red: 1, green: 1, blue: 1))
    #expect(colors.rgb(.indexed(232)) == CompanionRGB(red: 8 / 255, green: 8 / 255, blue: 8 / 255))
    #expect(colors.rgb(.default) == nil)
    let inverse = colors.colors(for: .init(inverse: true))
    #expect(inverse.foreground == colors.background && inverse.background == colors.foreground)
}

@Test func liveServiceReadsTerminalColorsBesideTheTheme() {
    let theme = CompanionLiveService.theme(from: .object(["base": .string("#101010"), "accent": .string("#8b7fff")]),
                                           terminal: .object(["background": .string("#123456")]))
    #expect(theme?.terminal.background == CompanionRGB(hex: "#123456"))
}

// MARK: Gating

private func host(terminal: CompanionTerminalSupport?, connection: CompanionConnection = .connected) -> CompanionHost {
    var chat = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: "chat"), name: "Chat", subtitle: "", status: .idle)
    chat.executionMode = "chat"
    var pty = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: "pty"), name: "Pty", subtitle: "", status: .working)
    pty.executionMode = "pty"
    var asleep = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: "asleep"), name: "Asleep", subtitle: "", status: .sleeping)
    asleep.executionMode = "pty"
    var host = CompanionHost(id: "h", name: "Studio", endpoint: "studio", connection: connection,
                             projects: [.init(id: "p", name: "Project", agents: [chat, pty, asleep])])
    host.terminal = terminal
    return host
}

@Test func entryPointsHideWithoutTheDesktopCapability() {
    let project = CompanionTerminalScope.project(.init(hostID: "h", projectID: "p"))
    #expect(CompanionTerminalAvailability.of(project, host: host(terminal: nil)) == .hidden)
    #expect(CompanionTerminalAvailability.of(.agentShell(.init(hostID: "h", projectID: "p", agentID: "chat")), host: host(terminal: nil)) == .hidden)
    let shellsOnly = CompanionTerminalSupport(projectShell: true, agentShell: false, agentAttach: false)
    #expect(CompanionTerminalAvailability.of(project, host: host(terminal: shellsOnly)) == .available)
    #expect(CompanionTerminalAvailability.of(.agentShell(.init(hostID: "h", projectID: "p", agentID: "chat")), host: host(terminal: shellsOnly)) == .hidden)
    #expect(CompanionTerminalAvailability.of(.agentPTY(.init(hostID: "h", projectID: "p", agentID: "pty")), host: host(terminal: shellsOnly)) == .hidden)
}

@Test func attachIsOnlyForRunningTerminalAgents() {
    let all = CompanionTerminalSupport(projectShell: true, agentShell: true, agentAttach: true)
    func attach(_ id: String) -> CompanionTerminalAvailability { .of(.agentPTY(.init(hostID: "h", projectID: "p", agentID: id)), host: host(terminal: all)) }
    #expect(attach("pty") == .available)
    #expect(attach("chat") == .hidden)
    #expect(attach("missing") == .hidden)
    guard case .unavailable = attach("asleep") else { Issue.record("A sleeping terminal agent can't be attached"); return }
}

@Test func entryPointsWaitForTheConnection() {
    let all = CompanionTerminalSupport(projectShell: true, agentShell: true, agentAttach: true)
    let availability = CompanionTerminalAvailability.of(.project(.init(hostID: "h", projectID: "p")), host: host(terminal: all, connection: .reconnecting))
    #expect(availability.isShown && !availability.isAvailable)
    #expect(CompanionTerminalAvailability.of(.project(.init(hostID: "h", projectID: "nope")), host: host(terminal: all)) == .hidden)
}

@Test func liveServiceAdvertisesTerminalsOnlyWithTheCapability() throws {
    func caps(_ block: String) throws -> AnnexCapabilities {
        try JSONDecoder().decode(AnnexCapabilities.self, from: Data(#"{"version":1,"epoch":"e","controlAuth":"mtls-pinned-client","controlAvailable":true,"commands":[],"idempotency":{"scope":"s","maxEntries":1,"ttlMs":1}\#(block)}"#.utf8))
    }
    #expect(CompanionLiveService.terminalSupport(try caps("")) == nil)
    #expect(CompanionLiveService.terminalSupport(nil) == nil)
    #expect(CompanionLiveService.terminalSupport(try caps(#","terminal":{"version":1,"projectShell":true,"agentShell":false,"agentAttach":true}"#))
            == .init(projectShell: true, agentShell: false, agentAttach: true))
}

// MARK: Session

@MainActor private final class FakeChannel: CompanionTerminalChannel {
    var continuation: AsyncStream<CompanionTerminalChannelEvent>.Continuation?
    var opens = 0
    var sent: [String] = []
    var resizes: [String] = []
    var closed = false
    var sendError: AnnexTransportError?
    func events() -> AsyncStream<CompanionTerminalChannelEvent> {
        let (stream, continuation) = AsyncStream<CompanionTerminalChannelEvent>.makeStream()
        self.continuation = continuation
        return stream
    }
    func open(cols: Int, rows: Int) async { opens += 1 }
    func send(_ input: String) async throws { if let sendError { throw sendError }; sent.append(input) }
    func resize(cols: Int, rows: Int) async { resizes.append("\(cols)x\(rows)") }
    func close() async { closed = true }
}

/// The screen's text with the rows it wrapped run together.
@MainActor private func unwrapped(_ session: CompanionTerminalSession) -> String {
    session.screen.logicalLines().map { $0.map(\.text).joined() }.joined(separator: "\n")
}

@MainActor private func settle() async { for _ in 0..<5 { await Task.yield() } }

@MainActor @Test func sessionRunsAShell() async {
    let channel = FakeChannel()
    let session = CompanionTerminalSession(scope: .project(.init(hostID: "h", projectID: "p")), title: "Project", channel: channel)
    session.start()
    await settle()
    #expect(channel.opens == 1 && session.state == .connecting)
    session.resize(cols: 40, rows: 10)
    session.apply(.opened(cwd: "/repo", snapshot: nil, cols: nil, rows: nil))
    await settle()
    #expect(session.state == .running && session.cwd == "/repo")
    #expect(channel.resizes == ["40x10"], "The shell learns the size the view measured before it opened")
    session.type("ls\n")
    session.controlArmed = true
    session.type("c")
    session.press(.up)
    await settle()
    #expect(channel.sent == ["ls\r", "\u{03}", "\u{1B}[A"])
    #expect(!session.controlArmed)
    session.apply(.output("file.txt\r\n"))
    #expect(session.screen.plainText() == "file.txt")
    session.close()
    await settle()
    #expect(channel.closed && session.state == .closed)
}

@MainActor @Test func sessionReopensAfterTheConnectionReturns() async {
    let channel = FakeChannel()
    let session = CompanionTerminalSession(scope: .agentShell(.init(hostID: "h", projectID: "p", agentID: "a")), title: "A", channel: channel)
    session.start()
    session.apply(.opened(cwd: nil, snapshot: nil, cols: nil, rows: nil))
    session.apply(.connectionLost)
    #expect(session.state == .reconnecting)
    session.type("lost")
    await settle()
    #expect(channel.sent.isEmpty, "Keys typed while away are dropped")
    session.apply(.connectionRestored)
    await settle()
    #expect(channel.opens == 2)
    session.apply(.opened(cwd: nil, snapshot: nil, cols: nil, rows: nil))
    #expect(session.state == .running)
    #expect(unwrapped(session).contains("The desktop ended the previous shell and its programs when the connection dropped. This is a new shell."))
    session.apply(.exited(code: 2))
    #expect(session.state == .exited(code: 2))
    #expect(session.screen.plainText().contains("Process exited with code 2."))
    session.restart()
    await settle()
    #expect(channel.opens == 3)
}

@MainActor @Test func agentTerminalKeepsTheDesktopSize() async {
    let channel = FakeChannel()
    let session = CompanionTerminalSession(scope: .agentPTY(.init(hostID: "h", projectID: "p", agentID: "a")), title: "A", channel: channel)
    session.start()
    session.apply(.opened(cwd: nil, snapshot: "\u{1B}[32mready\u{1B}[0m", cols: 100, rows: 30))
    session.resize(cols: 40, rows: 10)
    await settle()
    #expect(session.screen.cols == 100 && session.screen.rows == 30)
    #expect(channel.resizes.isEmpty, "The phone never reflows the desktop's view of the agent")
    #expect(session.screen.plainText() == "ready")
}

// MARK: Live channel

private actor FakeTerminalTransport: AnnexTransporting {
    private var continuation: AsyncStream<AnnexTerminalEvent>.Continuation?
    private(set) var sent: [AnnexTerminalFrame] = []
    func events() async -> AsyncThrowingStream<AnnexTransportEvent, Error> { AsyncThrowingStream { _ in } }
    func connect() async throws {}
    func disconnect() async {}
    func read(_ route: AnnexReadRoute) async throws -> AnnexJSON { .null }
    func execute(_ command: AnnexCommand) async throws -> AnnexCommandReceipt { throw AnnexTransportError.disconnected }
    func terminalEvents() async -> AsyncStream<AnnexTerminalEvent> {
        let (stream, continuation) = AsyncStream<AnnexTerminalEvent>.makeStream()
        self.continuation = continuation
        continuation.yield(.connection(.connected))
        return stream
    }
    private var failReattachSend = false
    /// The capability went away between the check and the send.
    func setFailReattachSend(_ fail: Bool) { failReattachSend = fail }
    func sendTerminal(_ frame: AnnexTerminalFrame) async throws {
        if failReattachSend, case .reattachShell = frame { throw AnnexTransportError.unsupportedCapability("shellReattach") }
        sent.append(frame)
    }
    func push(_ type: String, _ payload: AnnexJSON) { continuation?.yield(.frame(AnnexEnvelope(type: type, payload: payload))) }
    func connection(_ state: AnnexConnectionState) { continuation?.yield(.connection(state)) }
    private var reattach: Bool? = false
    /// Whether this desktop advertises `shellReattach` v1 with a grace period; nil while that isn't known (not
    /// connected, or capabilities not read yet during a flap).
    func setReattach(_ supported: Bool?) { reattach = supported }
    func supportsShellReattach() async -> Bool? { reattach }
}

@MainActor private func collect(_ stream: AsyncStream<CompanionTerminalChannelEvent>, count: Int) async -> [CompanionTerminalChannelEvent] {
    var events: [CompanionTerminalChannelEvent] = []
    for await event in stream {
        events.append(event)
        if events.count == count { break }
    }
    return events
}

@MainActor @Test func previewShellReportsItsScopeAndTheLatestPhoneSize() async throws {
    let channel = CompanionPreviewTerminalChannel(scope: .project(.init(hostID: "preview", projectID: "fixture")))
    let stream = channel.events()
    await channel.open(cols: 40, rows: 10)
    try await channel.send("pwd\rwhoami\rstty size\r")
    await channel.resize(cols: 55, rows: 13)
    try await channel.send("stty size\r")
    await channel.close()
    let events = await collect(stream, count: .max)
    #expect(events.first == .opened(cwd: "/Users/river/fixture", snapshot: nil, cols: nil, rows: nil))
    let output = events.compactMap { if case .output(let text) = $0 { text } else { nil } }.joined()
    #expect(output.contains("\r\n/Users/river/fixture\r\n"))
    #expect(output.contains("\r\nriver\r\n"))
    #expect(output.contains("\r\n10 40\r\n") && output.contains("\r\n13 55\r\n"),
            "The preview must exercise the same resize feedback as a desktop shell")
}

@MainActor @Test func previewShellEditsPasteAndInterruptsWithoutExecutingOnADesktop() async throws {
    let target = CompanionTarget(hostID: "preview", projectID: "fixture", agentID: "worker")
    let channel = CompanionPreviewTerminalChannel(scope: .agentShell(target))
    let stream = channel.events()
    await channel.open(cols: 80, rows: 24)
    try await channel.send("echo worx")
    try await channel.send("\u{7F}ld\r")
    try await channel.send("discard\u{03}\r")
    try await channel.send("\u{1B}[A")
    try await channel.send("\u{1B}[200~echo pasted\u{1B}[201~\r")
    try await channel.send("ls\rcolors\rclear\rmissing\r")
    try await channel.send("\u{08}\t\u{01}exit\r")
    await #expect(throws: CompanionServiceError.self) { try await channel.send("pwd\r") }
    await channel.close()
    let events = await collect(stream, count: .max)
    #expect(events.first == .opened(cwd: "/Users/river/fixture/.clubhouse/agents/worker",
                                   snapshot: nil, cols: nil, rows: nil))
    let output = events.compactMap { if case .output(let text) = $0 { text } else { nil } }.joined()
    #expect(output.contains("\r\nworld\r\n") && output.contains("\r\npasted\r\n"))
    #expect(output.contains("^C\r\n") && !output.contains("command not found: discard"))
    #expect(output.contains("Package.swift") && output.contains("\u{1B}[31m"))
    #expect(output.contains("\u{1B}[2J\u{1B}[H") && output.contains("command not found: missing"))
    #expect(events.last == .exited(code: 0))
}

@MainActor @Test func previewAgentAttachSuppliesADesktopSizedSnapshotAndReopeningClearsShellInput() async throws {
    let target = CompanionTarget(hostID: "preview", projectID: "fixture", agentID: "worker")
    let attach = CompanionPreviewTerminalChannel(scope: .agentPTY(target))
    let stream = attach.events()
    await attach.open(cols: 20, rows: 5)
    await attach.close()
    let events = await collect(stream, count: .max)
    let opened = try #require(events.first)
    guard case .opened(let cwd, let snapshot, let cols, let rows) = opened else {
        Issue.record("Expected a preview attachment snapshot")
        return
    }
    #expect(cwd == nil && cols == 80 && rows == 24)
    let text = try #require(snapshot)
    #expect(screen(text, cols: 80, rows: 24).plainText().contains("Tidy the release checklist"))
    let shell = CompanionPreviewTerminalChannel(scope: .agentShell(target))
    let shellStream = shell.events()
    await shell.open(cols: 80, rows: 24)
    try await shell.send("unfinished")
    await shell.open(cols: 80, rows: 24)
    try await shell.send("echo fresh\r")
    await shell.close()
    let shellEvents = await collect(shellStream, count: .max)
    let output = shellEvents.compactMap { if case .output(let text) = $0 { text } else { nil } }.joined()
    #expect(output.contains("\r\nfresh\r\n") && !output.contains("command not found: unfinishedecho"))
}

@MainActor @Test func liveAttachStitchesOutputOntoTheSnapshot() async {
    let transport = FakeTerminalTransport()
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: .agentPTY(.init(hostID: "h", projectID: "p", agentID: "agent")))
    let events = channel.events()
    await channel.open(cols: 40, rows: 10)
    #expect(await transport.sent == [.attach(agentID: "agent")])
    // Output can arrive before the ack: the part the snapshot holds is dropped.
    await transport.push("pty:data", .object(["agentId": .string("agent"), "data": .string("old"), "outputSeq": .integer(5)]))
    await transport.push("pty:data", .object(["agentId": .string("agent"), "data": .string("XYnew"), "outputSeq": .integer(10)]))
    await transport.push("pty:data", .object(["agentId": .string("other"), "data": .string("not mine")]))
    await transport.push("pty:attach:ack", .object(["agentId": .string("agent"), "buffer": .string("snapshot"), "outputSeq": .integer(7),
                                                    "cols": .integer(120), "rows": .integer(40)]))
    await transport.push("pty:data", .object(["agentId": .string("agent"), "data": .string("!"), "outputSeq": .integer(11)]))
    await transport.push("pty:exit", .object(["agentId": .string("agent"), "exitCode": .integer(0)]))
    let received = await collect(events, count: 4)
    #expect(received == [.opened(cwd: nil, snapshot: "snapshot", cols: 120, rows: 40), .output("new"), .output("!"), .exited(code: 0)])
    await channel.close()
    #expect(await transport.sent.count == 1, "Closing an agent's view sends nothing")
}

@MainActor @Test func liveShellSpawnsInTheAgentsWorktreeAndCloses() async {
    let transport = FakeTerminalTransport()
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: .agentShell(.init(hostID: "h", projectID: "p", agentID: "agent")), sessionID: "s1")
    let events = channel.events()
    await channel.open(cols: 40, rows: 10)
    #expect(await transport.sent == [.spawnShell(sessionID: "s1", projectID: "p", agentID: "agent")])
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/wt")]))
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("$ "), "outputSeq": .integer(2)]))
    await transport.push("error", .object(["message": .string("pty:input data exceeds 64KB limit"), "op": .string("pty:input"), "agentId": .string("s1")]))
    await transport.push("error", .object(["message": .string("too_many_shells"), "op": .string("pty:spawn-shell"), "sessionId": .string("s1")]))
    let received = await collect(events, count: 4)
    #expect(received.first == .opened(cwd: "/wt", snapshot: nil, cols: nil, rows: nil))
    #expect(received[1] == .output("$ "))
    #expect(received[2] == .inputRejected(CompanionTerminalSession.inputRefusedMessage))
    #expect(received[3] == .failed("Too many terminals are open from this phone. Close one and try again."))
    await channel.resize(cols: 50, rows: 12)
    try? await channel.send("ls\r")
    #expect(await transport.sent.last == .input(id: "s1", data: "ls\r"))
}

@MainActor @Test func liveChannelReportsADroppedConnection() async {
    let transport = FakeTerminalTransport()
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: .project(.init(hostID: "h", projectID: "p")), sessionID: "s1")
    let events = channel.events()
    await channel.open(cols: 40, rows: 10)
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1")]))
    await transport.connection(.reconnecting(attempt: 1, delaySeconds: 1))
    await transport.connection(.connecting)
    await transport.connection(.connected)
    let received = await collect(events, count: 3)
    #expect(received == [.opened(cwd: nil, snapshot: nil, cols: nil, rows: nil), .connectionLost, .connectionRestored])
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["ANNEX_REAL_CADENCE_TESTS"] == "1"), .timeLimit(.minutes(2)))
func heldAttachReplyHasNoDeadlineAndReconnectAutomaticallyAttachesAgain() async throws {
    let transport = FakeTerminalTransport()
    let target = CompanionTarget(hostID: "h", projectID: "p", agentID: "agent")
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: .agentPTY(target))
    let session = CompanionTerminalSession(scope: .agentPTY(target), title: "PTY", channel: channel)
    session.start()
    for _ in 0..<1000 where await transport.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await transport.sent == [.attach(agentID: "agent")])
    let started = ContinuousClock.now
    try await Task.sleep(for: .seconds(35))
    #expect(session.state == .connecting)
    #expect(await transport.sent.count == 1)
    print("Held PTY ack: send completed, session still connecting after \(ContinuousClock.now - started); no ack timeout/outcome-unknown")
    await transport.connection(.reconnecting(attempt: 1, delaySeconds: 1))
    await transport.connection(.connected)
    for _ in 0..<1000 where await transport.sent.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await transport.sent == [.attach(agentID: "agent"), .attach(agentID: "agent")])
    let plain = String(repeating: String(repeating: "x", count: 120) + "\r\n", count: 10_229)
    let renderStarted = ContinuousClock.now
    await transport.push("pty:attach:ack", .object(["agentId": .string("agent"), "buffer": .string(plain), "cols": .integer(120), "rows": .integer(40)]))
    for _ in 0..<1000 where session.state != .running { try await Task.sleep(for: .milliseconds(5)) }
    #expect(session.state == .running)
    #expect(!session.screen.plainText().isEmpty)
    print("Plain attach \(plain.utf8.count) bytes applied to real session/screen in \(ContinuousClock.now - renderStarted)")
    session.close()
}

@MainActor @Test func terminalFailureNeedsExplicitRestartButConnectionLossReattaches() async throws {
    let transport = FakeTerminalTransport()
    let target = CompanionTarget(hostID: "h", projectID: "p", agentID: "agent")
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: .agentPTY(target))
    let session = CompanionTerminalSession(scope: .agentPTY(target), title: "PTY", channel: channel)
    session.start()
    for _ in 0..<1000 where await transport.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    await transport.push("error", .object(["op": .string("pty:attach"), "agentId": .string("agent"), "message": .string("agent_not_running")]))
    for _ in 0..<1000 {
        if case .failed = session.state { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    guard case .failed = session.state else { Issue.record("Expected explicit terminal failure"); return }
    await transport.connection(.reconnecting(attempt: 1, delaySeconds: 1))
    await transport.connection(.connected)
    await settle()
    #expect(await transport.sent.count == 1)
    session.restart()
    for _ in 0..<1000 where await transport.sent.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await transport.sent.count == 2)
    session.close()
}

@MainActor @Test func attachSnapshotRestoresBracketedPasteOnlyWhenModeIsPresent() async {
    let channel = FakeChannel()
    let target = CompanionTarget(hostID: "h", projectID: "p", agentID: "a")
    let session = CompanionTerminalSession(scope: .agentPTY(target), title: "A", channel: channel)
    session.start()
    session.apply(.opened(cwd: nil, snapshot: "\u{1B}[?2004hready", cols: 80, rows: 24))
    #expect(session.screen.bracketedPaste)
    session.paste("a\nb\r\nc")
    await settle()
    #expect(channel.sent.last == "\u{1B}[200~a\rb\rc\u{1B}[201~")
    // A screen-only or shortened replay cannot communicate a mode that isn't in its bytes.
    session.apply(.opened(cwd: nil, snapshot: "ready", cols: 80, rows: 24))
    #expect(!session.screen.bracketedPaste)
    session.paste("a\nb")
    await settle()
    #expect(channel.sent.last == "a\rb")
    session.close()
}

@MainActor @Test func refusedInputClearsQueuedKeysWithoutReopeningTerminal() async {
    let channel = FakeChannel()
    let session = CompanionTerminalSession(scope: .project(.init(hostID: "h", projectID: "p")), title: "P", channel: channel)
    session.start()
    session.apply(.opened(cwd: nil, snapshot: "$ ", cols: nil, rows: nil))
    session.paste("pending paste")
    session.type("pending key")
    session.apply(.inputRejected(CompanionTerminalSession.inputRefusedMessage))
    await settle()
    #expect(channel.sent.isEmpty, "A rejection clears input that hasn't been sent yet")
    #expect(session.state == .running)
    #expect(session.inputError == CompanionTerminalSession.inputRefusedMessage)
    #expect(session.screen.plainText() == "$")
    session.clearInputError()
    session.type("fresh")
    await settle()
    #expect(session.inputError == nil)
    #expect(channel.sent == ["fresh"])
    session.close()
}

@MainActor @Test(arguments: ["terminal_input_rejected", "terminal_input_too_large"])
func locallyStoppedInputShowsRefusalWithoutReconnect(code: String) async {
    let channel = FakeChannel()
    channel.sendError = .rejected(status: 400, code: code)
    let session = CompanionTerminalSession(scope: .project(.init(hostID: "h", projectID: "p")), title: "P", channel: channel)
    session.apply(.opened(cwd: nil, snapshot: nil, cols: nil, rows: nil))
    session.paste("text")
    await settle()
    #expect(session.state == .running)
    #expect(session.inputError == CompanionTerminalSession.inputRefusedMessage)
    #expect(channel.sent.isEmpty)
    session.close()
}

@MainActor @Test func attachChannelCannotRecoverModeOmittedFromTheSnapshot() async throws {
    let transport = FakeTerminalTransport()
    let scope = CompanionTerminalScope.agentPTY(.init(hostID: "h", projectID: "p", agentID: "a"))
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: scope)
    let session = CompanionTerminalSession(scope: scope, title: "A", channel: channel)
    session.start()
    for _ in 0..<1000 where await transport.sent.isEmpty { await Task.yield() }
    // An early output mode is covered by outputSeq but absent from a shortened screen-only buffer.
    await transport.push("pty:data", .object(["agentId": .string("a"), "data": .string("\u{1B}[?2004h"), "outputSeq": .integer(8)]))
    await transport.push("pty:attach:ack", .object(["agentId": .string("a"), "buffer": .string("ready"), "outputSeq": .integer(13)]))
    for _ in 0..<1000 where session.state != .running { await Task.yield() }
    #expect(!session.screen.bracketedPaste, "Missing mode cannot be inferred from a rendered screen")
    await transport.push("pty:data", .object(["agentId": .string("a"), "data": .string("\u{1B}[?2004h"), "outputSeq": .integer(21)]))
    for _ in 0..<1000 where !session.screen.bracketedPaste { await Task.yield() }
    #expect(session.screen.bracketedPaste, "A subsequent mode change still works")
    session.paste("x\ny")
    for _ in 0..<1000 {
        if await transport.sent.contains(.input(id: "a", data: "\u{1B}[200~x\ry\u{1B}[201~")) { break }
        await Task.yield()
    }
    #expect(await transport.sent.last == .input(id: "a", data: "\u{1B}[200~x\ry\u{1B}[201~"))
    session.close()
}

@MainActor @Test func aMissingTerminalDuringInputStillOffersRecovery() async {
    let transport = FakeTerminalTransport()
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: .project(.init(hostID: "h", projectID: "p")), sessionID: "s1")
    let events = channel.events()
    await channel.open(cols: 80, rows: 24)
    await transport.push("error", .object(["op": .string("pty:input"), "agentId": .string("s1"), "message": .string("session_not_found")]))
    #expect(await collect(events, count: 1) == [.failed("The desktop lost track of this terminal. Open it again.")])
    await channel.close()
}

// MARK: Login round trip (synthetic)

/// Waits, a few milliseconds at a time, until `condition` holds; the live channel hops through actors and tasks.
@MainActor private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
    for _ in 0..<400 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(what)")
}

private let loginURL = "https://claude.example.test/oauth/authorize?code=true&client_id=SYNTH-0000-1111-2222"
    + "&response_type=code&redirect_uri=https%3A%2F%2Fclaude.example.test%2Foauth%2Fcode%2Fcallback"
    + "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference&code_challenge=SYNTHCHALLENGE0123456789abcdefghijklmnopqrs"
private let loginCode = "SYNTH-CODE-1234"

@MainActor private func openProjectShell(_ transport: FakeTerminalTransport) async -> (CompanionTerminalSession, CompanionLiveTerminalChannel) {
    let scope = CompanionTerminalScope.project(.init(hostID: "h", projectID: "p"))
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: scope, sessionID: "s1")
    let session = CompanionTerminalSession(scope: scope, title: "Project", channel: channel, cols: 40, rows: 10)
    session.start()
    await waitUntil("the spawn") { await transport.sent.count == 1 }
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/repo")]))
    await waitUntil("the shell to open") { session.state == .running }
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("Browse to \(loginURL)\r\nPaste code here if prompted > "), "outputSeq": .integer(1)]))
    await waitUntil("the login prompt") { session.screen.plainText().contains("Paste code here") }
    session.refreshLinks()
    return (session, channel)
}

private func spawns(_ frames: [AnnexTerminalFrame]) -> Int {
    frames.filter { if case .spawnShell = $0 { true } else { false } }.count
}

@MainActor @Test func theLoginRoundTripThroughTheInAppBrowserKeepsTheSameShell() async throws {
    let transport = FakeTerminalTransport()
    let (session, _) = await openProjectShell(transport)
    let link = try #require(session.links.first)
    #expect(session.links.map(\.text) == [loginURL], "The wrapped address comes out exact")

    // Open it in the in-app browser: the app stays in front, and the page (presented over full screen) doesn't
    // take the terminal's view off screen, so the terminal doesn't close.
    session.openInBrowser(link)
    #expect(session.browserLink == link && session.state == .running)
    session.browserDismissed()
    #expect(session.browserLink == nil && session.state == .running)

    // Back from the page, paste the code it gave.
    session.paste(loginCode)
    await waitUntil("the code to be sent") { await transport.sent.count == 2 }
    let sent = await transport.sent.filter { if case .resize = $0 { false } else { true } }
    #expect(spawns(sent) == 1, "One shell the whole time")
    #expect(sent == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .input(id: "s1", data: loginCode)])
    #expect(!sent.contains { if case .close = $0 { true } else { false } })
    #expect(!unwrapped(session).contains("new shell"), "Nothing replaced the shell, so nothing says it was")
    #expect(session.screen.plainText().contains("Paste code here"), "The screen is the same one")
    session.close()
}

@MainActor @Test func theTerminalGoingAwayWhileTheBrowserIsUpClosesItsShell() async throws {
    // Everything presented can be cleared from outside (the Message Dispatcher App Intent): the page goes with the
    // terminal and never calls back, so the shell must still end.
    let transport = FakeTerminalTransport()
    let (session, _) = await openProjectShell(transport)
    let link = try #require(session.links.first)
    session.openInBrowser(link)
    session.close()
    await waitUntil("the close") { await transport.sent.contains { if case .close = $0 { true } else { false } } }
    #expect(session.state == .closed && session.browserLink == nil)
    #expect(await transport.sent.contains(.close(sessionID: "s1")))
}

@MainActor @Test func aDroppedConnectionIsTheOnlyWayToANewShellAndTheScreenSaysSo() async throws {
    let transport = FakeTerminalTransport()
    let (session, _) = await openProjectShell(transport)
    // What backgrounding does today: the connection drops (the desktop ends the shell), then comes back.
    await transport.connection(.reconnecting(attempt: 1, delaySeconds: 1))
    await waitUntil("reconnecting") { session.state == .reconnecting }
    session.paste(loginCode)
    await transport.connection(.connected)
    await waitUntil("a second spawn") { await spawns(transport.sent) == 2 }
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/repo")]))
    await waitUntil("the new shell") { session.state == .running }
    let sent = await transport.sent.filter { if case .resize = $0 { false } else { true } }
    #expect(sent == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .spawnShell(sessionID: "s1", projectID: "p", agentID: nil)],
            "The code pasted while away was dropped, and the shell was started again")
    let text = unwrapped(session)
    #expect(text.contains("The desktop ended the previous shell and its programs when the connection dropped."))
    #expect(text.contains("This is a new shell."))
    session.close()
}

@MainActor @Test func linksAppearShortlyAfterOutputWithoutAskingForThem() async {
    let transport = FakeTerminalTransport()
    let scope = CompanionTerminalScope.project(.init(hostID: "h", projectID: "p"))
    let session = CompanionTerminalSession(scope: scope, title: "P", channel: CompanionLiveTerminalChannel(transport: transport, scope: scope, sessionID: "s1"), cols: 40, rows: 10)
    session.start()
    await waitUntil("the spawn") { await transport.sent.count == 1 }
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1")]))
    await waitUntil("open") { session.state == .running }
    #expect(session.links.isEmpty)
    // The address starts in one message and ends in the next.
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("go to ht"), "outputSeq": .integer(1)]))
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("tps://a.example.test/x\r\n"), "outputSeq": .integer(2)]))
    await waitUntil("the links") { session.links.map(\.text) == ["https://a.example.test/x"] }
    session.close()
}

// MARK: Shell reattach (synthetic)

private func isSpawn(_ frame: AnnexTerminalFrame) -> Bool { if case .spawnShell = frame { true } else { false } }
private func isReattach(_ frame: AnnexTerminalFrame) -> Bool { if case .reattachShell = frame { true } else { false } }
private func isResize(_ frame: AnnexTerminalFrame) -> Bool { if case .resize = frame { true } else { false } }

/// A project shell, opened with ids from `ids`, whose desktop keeps shells through a drop when `reattach`.
@MainActor private func reattachShell(reattach: Bool?, ids: [String] = ["s2", "s3"]) async -> (CompanionTerminalSession, FakeTerminalTransport) {
    let transport = FakeTerminalTransport()
    await transport.setReattach(reattach)
    var remaining = ids
    let scope = CompanionTerminalScope.project(.init(hostID: "h", projectID: "p"))
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: scope, sessionID: "s1", makeSessionID: { remaining.isEmpty ? "s-more" : remaining.removeFirst() })
    let session = CompanionTerminalSession(scope: scope, title: "Project", channel: channel, cols: 40, rows: 10)
    session.start()
    await waitUntil("the spawn") { await transport.sent.contains(where: isSpawn) }
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/repo")]))
    await waitUntil("the shell to open") { session.state == .running }
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("hello\r\n"), "outputSeq": .integer(7)]))
    await waitUntil("output") { session.screen.plainText().contains("hello") }
    return (session, transport)
}

@MainActor private func dropAndRestore(_ session: CompanionTerminalSession, _ transport: FakeTerminalTransport) async {
    await transport.connection(.reconnecting(attempt: 1, delaySeconds: 1))
    await waitUntil("reconnecting") { session.state == .reconnecting }
    await transport.connection(.connected)
}

@MainActor @Test func aDroppedConnectionReattachesTheSameShellWithoutANewShellNotice() async {
    let (session, transport) = await reattachShell(reattach: true)
    await dropAndRestore(session, transport)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    // Output that raced ahead of the ack: part of it is in the snapshot (seq 12), part is new.
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("stale"), "outputSeq": .integer(8)]))
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("AB!!"), "outputSeq": .integer(14)]))
    await transport.push("pty:reattach-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/repo/sub"), "buffer": .string("hello\r\nsnap shot\r\n"),
                                                           "outputSeq": .integer(12), "cols": .integer(100), "rows": .integer(30)]))
    await waitUntil("the shell to open again") { session.state == .running && session.screen.plainText().contains("!!") }
    await transport.push("pty:data", .object(["agentId": .string("s1"), "data": .string("C"), "outputSeq": .integer(15)]))
    await waitUntil("later output") { session.screen.plainText().contains("!!C") }
    session.paste("SYNTH-CODE-1234")
    await waitUntil("input") { await transport.sent.contains(.input(id: "s1", data: "SYNTH-CODE-1234")) }

    let text = session.screen.plainText()
    #expect(text.contains("snap shot"), "The snapshot is applied")
    #expect(!text.contains("stale"), "Output the snapshot already holds is dropped")
    #expect(text.contains("!!C") && !text.contains("AB"), "Only the part of a straddling frame the snapshot lacks is kept")
    #expect(session.cwd == "/repo/sub")
    #expect(!unwrapped(session).contains("new shell") && !unwrapped(session).contains("ended"), "Nothing replaced the shell, so nothing says it was")
    #expect(session.screen.cols == 40 && session.screen.rows == 10, "The shell follows the phone's size, not the one in the ack")
    let sent = await transport.sent
    #expect(sent.filter(isSpawn).count == 1 && sent.filter(isReattach).count == 1, "One spawn, one reattach")
    #expect(sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .reattachShell(sessionID: "s1", cols: 40, rows: 10),
                                              .input(id: "s1", data: "SYNTH-CODE-1234")], "The same id throughout, and input goes to it")
    #expect(sent.last(where: isResize) == .resize(id: "s1", cols: 40, rows: 10), "The reattached shell is resized to the phone")
    session.close()
}

@MainActor @Test(arguments: [
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"session_expired"}"#, CompanionTerminalSession.State.failed("The desktop ended this shell after it was away too long.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","message":"session_expired"}"#, .failed("The desktop ended this shell after it was away too long.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"session_exited","exitCode":3}"#, .exited(code: 3)),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"terminal_unavailable"}"#, .failed("The desktop couldn't reach this shell right now. Try again.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"busy","message":"busy"}"#, .failed("The desktop is busy. Try again in a moment.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"session_not_found"}"#, .failed("The desktop lost track of this terminal. Open it again.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"invalid_session_id"}"#, .failed("The desktop lost track of this terminal. Open it again.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"session_in_use"}"#, .failed("The desktop lost track of this terminal. Open it again.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"authorization_revoked"}"#, .failed("This phone's access to the desktop was revoked. Pair it again to open terminals.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"too_many_shells"}"#, .failed("Too many terminals are open from this phone. Close one and try again.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"internal_error"}"#, .failed("The desktop couldn't open this terminal. Try again.")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","code":"synthetic_unknown"}"#, .failed("The desktop couldn't reattach this shell: synthetic_unknown")),
    (#"{"op":"pty:reattach-shell","sessionId":"s1","message":"synthetic_unknown"}"#, .failed("The desktop couldn't reattach this shell: synthetic_unknown")),
])
func aRefusedReattachSaysWhyAndNeverSpawns(payload: String, expected: CompanionTerminalSession.State) async throws {
    let (session, transport) = await reattachShell(reattach: true)
    await dropAndRestore(session, transport)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", try JSONDecoder().decode(AnnexJSON.self, from: Data(payload.utf8)))
    await waitUntil("the refusal") { session.state != .reconnecting }
    #expect(session.state == expected)
    try? await Task.sleep(for: .milliseconds(60))
    let sent = await transport.sent
    #expect(sent.filter(isSpawn).count == 1, "A refused reattach never starts a shell by itself")
    #expect(sent.filter(isReattach).count == 1)
    #expect(!unwrapped(session).contains("new shell"))
    session.close()
}

@MainActor @Test func tryAgainAfterTerminalUnavailableReattachesUnderTheSameID() async {
    let (session, transport) = await reattachShell(reattach: true)
    await dropAndRestore(session, transport)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", .object(["op": .string("pty:reattach-shell"), "sessionId": .string("s1"), "code": .string("terminal_unavailable")]))
    await waitUntil("the failure") { if case .failed = session.state { true } else { false } }
    session.restart()
    await waitUntil("the second reattach") { await transport.sent.filter(isReattach).count == 2 }
    await transport.push("pty:reattach-shell:ack", .object(["sessionId": .string("s1"), "buffer": .string("hello\r\n"), "outputSeq": .integer(7)]))
    await waitUntil("running") { session.state == .running }
    let sent = await transport.sent
    #expect(sent.filter(isSpawn).count == 1, "Try again re-sends the reattach, never a spawn")
    #expect(sent.filter(isReattach) == [.reattachShell(sessionID: "s1", cols: 40, rows: 10), .reattachShell(sessionID: "s1", cols: 40, rows: 10)])
    #expect(!unwrapped(session).contains("new shell"))
    session.close()
}

@MainActor @Test func aNewShellAfterAnExpiredOrExitedShellUsesANewID() async {
    // Expired while away: the person asks for a new shell.
    let (session, transport) = await reattachShell(reattach: true)
    await dropAndRestore(session, transport)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", .object(["op": .string("pty:reattach-shell"), "sessionId": .string("s1"), "code": .string("session_expired")]))
    await waitUntil("the failure") { if case .failed = session.state { true } else { false } }
    session.restart()
    await waitUntil("the new spawn") { await transport.sent.filter(isSpawn).count == 2 }
    let spawn = await transport.sent.filter(isSpawn).last
    #expect(spawn == .spawnShell(sessionID: "s2", projectID: "p", agentID: nil), "A new shell, a new id")
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s2"), "cwd": .string("/repo")]))
    await waitUntil("the new shell") { session.state == .running }
    session.paste("echo hi")
    await waitUntil("input to the new id") { await transport.sent.contains(.input(id: "s2", data: "echo hi")) }
    #expect(await !transport.sent.contains(.input(id: "s1", data: "echo hi")))
    #expect(unwrapped(session).contains(CompanionTerminalSession.restartedShellNotice), "A new shell says so")
    session.close()
    await waitUntil("the close") { await transport.sent.contains(.close(sessionID: "s2")) }

    // The shell exited: New shell is also a new id.
    let (exited, exitedTransport) = await reattachShell(reattach: true)
    await exitedTransport.push("pty:exit", .object(["agentId": .string("s1"), "exitCode": .integer(0)]))
    await waitUntil("the exit") { exited.state == .exited(code: 0) }
    exited.restart()
    await waitUntil("the new spawn") { await exitedTransport.sent.filter(isSpawn).count == 2 }
    #expect(await exitedTransport.sent.filter(isSpawn).last == .spawnShell(sessionID: "s2", projectID: "p", agentID: nil))
    #expect(await !exitedTransport.sent.contains(where: isReattach))
    exited.close()
}

@MainActor @Test func aSpawnRefusedThenTriedAgainUsesANewID() async {
    let transport = FakeTerminalTransport()
    let scope = CompanionTerminalScope.project(.init(hostID: "h", projectID: "p"))
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: scope, sessionID: "s1", makeSessionID: { "s2" })
    let session = CompanionTerminalSession(scope: scope, title: "P", channel: channel, cols: 40, rows: 10)
    session.start()
    await waitUntil("the spawn") { await transport.sent.contains(where: isSpawn) }
    await transport.push("error", .object(["op": .string("pty:spawn-shell"), "sessionId": .string("s1"), "message": .string("too_many_shells")]))
    await waitUntil("the failure") { if case .failed = session.state { true } else { false } }
    session.restart()
    await waitUntil("the second spawn") { await transport.sent.filter(isSpawn).count == 2 }
    #expect(await transport.sent.filter(isSpawn).last == .spawnShell(sessionID: "s2", projectID: "p", agentID: nil))
    session.close()
}

@MainActor @Test func withoutShellReattachADroppedConnectionRespawnsAndSaysSo() async {
    // No capability, or one this phone doesn't know (version 2 reads as unsupported): the legacy path.
    let (session, transport) = await reattachShell(reattach: false)
    await dropAndRestore(session, transport)
    await waitUntil("a second spawn") { await transport.sent.filter(isSpawn).count == 2 }
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/repo")]))
    await waitUntil("the new shell") { session.state == .running }
    let sent = await transport.sent
    #expect(sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .spawnShell(sessionID: "s1", projectID: "p", agentID: nil)])
    #expect(!sent.contains(where: isReattach))
    let text = unwrapped(session)
    #expect(text.contains("The desktop ended the previous shell and its programs when the connection dropped."))
    #expect(text.contains("This is a new shell."))
    session.close()
}

/// A project shell whose spawn was sent but whose ack never arrived before the connection dropped and came back.
@MainActor private func unackedSpawn(reattach: Bool?) async -> (CompanionTerminalSession, FakeTerminalTransport) {
    let transport = FakeTerminalTransport()
    await transport.setReattach(reattach)
    let scope = CompanionTerminalScope.project(.init(hostID: "h", projectID: "p"))
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: scope, sessionID: "s1", makeSessionID: { "s2" })
    let session = CompanionTerminalSession(scope: scope, title: "P", channel: channel, cols: 40, rows: 10)
    session.start()
    await waitUntil("the spawn") { await transport.sent.contains(where: isSpawn) }
    await dropAndRestore(session, transport)
    return (session, transport)
}

@MainActor @Test func aSpawnWhoseAckWasLostIsReattachedNotRespawned() async {
    // The desktop may have made the shell and lost only the ack; a spawn under the same id would replace it.
    let (session, transport) = await unackedSpawn(reattach: true)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    #expect(await transport.sent.filter(isSpawn).count == 1, "No second spawn while a reattach can still find the shell")
    await transport.push("pty:reattach-shell:ack", .object(["sessionId": .string("s1"), "cwd": .string("/repo"), "buffer": .string("river % "), "outputSeq": .integer(8)]))
    await waitUntil("running") { session.state == .running }
    session.paste("SYNTH-CODE-1234")
    await waitUntil("input") { await transport.sent.contains(.input(id: "s1", data: "SYNTH-CODE-1234")) }
    let sent = await transport.sent
    #expect(sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .reattachShell(sessionID: "s1", cols: 40, rows: 10),
                                              .input(id: "s1", data: "SYNTH-CODE-1234")], "It resumes under the same id")
    #expect(!unwrapped(session).contains("new shell") && !unwrapped(session).contains("ended"))
    session.close()
}

@MainActor @Test(arguments: ["session_not_found", "invalid_session_id"])
func aSpawnThatNeverReachedTheDesktopIsShownAndOnlyNewShellStartsOneUnderANewID(code: String) async {
    let (session, transport) = await unackedSpawn(reattach: true)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", .object(["op": .string("pty:reattach-shell"), "sessionId": .string("s1"), "code": .string(code)]))
    await waitUntil("the refusal") { if case .failed = session.state { true } else { false } }
    #expect(session.state == .failed(CompanionLiveTerminalChannel.neverStartedMessage))
    #expect(CompanionLiveTerminalChannel.neverStartedMessage == "This shell didn't start before the connection dropped.")
    // Nothing starts a shell behind the person's back.
    try? await Task.sleep(for: .milliseconds(80))
    #expect(await transport.sent.filter(isSpawn).count == 1, "Only the original spawn: a refusal never spawns")
    #expect(await transport.sent.filter(isReattach).count == 1)
    // Their New shell spawns exactly once, under a new id, without a notice (nothing had opened, nothing ended).
    session.restart()
    await waitUntil("the new spawn") { await transport.sent.filter(isSpawn).count == 2 }
    try? await Task.sleep(for: .milliseconds(80))
    let sent = await transport.sent
    #expect(sent.filter(isSpawn) == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .spawnShell(sessionID: "s2", projectID: "p", agentID: nil)])
    #expect(sent.filter(isReattach).count == 1, "New shell is a spawn, not another reattach")
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s2"), "cwd": .string("/repo")]))
    await waitUntil("running") { session.state == .running }
    session.paste("echo hi")
    await waitUntil("input to the new id") { await transport.sent.contains(.input(id: "s2", data: "echo hi")) }
    #expect(await !transport.sent.contains(.input(id: "s1", data: "echo hi")))
    #expect(!unwrapped(session).contains("new shell") && !unwrapped(session).contains("ended"))
    session.close()
}

@MainActor @Test(arguments: ["session_in_use", "session_expired", "authorization_revoked", "internal_error", "synthetic_unknown"])
func anotherRefusalOfAnUnackedSpawnsReattachDoesNotSpawn(code: String) async {
    let (session, transport) = await unackedSpawn(reattach: true)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", .object(["op": .string("pty:reattach-shell"), "sessionId": .string("s1"), "code": .string(code)]))
    await waitUntil("the refusal") { if case .failed = session.state { true } else { false } }
    try? await Task.sleep(for: .milliseconds(60))
    #expect(await transport.sent.filter(isSpawn).count == 1, "A refusal never spawns")
    session.close()
}

@MainActor @Test func withoutShellReattachAnUnackedSpawnIsRespawnedUnderTheSameID() async {
    let (session, transport) = await unackedSpawn(reattach: false)
    await waitUntil("a second spawn") { await transport.sent.filter(isSpawn).count == 2 }
    #expect(await transport.sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .spawnShell(sessionID: "s1", projectID: "p", agentID: nil)])
    #expect(await !transport.sent.contains(where: isReattach))
    session.close()
}

@MainActor @Test func aFailedSpawnTriedAgainIsNeverReattached() async {
    // A refused spawn leaves nothing to reclaim: the next try is a spawn under a new id, even with the capability.
    let transport = FakeTerminalTransport()
    await transport.setReattach(true)
    let scope = CompanionTerminalScope.project(.init(hostID: "h", projectID: "p"))
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: scope, sessionID: "s1", makeSessionID: { "s2" })
    let session = CompanionTerminalSession(scope: scope, title: "P", channel: channel, cols: 40, rows: 10)
    session.start()
    await waitUntil("the spawn") { await transport.sent.contains(where: isSpawn) }
    await transport.push("error", .object(["op": .string("pty:spawn-shell"), "sessionId": .string("s1"), "message": .string("too_many_shells")]))
    await waitUntil("the failure") { if case .failed = session.state { true } else { false } }
    session.restart()
    await waitUntil("the second spawn") { await transport.sent.filter(isSpawn).count == 2 }
    #expect(await transport.sent.filter(isSpawn).last == .spawnShell(sessionID: "s2", projectID: "p", agentID: nil))
    #expect(await !transport.sent.contains(where: isReattach))
    session.close()
}

// MARK: Capability unknown

private let unreachable = CompanionTerminalSession.State.failed("The desktop couldn't reach this shell right now. Try again.")

@MainActor @Test func anUnknownCapabilityWhileConnectedFailsRetriablyAndTryAgainReattaches() async {
    // The socket stays connected but the capabilities read failed: no connection edge will ever come, so the shell
    // must not sit in "Reconnecting" forever.
    let (session, transport) = await reattachShell(reattach: true)
    await transport.setReattach(nil)
    await dropAndRestore(session, transport)
    await waitUntil("the retriable failure") { session.state == unreachable }
    try? await Task.sleep(for: .milliseconds(60))
    var sent = await transport.sent
    #expect(sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil)], "Nothing is sent and nothing is spawned")
    #expect(!unwrapped(session).contains("new shell") && !unwrapped(session).contains("ended"))

    // Try again once the capability is known: the same shell, reattached under the same id.
    await transport.setReattach(true)
    session.restart()
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("pty:reattach-shell:ack", .object(["sessionId": .string("s1"), "buffer": .string("hello\r\n"), "outputSeq": .integer(7)]))
    await waitUntil("running") { session.state == .running }
    session.paste("SYNTH-CODE-1234")
    await waitUntil("input") { await transport.sent.contains(.input(id: "s1", data: "SYNTH-CODE-1234")) }
    sent = await transport.sent
    #expect(sent.filter(isSpawn).count == 1, "Never a same-id spawn, which would replace a kept shell")
    #expect(sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil), .reattachShell(sessionID: "s1", cols: 40, rows: 10),
                                              .input(id: "s1", data: "SYNTH-CODE-1234")])
    session.close()
}

@MainActor @Test func terminalUnavailableThenAnUnknownCapabilityKeepsTheShellForTheNextTryAgain() async {
    let (session, transport) = await reattachShell(reattach: true)
    await dropAndRestore(session, transport)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", .object(["op": .string("pty:reattach-shell"), "sessionId": .string("s1"), "code": .string("terminal_unavailable")]))
    await waitUntil("the failure") { session.state == unreachable }
    // Try again while the capability is unknown: the same retriable failure, nothing sent.
    await transport.setReattach(nil)
    session.restart()
    await waitUntil("the failure again") { session.state == unreachable }
    try? await Task.sleep(for: .milliseconds(60))
    let held = await transport.sent
    #expect(held.filter(isReattach).count == 1 && held.filter(isSpawn).count == 1)
    // And once it is known, one more reattach under the same id.
    await transport.setReattach(true)
    session.restart()
    await waitUntil("the second reattach") { await transport.sent.filter(isReattach).count == 2 }
    let sent = await transport.sent
    #expect(sent.filter(isSpawn).count == 1)
    #expect(sent.filter(isReattach) == [.reattachShell(sessionID: "s1", cols: 40, rows: 10), .reattachShell(sessionID: "s1", cols: 40, rows: 10)])
    session.close()
}

@MainActor @Test func anUnackedSpawnWithAnUnknownCapabilityFailsRetriablyThenReattaches() async {
    let (session, transport) = await unackedSpawn(reattach: nil)
    await waitUntil("the retriable failure") { session.state == unreachable }
    try? await Task.sleep(for: .milliseconds(60))
    #expect(await transport.sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil)], "No second spawn while the capability is unknown")
    await transport.setReattach(true)
    session.restart()
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    #expect(await transport.sent.filter(isSpawn).count == 1)
    #expect(await transport.sent.filter(isReattach) == [.reattachShell(sessionID: "s1", cols: 40, rows: 10)])
    session.close()
}

@MainActor @Test func aCapabilityLostBetweenTheCheckAndTheSendIsTheSameRetriableFailure() async {
    let (session, transport) = await reattachShell(reattach: true)
    await transport.setFailReattachSend(true)
    await dropAndRestore(session, transport)
    await waitUntil("the retriable failure") { session.state == unreachable }
    #expect(session.state != .failed(CompanionTerminalAvailability.updateDesktop), "A flap isn't \"update the desktop\"")
    await transport.setFailReattachSend(false)
    session.restart()
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    #expect(await transport.sent.filter(isSpawn).count == 1)
    #expect(await transport.sent.filter(isReattach) == [.reattachShell(sessionID: "s1", cols: 40, rows: 10)])
    session.close()
}

@MainActor @Test func anUnknownCapabilityWhileDisconnectedStaysReconnectingUntilTheNextEdge() async {
    let (session, transport) = await reattachShell(reattach: true)
    await transport.setReattach(nil)
    // The connection drops, and the person tries again while it is still down: a real edge will come.
    await transport.connection(.reconnecting(attempt: 1, delaySeconds: 1))
    await waitUntil("reconnecting") { session.state == .reconnecting }
    session.restart()
    try? await Task.sleep(for: .milliseconds(100))
    await waitUntil("reconnecting again") { session.state == .reconnecting }
    #expect(await transport.sent.filter { !isResize($0) } == [.spawnShell(sessionID: "s1", projectID: "p", agentID: nil)], "Nothing is sent while it isn't known")
    #expect(!unwrapped(session).contains("new shell") && !unwrapped(session).contains("ended"))
    // The connection settles with the capability: the edge reopens it, reattaching under the same id.
    await transport.setReattach(true)
    await transport.connection(.connected)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    #expect(await transport.sent.filter(isSpawn).count == 1)
    #expect(await transport.sent.filter(isReattach) == [.reattachShell(sessionID: "s1", cols: 40, rows: 10)])
    session.close()
}

@MainActor @Test func aKnownLegacyDesktopStillRespawnsAfterAnUnknownCapabilitySettles() async {
    // Unknown first (retriable failure), then known to lack shellReattach: only then the legacy same-id spawn.
    let (session, transport) = await reattachShell(reattach: nil)
    await dropAndRestore(session, transport)
    await waitUntil("the retriable failure") { session.state == unreachable }
    #expect(await transport.sent.filter(isSpawn).count == 1)
    await transport.setReattach(false)
    session.restart()
    await waitUntil("a second spawn") { await transport.sent.filter(isSpawn).count == 2 }
    #expect(await !transport.sent.contains(where: isReattach))
    session.close()
}

// MARK: Input refusals by code or message

@MainActor @Test(arguments: [
    (#"{"op":"pty:input","agentId":"s1","code":"pty:input data exceeds 64KB limit","message":"something else"}"#, true),
    (#"{"op":"pty:input","agentId":"s1","code":"something else","message":"pty:input data exceeds 64KB limit"}"#, true),
    (#"{"op":"pty:input","agentId":"s1","message":"pty:input data exceeds 64KB limit"}"#, true),
    (#"{"op":"pty:input","agentId":"s1","code":"pty:input rejected"}"#, true),
    (#"{"op":"pty:input","agentId":"s1","code":"unrelated","message":"also unrelated"}"#, false),
])
func aRefusedInputIsRecognizedByCodeOrMessage(payload: String, isInputRefusal: Bool) async throws {
    let transport = FakeTerminalTransport()
    let channel = CompanionLiveTerminalChannel(transport: transport, scope: .project(.init(hostID: "h", projectID: "p")), sessionID: "s1")
    let events = channel.events()
    await channel.open(cols: 40, rows: 10)
    await transport.push("pty:spawn-shell:ack", .object(["sessionId": .string("s1")]))
    await transport.push("error", try JSONDecoder().decode(AnnexJSON.self, from: Data(payload.utf8)))
    let received = await collect(events, count: 2)
    #expect(received[0] == .opened(cwd: nil, snapshot: nil, cols: nil, rows: nil))
    if isInputRefusal {
        #expect(received[1] == .inputRejected(CompanionTerminalSession.inputRefusedMessage), "A refused paste never replaces or fails the shell")
    } else {
        // Not an input refusal: it is an error for the shell, as before.
        if case .failed = received[1] {} else { Issue.record("Expected a failure, got \(received[1])") }
    }
}

// MARK: busy (desktop #3843: refused before anything is claimed; the shell is still detached)

@MainActor @Test func aBusyDesktopIsRetriableUnderTheSameIDAndNeverSpawns() async {
    let (session, transport) = await reattachShell(reattach: true)
    await dropAndRestore(session, transport)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", .object(["message": .string("busy"), "code": .string("busy"), "op": .string("pty:reattach-shell"), "sessionId": .string("s1")]))
    await waitUntil("the retriable failure") { session.state == .failed("The desktop is busy. Try again in a moment.") }
    try? await Task.sleep(for: .milliseconds(60))
    #expect(await transport.sent.filter(isSpawn).count == 1, "A busy refusal never spawns")
    // Try again re-sends the reattach under the SAME id (a new id would abandon a shell that is still detached).
    session.restart()
    await waitUntil("the second reattach") { await transport.sent.filter(isReattach).count == 2 }
    await transport.push("pty:reattach-shell:ack", .object(["sessionId": .string("s1"), "buffer": .string("hello\r\n"), "outputSeq": .integer(7)]))
    await waitUntil("running") { session.state == .running }
    session.paste("SYNTH-CODE-1234")
    await waitUntil("input") { await transport.sent.contains(.input(id: "s1", data: "SYNTH-CODE-1234")) }
    let sent = await transport.sent
    #expect(sent.filter(isSpawn).count == 1)
    #expect(sent.filter(isReattach) == [.reattachShell(sessionID: "s1", cols: 40, rows: 10), .reattachShell(sessionID: "s1", cols: 40, rows: 10)])
    #expect(!unwrapped(session).contains("new shell") && !unwrapped(session).contains("ended"))
    session.close()
}

@MainActor @Test func aBusyDesktopForAnUnackedSpawnIsAlsoRetriableUnderTheSameID() async {
    let (session, transport) = await unackedSpawn(reattach: true)
    await waitUntil("the reattach") { await transport.sent.contains(where: isReattach) }
    await transport.push("error", .object(["message": .string("busy"), "code": .string("busy"), "op": .string("pty:reattach-shell"), "sessionId": .string("s1")]))
    await waitUntil("the retriable failure") { session.state == .failed("The desktop is busy. Try again in a moment.") }
    session.restart()
    await waitUntil("the second reattach") { await transport.sent.filter(isReattach).count == 2 }
    try? await Task.sleep(for: .milliseconds(60))
    #expect(await transport.sent.filter(isSpawn).count == 1, "Zero spawns beyond the original")
    #expect(await transport.sent.filter(isReattach) == [.reattachShell(sessionID: "s1", cols: 40, rows: 10), .reattachShell(sessionID: "s1", cols: 40, rows: 10)])
    session.close()
}
