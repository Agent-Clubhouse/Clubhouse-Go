import Foundation

/// A VT100/xterm screen for a phone terminal: the visible grid plus scrollback, fed raw PTY output.
/// Rebuilt from the legacy `ANSITerminal` (#117) without UI frameworks, so it can be unit tested. It covers what
/// shells and common full-screen tools use: SGR colors (16, 256 and RGB), cursor movement and save/restore, erase,
/// insert/delete, scroll regions, the alternate screen, deferred wrap, and the modes the keyboard needs
/// (application cursor keys, bracketed paste). Characters are one cell wide.
struct CompanionTerminalScreen: Sendable {
    enum Color: Hashable, Sendable {
        case `default`
        /// 0–7 standard, 8–15 bright, 16–255 the xterm cube and grays.
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    struct Style: Hashable, Sendable {
        var foreground: Color = .default
        var background: Color = .default
        var bold = false, dim = false, italic = false, underline = false, inverse = false, strikethrough = false
    }

    struct Cell: Equatable, Sendable {
        /// One character, with any combining marks that follow it.
        var text: String = " "
        var style = Style()
        var isBlank: Bool { text == " " && style == Style() }
    }

    /// Text that shares one style, for rendering.
    struct Run: Equatable, Sendable {
        var text: String
        var style: Style
        var isCursor = false
    }

    static let scrollbackLimit = 1000

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var grid: [[Cell]]
    private(set) var scrollback: [[Cell]] = []
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    /// The window title from OSC 0 or 2.
    private(set) var title: String?
    /// DECCKM: arrows send `ESC O A` rather than `ESC [ A`.
    private(set) var applicationCursorKeys = false
    /// Paste is wrapped in `ESC [200~` … `ESC [201~` when the program asked for it.
    private(set) var bracketedPaste = false
    private(set) var cursorVisible = true
    private(set) var isAlternateScreen = false
    /// Answers the program asked for (cursor position, device attributes), to send back as input.
    private(set) var replies: [String] = []

    private var style = Style()
    private var pendingWrap = false
    private var autowrap = true
    private var scrollTop = 0
    private var scrollBottom: Int
    private var saved: (row: Int, col: Int, style: Style)?
    private var primary: (grid: [[Cell]], row: Int, col: Int)?
    private var lastPrinted: String?
    private var state = ParseState.ground

    private enum ParseState: Sendable {
        case ground, escape, charset
        case csi(String)
        /// OSC, DCS, APC and PM strings run to BEL or ST; only OSC titles are kept.
        case string(String, isOSC: Bool)
        case stringEscape(String, isOSC: Bool)
    }

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(1, cols); self.rows = max(1, rows)
        grid = Self.blankGrid(cols: self.cols, rows: self.rows)
        scrollBottom = self.rows - 1
    }

    private static func blankGrid(cols: Int, rows: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }
    /// Erased cells keep the current background, as xterm does.
    private var blank: Cell { Cell(text: " ", style: Style(background: style.background)) }
    private var blankRow: [Cell] { Array(repeating: blank, count: cols) }

    mutating func takeReplies() -> [String] { defer { replies = [] }; return replies }

    // MARK: Size

