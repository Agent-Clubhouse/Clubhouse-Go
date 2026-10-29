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
    func events() -> AsyncStream<CompanionTerminalChannelEvent> {
        let (stream, continuation) = AsyncStream<CompanionTerminalChannelEvent>.makeStream()
        self.continuation = continuation
        return stream
    }
    func open(cols: Int, rows: Int) async { opens += 1 }
    func send(_ input: String) async throws { sent.append(input) }
    func resize(cols: Int, rows: Int) async { resizes.append("\(cols)x\(rows)") }
    func close() async { closed = true }
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
    #expect(session.screen.plainText().contains("This is a new shell."))
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
    func sendTerminal(_ frame: AnnexTerminalFrame) async throws { sent.append(frame) }
    func push(_ type: String, _ payload: AnnexJSON) { continuation?.yield(.frame(AnnexEnvelope(type: type, payload: payload))) }
    func connection(_ state: AnnexConnectionState) { continuation?.yield(.connection(state)) }
}

@MainActor private func collect(_ stream: AsyncStream<CompanionTerminalChannelEvent>, count: Int) async -> [CompanionTerminalChannelEvent] {
    var events: [CompanionTerminalChannelEvent] = []
    for await event in stream {
        events.append(event)
        if events.count == count { break }
    }
    return events
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
    guard case .output(let notice) = received[2] else { Issue.record("A refused paste leaves the shell running"); return }
    #expect(notice.contains("too long"))
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
