import Foundation
import Observation

/// Where a terminal opens, matching the desktop's Terminal scope: a project's root, an agent's worktree (or a quick
/// agent's working folder), or a terminal-mode agent's own PTY.
enum CompanionTerminalScope: Hashable, Identifiable, Sendable {
    case project(CompanionProjectTarget)
    case agentShell(CompanionTarget)
    case agentPTY(CompanionTarget)
    var id: Self { self }
    var hostID: String {
        switch self {
        case .project(let project): project.hostID
        case .agentShell(let target), .agentPTY(let target): target.hostID
        }
    }
    var projectID: String {
        switch self {
        case .project(let project): project.projectID
        case .agentShell(let target), .agentPTY(let target): target.projectID
        }
    }
    var agent: CompanionTarget? {
        switch self {
        case .project: nil
        case .agentShell(let target), .agentPTY(let target): target
        }
    }
    /// A shell is the phone's own and follows its size. An agent's PTY is shared with the desktop, so the phone
    /// shows it at the desktop's size rather than reflowing the desktop's view.
    var resizesPTY: Bool { if case .agentPTY = self { false } else { true } }
}

/// The desktop's `terminal` capability (v1). Nil on a host: no terminals, and every entry point is hidden.
struct CompanionTerminalSupport: Equatable, Sendable {
    var projectShell: Bool
    var agentShell: Bool
    var agentAttach: Bool

    func allows(_ scope: CompanionTerminalScope) -> Bool {
        switch scope {
        case .project: projectShell
        case .agentShell: agentShell
        case .agentPTY: agentAttach
        }
    }
}

/// Whether an entry point shows, and whether it can be used now.
enum CompanionTerminalAvailability: Equatable, Sendable {
    /// The desktop doesn't offer it, or the agent or project is gone.
    case hidden
    /// Shown but disabled, with the reason.
    case unavailable(String)
    case available

    static let updateDesktop = "Update Clubhouse on your desktop to open terminals from your phone."
    var isShown: Bool { self != .hidden }
    var isAvailable: Bool { self == .available }

    /// Entry points show only when the desktop advertises the capability, and work only while it's connected.
    static func of(_ scope: CompanionTerminalScope, host: CompanionHost?) -> Self {
        guard let host, let support = host.terminal, support.allows(scope),
              let project = host.projects.first(where: { $0.id == scope.projectID }) else { return .hidden }
        if let target = scope.agent {
            guard let agent = project.agents.first(where: { $0.id == target }) else { return .hidden }
            if case .agentPTY = scope {
                // Chat and headless agents have no PTY to attach to.
                guard agent.executionMode == "pty" else { return .hidden }
                if !agent.isRunning { return .unavailable("\(agent.name) isn't running. Start it on your desktop to see its terminal.") }
            }
        }
        return host.connection.canOperate ? .available : .unavailable("Reconnect to \(host.name) to open a terminal.")
    }
}

extension CompanionAgent {
    /// Its process is up, so its PTY can be attached.
    var isRunning: Bool {
        switch status {
        case .sleeping, .stopped, .completed, .failed: false
        default: !hasExited
        }
    }
}

// MARK: Colors

/// The desktop theme's `terminalColors` (Clubhouse `TerminalColors`), with a set derived from the app theme for
/// desktops and themes that don't send one, and for any color missing from it.
struct CompanionTerminalColors: Equatable, Sendable {
    var background: CompanionRGB
    var foreground: CompanionRGB
    var cursor: CompanionRGB
    var selection: CompanionRGB
    /// black, red, green, yellow, blue, magenta, cyan, white, then their bright forms.
    var ansi: [CompanionRGB]

    static let ansiKeys = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                           "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]
    /// xterm's defaults, for colors a theme leaves out.
    private static let xterm = ["#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
                                "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff"].compactMap { CompanionRGB(hex: $0) }

    init(background: CompanionRGB, foreground: CompanionRGB, cursor: CompanionRGB, selection: CompanionRGB, ansi: [CompanionRGB]) {
        self.background = background; self.foreground = foreground; self.cursor = cursor; self.selection = selection
        self.ansi = ansi.count == 16 ? ansi : Self.xterm
    }

    /// The desktop's colors, completed from `theme` where they're missing or unreadable.
    init(colors: [String: String], theme: CompanionDesktopTheme) {
        let fallback = Self.derived(from: theme)
        func color(_ key: String, _ otherwise: CompanionRGB) -> CompanionRGB { colors[key].flatMap { CompanionRGB(hex: $0) } ?? otherwise }
        self.init(background: color("background", fallback.background), foreground: color("foreground", fallback.foreground),
                  cursor: color("cursor", fallback.cursor), selection: color("selectionBackground", fallback.selection),
                  ansi: Self.ansiKeys.enumerated().map { color($1, fallback.ansi[$0]) })
    }

    /// The app theme's grounds and text, with xterm's palette.
    static func derived(from theme: CompanionDesktopTheme) -> CompanionTerminalColors {
        .init(background: theme.base, foreground: theme.text, cursor: theme.accent,
              selection: theme.accent.mixed(with: theme.base, amount: 0.6), ansi: xterm)
    }