    /// Rows that no longer fit go to scrollback, so the cursor's line stays on screen. Lines are not reflowed.
    mutating func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(1, newCols), newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }
        func fit(_ row: [Cell]) -> [Cell] {
            row.count >= newCols ? Array(row.prefix(newCols)) : row + Array(repeating: Cell(), count: newCols - row.count)
        }
        if cursorRow >= newRows {
            let overflow = cursorRow - newRows + 1
            if !isAlternateScreen { pushScrollback(grid.prefix(overflow)) }
            grid.removeFirst(overflow)
            cursorRow -= overflow
        }
        if grid.count > newRows { grid.removeLast(grid.count - newRows) }
        while grid.count < newRows { grid.append(Array(repeating: Cell(), count: newCols)) }
        grid = grid.map(fit)
        if var primary {
            primary.grid = Array(primary.grid.prefix(newRows)).map(fit)
            while primary.grid.count < newRows { primary.grid.append(Array(repeating: Cell(), count: newCols)) }
            primary.row = min(primary.row, newRows - 1); primary.col = min(primary.col, newCols - 1)
            self.primary = primary
        }
        cols = newCols; rows = newRows
        cursorRow = min(cursorRow, rows - 1); cursorCol = min(cursorCol, cols - 1)
        scrollTop = 0; scrollBottom = rows - 1
        pendingWrap = false
    }

    // MARK: Input

    mutating func feed(_ text: String) {
        for scalar in text.unicodeScalars { process(scalar) }
    }

    private mutating func process(_ scalar: Unicode.Scalar) {
        switch state {
        case .ground: ground(scalar)
        case .escape: escape(scalar)
        case .charset: state = .ground
        case .csi(let buffer):
            switch scalar.value {
            case 0x1B: state = .escape
            case 0x18, 0x1A: state = .ground
            case 0x40...0x7E: state = .ground; csi(buffer, final: Character(scalar))
            case 0x20...0x3F:
                // A runaway sequence is dropped rather than buffered forever.
                state = buffer.count > 64 ? .ground : .csi(buffer + String(Character(scalar)))
            default: ground(scalar, controlsOnly: true)
            }
        case .string(let buffer, let isOSC):
            switch scalar.value {
            case 0x07: finishString(buffer, isOSC: isOSC)
            case 0x1B: state = .stringEscape(buffer, isOSC: isOSC)
            case 0x18, 0x1A: state = .ground
            default: state = .string(buffer.count > 512 ? buffer : buffer + String(Character(scalar)), isOSC: isOSC)
            }
        case .stringEscape(let buffer, let isOSC):
            if scalar == "\\" { finishString(buffer, isOSC: isOSC) } else { state = .ground; process(scalar) }
        }
    }

    private mutating func ground(_ scalar: Unicode.Scalar, controlsOnly: Bool = false) {
        switch scalar.value {
        case 0x1B: state = .escape
        case 0x0D: cursorCol = 0; pendingWrap = false
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x08: if cursorCol > 0 { cursorCol -= 1 }; pendingWrap = false
        case 0x09: cursorCol = min((cursorCol / 8 + 1) * 8, cols - 1); pendingWrap = false
        case 0x00...0x1F, 0x7F: break
        case 0x80...0x9F: break
        default: if !controlsOnly { printScalar(scalar) }
        }
    }

    private mutating func escape(_ scalar: Unicode.Scalar) {
        state = .ground
        switch scalar {
        case "[": state = .csi("")
        case "]": state = .string("", isOSC: true)
        case "P", "_", "^", "X": state = .string("", isOSC: false)
        case "(", ")", "*", "+", "-", ".", "/", "#", "%": state = .charset
        case "7": saveCursor()
        case "8": restoreCursor()
        case "D": lineFeed()
        case "E": cursorCol = 0; lineFeed()
        case "M": reverseIndex()
        case "c": reset()
        default: break
        }
    }

    private mutating func finishString(_ buffer: String, isOSC: Bool) {
        state = .ground
        guard isOSC else { return }
        let parts = buffer.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[0] == "0" || parts[0] == "2" { title = String(parts[1]) }
    }

    // MARK: Printing

    private mutating func printScalar(_ scalar: Unicode.Scalar) {
        // Combining marks, variation selectors and joiners belong to the character before them.
        if Self.isCombining(scalar) {
            let col = pendingWrap ? cursorCol : cursorCol - 1
            if col >= 0 { grid[cursorRow][col].text.unicodeScalars.append(scalar) }
            return
        }
        if pendingWrap {
            pendingWrap = false
            if autowrap { cursorCol = 0; lineFeed() }
        }
        let text = String(Character(scalar))
        grid[cursorRow][cursorCol] = Cell(text: text, style: style)
        lastPrinted = text
        if cursorCol == cols - 1 { pendingWrap = true } else { cursorCol += 1 }
    }

    private static func isCombining(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: return true
        default: return scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value)
        }
    }

    // MARK: Lines and scrolling

    private mutating func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom { scrollUp(1) }
        else if cursorRow < rows - 1 { cursorRow += 1 }
    }

    private mutating func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop { scrollDown(1) }
        else if cursorRow > 0 { cursorRow -= 1 }
    }

    private mutating func scrollUp(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        let removed = grid[scrollTop..<(scrollTop + count)]
        if scrollTop == 0 && !isAlternateScreen { pushScrollback(removed) }
        grid.removeSubrange(scrollTop..<(scrollTop + count))
        grid.insert(contentsOf: Array(repeating: blankRow, count: count), at: scrollBottom - count + 1)
    }

    private mutating func scrollDown(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        grid.removeSubrange((scrollBottom - count + 1)...scrollBottom)
        grid.insert(contentsOf: Array(repeating: blankRow, count: count), at: scrollTop)
    }

    private mutating func pushScrollback<S: Sequence>(_ lines: S) where S.Element == [Cell] {
        scrollback.append(contentsOf: lines)
        if scrollback.count > Self.scrollbackLimit { scrollback.removeFirst(scrollback.count - Self.scrollbackLimit) }
    }

    // MARK: Control sequences

    private mutating func csi(_ buffer: String, final: Character) {
        let marker = buffer.first.flatMap { "?<=>".contains($0) ? $0 : nil }
        let body = marker == nil ? buffer : String(buffer.dropFirst())
        // Intermediates (such as the space in `CSI 2 SP q`) select variants this screen doesn't draw.
        guard !body.contains(where: { $0.unicodeScalars.first.map { (0x20...0x2F).contains($0.value) } ?? false }) else { return }
        let params = body.split(separator: ";", omittingEmptySubsequences: false).map { Int($0.split(separator: ":").first ?? "") }
        func param(_ index: Int, _ fallback: Int = 1) -> Int {
            guard index < params.count, let value = params[index], value > 0 else { return fallback }
            return value
        }
        if marker == "?" {
            if final == "h" || final == "l" { setPrivateModes(params.compactMap { $0 }, on: final == "h") }
            return
        }
        guard marker == nil else { return }
        if final != "m" { pendingWrap = false }
        switch final {
        case "m": sgr(params.map { $0 ?? 0 })
        case "A": cursorRow = max(cursorRow - param(0), cursorRow >= scrollTop ? scrollTop : 0)
        case "B", "e": cursorRow = min(cursorRow + param(0), cursorRow <= scrollBottom ? scrollBottom : rows - 1)
        case "C", "a": cursorCol = min(cursorCol + param(0), cols - 1)
        case "D": cursorCol = max(cursorCol - param(0), 0)
        case "E": cursorRow = min(cursorRow + param(0), rows - 1); cursorCol = 0
        case "F": cursorRow = max(cursorRow - param(0), 0); cursorCol = 0
        case "G", "`": cursorCol = min(param(0) - 1, cols - 1)
        case "d": cursorRow = min(param(0) - 1, rows - 1)
        case "H", "f": cursorRow = min(param(0) - 1, rows - 1); cursorCol = min(param(1) - 1, cols - 1)
        case "J": eraseDisplay(param(0, 0))
        case "K": eraseLine(param(0, 0))
        case "L": if (scrollTop...scrollBottom).contains(cursorRow) { insertLines(param(0)) }
        case "M": if (scrollTop...scrollBottom).contains(cursorRow) { deleteLines(param(0)) }
        case "@":
            let count = min(param(0), cols - cursorCol)
            grid[cursorRow].insert(contentsOf: Array(repeating: blank, count: count), at: cursorCol)
            grid[cursorRow].removeLast(count)
        case "P":
            let count = min(param(0), cols - cursorCol)
            grid[cursorRow].removeSubrange(cursorCol..<(cursorCol + count))
            grid[cursorRow].append(contentsOf: Array(repeating: blank, count: count))
        case "X":
            for col in cursorCol..<min(cols, cursorCol + param(0)) { grid[cursorRow][col] = blank }
        case "S": scrollUp(param(0))
        case "T": scrollDown(param(0))
        case "b": if let lastPrinted { for _ in 0..<min(param(0), cols * rows) { feed(lastPrinted) } }
        case "r":
            let top = param(0) - 1, bottom = min(param(1, rows), rows) - 1
            guard top < bottom else { return }
            scrollTop = top; scrollBottom = bottom
            cursorRow = 0; cursorCol = 0
        case "s": saveCursor()
        case "u": restoreCursor()
        case "n":
            if param(0, 0) == 5 { replies.append("\u{1B}[0n") }
            if param(0, 0) == 6 { replies.append("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R") }
        case "c": if param(0, 0) == 0 { replies.append("\u{1B}[?1;2c") }
        default: break
        }
    }

    private mutating func setPrivateModes(_ modes: [Int], on: Bool) {
        for mode in modes {
            switch mode {
            case 1: applicationCursorKeys = on
            case 7: autowrap = on
            case 25: cursorVisible = on
            case 2004: bracketedPaste = on
            case 47, 1047: setAlternateScreen(on, saveCursor: false)
            case 1049: setAlternateScreen(on, saveCursor: true)
            default: break
            }
        }
    }

    private mutating func setAlternateScreen(_ on: Bool, saveCursor: Bool) {
        guard on != isAlternateScreen else { return }
        if on {
            primary = (grid, cursorRow, cursorCol)
            grid = Self.blankGrid(cols: cols, rows: rows)
            if !saveCursor { cursorRow = 0; cursorCol = 0 }
        } else if let primary {
            grid = primary.grid
            if saveCursor { cursorRow = primary.row; cursorCol = primary.col }
            self.primary = nil
        }
        isAlternateScreen = on
        scrollTop = 0; scrollBottom = rows - 1
        pendingWrap = false
    }

    private mutating func sgr(_ params: [Int]) {
        let params = params.isEmpty ? [0] : params
        var index = 0
        func extended() -> Color? {
            guard index + 1 < params.count else { return nil }
            if params[index + 1] == 5, index + 2 < params.count {
                defer { index += 2 }
                return .indexed(UInt8(clamping: params[index + 2]))
            }
            if params[index + 1] == 2, index + 4 < params.count {
                defer { index += 4 }
                return .rgb(UInt8(clamping: params[index + 2]), UInt8(clamping: params[index + 3]), UInt8(clamping: params[index + 4]))
            }
            return nil
        }
        while index < params.count {
            let value = params[index]
            switch value {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 21, 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(UInt8(value - 30))
            case 38: if let color = extended() { style.foreground = color }
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(UInt8(value - 40))
            case 48: if let color = extended() { style.background = color }
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(UInt8(value - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(value - 100 + 8))
            default: break
            }
            index += 1
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for row in (cursorRow + 1)..<rows { grid[row] = blankRow }
        case 1:
            for row in 0..<cursorRow { grid[row] = blankRow }
            eraseLine(1)
        case 2: grid = Array(repeating: blankRow, count: rows)
        case 3: scrollback = []
        default: break
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 0: for col in cursorCol..<cols { grid[cursorRow][col] = blank }
        case 1: for col in 0...min(cursorCol, cols - 1) { grid[cursorRow][col] = blank }
        case 2: grid[cursorRow] = blankRow
        default: break
        }
    }

    private mutating func insertLines(_ count: Int) {
        let count = min(count, scrollBottom - cursorRow + 1)
        grid.removeSubrange((scrollBottom - count + 1)...scrollBottom)
        grid.insert(contentsOf: Array(repeating: blankRow, count: count), at: cursorRow)
        cursorCol = 0
    }

    private mutating func deleteLines(_ count: Int) {
        let count = min(count, scrollBottom - cursorRow + 1)
        grid.removeSubrange(cursorRow..<(cursorRow + count))
        grid.insert(contentsOf: Array(repeating: blankRow, count: count), at: scrollBottom - count + 1)
        cursorCol = 0
    }

    private mutating func saveCursor() { saved = (cursorRow, cursorCol, style) }
    private mutating func restoreCursor() {
        guard let saved else { cursorRow = 0; cursorCol = 0; return }
        cursorRow = min(saved.row, rows - 1); cursorCol = min(saved.col, cols - 1); style = saved.style
        pendingWrap = false
    }

    /// RIS: a fresh screen, keeping the size and scrollback.
    private mutating func reset() {
        let history = scrollback
        self = CompanionTerminalScreen(cols: cols, rows: rows)
        scrollback = history
    }

    // MARK: Output

    /// Scrollback then the screen, with trailing blanks trimmed and the empty rows below the cursor dropped.
    /// The cursor cell is marked when it's visible.
    func renderedLines(showCursor: Bool = true) -> [[Run]] {
        let lastScreenRow = max(cursorRow, grid.lastIndex { $0.contains { !$0.isBlank } } ?? 0)
        let lines = scrollback + grid.prefix(lastScreenRow + 1)
        let cursorLine = scrollback.count + cursorRow
        return lines.enumerated().map { index, row in
            let cursor = showCursor && cursorVisible && index == cursorLine ? cursorCol : nil
            return Self.runs(row, cursor: cursor)
        }
    }

    private static func runs(_ row: [Cell], cursor: Int?) -> [Run] {
        let lastContent = row.lastIndex { !$0.isBlank } ?? -1
        let end = max(lastContent, cursor ?? -1)
        guard end >= 0 else { return [] }
        var runs: [Run] = []
        for (col, cell) in row.prefix(end + 1).enumerated() {
            let isCursor = col == cursor
            if !isCursor, let last = runs.last, !last.isCursor, last.style == cell.style {
                runs[runs.count - 1].text += cell.text
            } else {
                runs.append(Run(text: cell.text, style: cell.style, isCursor: isCursor))
            }
        }
        return runs
    }

    /// Everything on screen and in scrollback as plain text, for Copy all.
    func plainText() -> String {
        var lines = renderedLines(showCursor: false).map { $0.map(\.text).joined() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
