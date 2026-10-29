import Foundation

/// The preview desktop's terminals: a fake shell that echoes what's typed and answers a few commands, and a
/// terminal-mode agent's screen. Nothing reaches a desktop.
@MainActor final class CompanionPreviewTerminalChannel: CompanionTerminalChannel {
    let scope: CompanionTerminalScope
    private var continuation: AsyncStream<CompanionTerminalChannelEvent>.Continuation?
    private var line = ""
    private var isOpen = false
    private(set) var size: (cols: Int, rows: Int)?

    init(scope: CompanionTerminalScope) { self.scope = scope }

    var cwd: String {
        switch scope {
        case .project(let project): "/Users/river/\(project.projectID)"
        case .agentShell(let target), .agentPTY(let target): "/Users/river/\(target.projectID)/.clubhouse/agents/\(target.agentID)"
        }
    }

    func events() -> AsyncStream<CompanionTerminalChannelEvent> {
        let (stream, continuation) = AsyncStream<CompanionTerminalChannelEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func open(cols: Int, rows: Int) async {
        isOpen = true
        line = ""
        if case .agentPTY = scope {
            continuation?.yield(.opened(cwd: nil, snapshot: Self.agentScreen, cols: 80, rows: 24))
        } else {
            size = (cols, rows)
            continuation?.yield(.opened(cwd: cwd, snapshot: nil, cols: nil, rows: nil))
            continuation?.yield(.output("Preview shell · nothing runs on a desktop\r\n" + prompt))
        }
    }

    func send(_ input: String) async throws {
        guard isOpen else { throw CompanionServiceError.unavailable("Preview only") }
        // Paste brackets and keys such as arrows aren't the shell's to echo.
        let text = input.replacingOccurrences(of: "\u{1B}[200~", with: "").replacingOccurrences(of: "\u{1B}[201~", with: "")
        guard !text.hasPrefix("\u{1B}") else { return }
        var output = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                output += "\r\n" + run(line)
                line = ""
                guard isOpen else { continuation?.yield(.output(output)); continuation?.yield(.exited(code: 0)); return }
                output += prompt
            case "\u{7F}", "\u{08}":
                if !line.isEmpty { line.removeLast(); output += "\u{08} \u{08}" }
            case "\u{03}":
                line = ""
                output += "^C\r\n" + prompt
            case "\t": break
            default:
                guard scalar.value >= 0x20 else { continue }
                line.unicodeScalars.append(scalar)
                output.unicodeScalars.append(scalar)
            }
        }
        if !output.isEmpty { continuation?.yield(.output(output)) }
    }

    func resize(cols: Int, rows: Int) async { size = (cols, rows) }

    func close() async {
        isOpen = false
        continuation?.finish(); continuation = nil
    }

    private var prompt: String {
        "\u{1B}[32mriver@studio\u{1B}[0m \u{1B}[34m\((cwd as NSString).lastPathComponent)\u{1B}[0m % "
    }

    private func run(_ command: String) -> String {
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let name = words.first else { return "" }
        let rest = words.dropFirst().joined(separator: " ")
        switch name {
        case "echo": return rest + "\r\n"
        case "pwd": return cwd + "\r\n"
        case "whoami": return "river\r\n"
        // The size the phone last sent, so a UI test can see the terminal follow rotation.
        case "stty": return size.map { "\($0.rows) \($0.cols)\r\n" } ?? "24 80\r\n"
        case "ls": return "\u{1B}[1;34mSources\u{1B}[0m  \u{1B}[1;34mTests\u{1B}[0m  Package.swift  README.md\r\n"
        case "clear": return "\u{1B}[2J\u{1B}[H"
        case "colors":
            return (0..<8).map { "\u{1B}[3\($0)m■\u{1B}[0m" }.joined(separator: " ") + "\r\n"
                + (0..<8).map { "\u{1B}[9\($0)m■\u{1B}[0m" }.joined(separator: " ") + "\r\n"
        case "exit":
            isOpen = false
            return "logout\r\n"
        default: return "zsh: command not found: \(name)\r\n"
        }
    }

    /// A terminal-mode agent mid-task, as its PTY snapshot would show it.
    static let agentScreen = [
        "\u{1B}[1;35m✻\u{1B}[0m \u{1B}[1mWelcome to Claude Code\u{1B}[0m",
        "",
        "\u{1B}[2m>\u{1B}[0m Tidy the release checklist and open a PR",
        "",
        "\u{1B}[32m⏺\u{1B}[0m Reading \u{1B}[1mdocs/RELEASING.md\u{1B}[0m",
        "\u{1B}[32m⏺\u{1B}[0m Updated 3 steps; running the checks now",
        "",
        "\u{1B}[2m  ⎿  swift test · 412 passed\u{1B}[0m",
        "",
        "\u{1B}[36m╭──────────────────────────────────────────╮\u{1B}[0m",
        "\u{1B}[36m│\u{1B}[0m > ",
    ].joined(separator: "\r\n")
}