    /// A cell color as RGB. Nil is the default, which draws in `foreground` or on `background`.
    func rgb(_ color: CompanionTerminalScreen.Color) -> CompanionRGB? {
        switch color {
        case .default: return nil
        case .rgb(let r, let g, let b): return CompanionRGB(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .indexed(let index) where index < 16: return ansi[Int(index)]
        case .indexed(let index) where index < 232:
            // The 6×6×6 cube.
            let value = Int(index) - 16
            func level(_ step: Int) -> Double { step == 0 ? 0 : Double(step * 40 + 55) / 255 }
            return CompanionRGB(red: level(value / 36), green: level(value / 6 % 6), blue: level(value % 6))
        case .indexed(let index):
            let gray = Double((Int(index) - 232) * 10 + 8) / 255
            return CompanionRGB(red: gray, green: gray, blue: gray)
        }
    }

    /// A cell's drawn colors, after inverse.
    func colors(for style: CompanionTerminalScreen.Style) -> (foreground: CompanionRGB, background: CompanionRGB?) {
        let foreground = rgb(style.foreground) ?? self.foreground
        let background = rgb(style.background)
        if style.inverse { return (background ?? self.background, foreground) }
        return (style.dim ? foreground.mixed(with: self.background, amount: 0.4) : foreground, background)
    }
}

// MARK: Keys

/// The keys on the terminal's accessory bar, and what each sends.
enum CompanionTerminalKey: String, CaseIterable, Identifiable, Sendable {
    case escape, tab, up, down, left, right, home, end, pageUp, pageDown, interrupt, enter, backspace
    var id: String { rawValue }

    func sequence(applicationCursorKeys: Bool) -> String {
        let csi = "\u{1B}[", ss3 = "\u{1B}O"
        switch self {
        case .escape: return "\u{1B}"
        case .tab: return "\t"
        case .up: return (applicationCursorKeys ? ss3 : csi) + "A"
        case .down: return (applicationCursorKeys ? ss3 : csi) + "B"
        case .right: return (applicationCursorKeys ? ss3 : csi) + "C"
        case .left: return (applicationCursorKeys ? ss3 : csi) + "D"
        case .home: return (applicationCursorKeys ? ss3 : csi) + "H"
        case .end: return (applicationCursorKeys ? ss3 : csi) + "F"
        case .pageUp: return csi + "5~"
        case .pageDown: return csi + "6~"
        case .interrupt: return "\u{03}"
        case .enter: return "\r"
        case .backspace: return "\u{7F}"
        }
    }
}

enum CompanionTerminalInput {
    /// Ctrl with a typed character: letters and `@[\]^_` become their control codes, `?` is DEL, and space is NUL.
    /// Anything else is sent as typed.
    static func control(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return text }
        switch scalar {
        case "a"..."z": return String(UnicodeScalar(UInt8(scalar.value - 96)))
        case "A"..."Z": return String(UnicodeScalar(UInt8(scalar.value - 64)))
        case "@", "[", "\\", "]", "^", "_": return String(UnicodeScalar(UInt8(scalar.value - 64)))
        case " ", "2": return "\u{00}"
        case "?": return "\u{7F}"
        default: return text
        }
    }

    /// Typed text as a terminal sends it: Return is a carriage return.
    static func typed(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
    }

    /// Pasted text. Line ends become carriage returns; when the program asked for bracketed paste it's wrapped, and
    /// escape characters are removed so the paste can't end the bracket early and run as keystrokes.
    static func paste(_ text: String, bracketed: Bool) -> String {
        let lines = typed(text)
        guard bracketed else { return lines }
        return "\u{1B}[200~" + lines.replacingOccurrences(of: "\u{1B}", with: "") + "\u{1B}[201~"
    }
}

// MARK: Session

/// What a terminal's channel reports. `opened` with a snapshot replaces the screen (an agent's PTY).
enum CompanionTerminalChannelEvent: Equatable, Sendable {
    case opened(cwd: String?, snapshot: String?, cols: Int?, rows: Int?)
    case output(String)
    case exited(code: Int?)
    case failed(String)
    /// The desktop connection dropped. The desktop kills the phone's shells when it does.
    case connectionLost
    /// It's back: the session opens again (a new shell, or a fresh snapshot).
    case connectionRestored
}

/// One terminal on one desktop: the live connection's `pty:*` messages, or the preview's fake shell.
@MainActor protocol CompanionTerminalChannel: AnyObject {
    func events() -> AsyncStream<CompanionTerminalChannelEvent>
    /// Spawns the shell or attaches to the agent's PTY. The result arrives as an event.
    func open(cols: Int, rows: Int) async
    func send(_ input: String) async throws
    /// Shells only; an agent's PTY keeps the desktop's size.
    func resize(cols: Int, rows: Int) async
    func close() async
}

/// A full-screen terminal's state: its screen, and its connection to the desktop's PTY.
@MainActor @Observable final class CompanionTerminalSession {
    enum State: Equatable, Sendable {
        case connecting, running, reconnecting
        case exited(code: Int?)
        case failed(String)
        case closed
        var isLive: Bool { self == .running }
    }

    let scope: CompanionTerminalScope
    let title: String
    private(set) var state: State = .connecting
    private(set) var screen: CompanionTerminalScreen
    /// Bumped on every screen change, for views that redraw.
    private(set) var revision = 0
    /// The shell's working directory from the desktop.
    private(set) var cwd: String?
    /// The next typed character is sent with Ctrl, from the accessory bar's Ctrl key.
    var controlArmed = false
    @ObservationIgnored private let channel: any CompanionTerminalChannel
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var outbox: [String] = []
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var hasOpened = false

    init(scope: CompanionTerminalScope, title: String, channel: any CompanionTerminalChannel, cols: Int = 80, rows: Int = 24) {
        self.scope = scope; self.title = title; self.channel = channel
        screen = CompanionTerminalScreen(cols: cols, rows: rows)
    }

    /// The project's name for its shell, and the agent's name for its own.
    static func title(for scope: CompanionTerminalScope, host: CompanionHost?) -> String {
        let project = host?.projects.first { $0.id == scope.projectID }
        guard let target = scope.agent else { return project?.name ?? "Terminal" }
        return project?.agents.first { $0.id == target }?.name ?? "Terminal"
    }

    func start() {
        guard listening == nil else { return }
        let events = channel.events()
        listening = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
        open()
    }

    private func open() {
        state = hasOpened ? .reconnecting : .connecting
        let cols = screen.cols, rows = screen.rows
        Task { await channel.open(cols: cols, rows: rows) }
    }

    /// After an exit or failure: a new shell, or the agent's terminal again.
    func restart() {
        guard state != .closed, !state.isLive else { return }
        open()
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        listening?.cancel(); listening = nil
        outbox = []
        Task { await channel.close() }
    }

    func apply(_ event: CompanionTerminalChannelEvent) {
        guard state != .closed else { return }
        switch event {
        case .opened(let cwd, let snapshot, let cols, let rows):
            if let cwd { self.cwd = cwd }
            if let snapshot {
                screen = CompanionTerminalScreen(cols: cols ?? screen.cols, rows: rows ?? screen.rows)
                screen.feed(snapshot)
            } else if hasOpened, scope.resizesPTY {
                // The desktop killed the old shell when the connection dropped.
                notice("Reconnected. This is a new shell.")
            }
            hasOpened = true
            state = .running
            changed()
            // The shell started at the size `open` sent; the view may have measured since.
            if scope.resizesPTY {
                let cols = screen.cols, rows = screen.rows
                Task { await channel.resize(cols: cols, rows: rows) }
            }
        case .output(let text):
            screen.feed(text)
            for reply in screen.takeReplies() { enqueue(reply) }
            changed()
        case .exited(let code):
            state = .exited(code: code)
            notice(code.map { "Process exited with code \($0)." } ?? "Process exited.")
        case .failed(let message):
            state = .failed(message)
        case .connectionLost:
            if state == .running || state == .connecting { state = .reconnecting }
        case .connectionRestored:
            if state == .reconnecting { open() }
        }
    }

    private func notice(_ text: String) {
        screen.feed("\r\n\u{1B}[2m[\(text)]\u{1B}[0m\r\n")
        changed()
    }

    private func changed() { revision &+= 1 }

    // MARK: Input

    /// Text from the keyboard. With Ctrl armed, its first character is sent as a control code.
    func type(_ text: String) {
        guard !text.isEmpty else { return }
        if controlArmed {
            controlArmed = false
            let first = String(text.prefix(1))
            enqueue(CompanionTerminalInput.control(first) + CompanionTerminalInput.typed(String(text.dropFirst())))
        } else {
            enqueue(CompanionTerminalInput.typed(text))
        }
    }

    func press(_ key: CompanionTerminalKey) {
        controlArmed = false
        enqueue(key.sequence(applicationCursorKeys: screen.applicationCursorKeys))
    }

    func paste(_ text: String) {
        guard !text.isEmpty else { return }
        enqueue(CompanionTerminalInput.paste(text, bracketed: screen.bracketedPaste))
    }

    /// Input goes out in order, one message at a time. Keys pressed while the shell is away are dropped, as a
    /// disconnected terminal would.
    private func enqueue(_ input: String) {
        guard state.isLive else { return }
        outbox.append(input)
        guard !flushing else { return }
        flushing = true
        Task {
            while !outbox.isEmpty, state.isLive {
                let next = outbox.removeFirst()
                do { try await channel.send(next) }
                catch { outbox = []; if state.isLive { state = .reconnecting }; break }
            }
            outbox = []
            flushing = false
        }
    }

    /// The phone's size in cells. A shell follows it; an agent's PTY keeps the desktop's size.
    func resize(cols: Int, rows: Int) {
        guard scope.resizesPTY, cols > 0, rows > 0, cols != screen.cols || rows != screen.rows else { return }
        screen.resize(cols: cols, rows: rows)
        changed()
        guard state.isLive else { return }
        Task { await channel.resize(cols: cols, rows: rows) }
    }
}
