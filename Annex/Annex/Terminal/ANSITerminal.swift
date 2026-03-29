import Foundation
import SwiftUI

/// A virtual terminal that parses ANSI escape sequences and maintains a screen buffer.
/// Handles CSI sequences for colors (SGR), cursor movement, and erase operations.
@Observable final class ANSITerminal {
    var cols: Int
    var rows: Int

    /// Screen buffer: rows × cols of styled characters
    private(set) var cells: [[Cell]]

    /// Current cursor position (0-indexed)
    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0

    /// Current text style applied to new characters
    private var currentStyle: CellStyle = CellStyle()

    /// Parser state machine
    private var parseState: ParseState = .ground
    private var escBuffer: String = ""

    struct Cell: Equatable {
        var character: Character = " "
        var style: CellStyle = CellStyle()
    }

    struct CellStyle: Equatable {
        var foreground: TermColor = .default
        var background: TermColor = .default
        var bold: Bool = false
        var dim: Bool = false
        var italic: Bool = false
        var underline: Bool = false
        var inverse: Bool = false
        var strikethrough: Bool = false
    }

    enum TermColor: Equatable {
        case `default`
        case standard(UInt8)    // 0-7 standard, 8-15 bright
        case color256(UInt8)    // 0-255
        case rgb(UInt8, UInt8, UInt8)
    }

    private enum ParseState {
        case ground
        case escape       // Got ESC
        case csi          // Got ESC[
        case oscString    // Got ESC] (operating system command)
    }

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        self.cells = Self.makeEmptyBuffer(cols: cols, rows: rows)
    }

    private static func makeEmptyBuffer(cols: Int, rows: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }

    /// Resize the terminal. Preserves existing content where possible.
    func resize(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        var newCells = Self.makeEmptyBuffer(cols: cols, rows: rows)
        let copyRows = min(self.rows, rows)
        let copyCols = min(self.cols, cols)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                newCells[r][c] = cells[r][c]
            }
        }
        self.cols = cols
        self.rows = rows
        self.cells = newCells
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    /// Feed raw PTY data into the terminal.
    func write(_ text: String) {
        // Iterate over unicode scalars to avoid Swift treating \r\n as a single Character
        for scalar in text.unicodeScalars {
            processChar(Character(scalar))
        }
    }

    // MARK: - State Machine

    private func processChar(_ ch: Character) {
        switch parseState {
        case .ground:
            switch ch {
            case "\u{1B}": // ESC
                parseState = .escape
                escBuffer = ""
            case "\r": // Carriage return
                cursorCol = 0
            case "\n": // Line feed
                lineFeed()
            case "\u{08}": // Backspace
                if cursorCol > 0 { cursorCol -= 1 }
            case "\t": // Tab
                cursorCol = min(((cursorCol / 8) + 1) * 8, cols - 1)
            case "\u{07}": // Bell — ignore
                break
            default:
                if ch.asciiValue != nil || !ch.isASCII {
                    putChar(ch)
                }
            }

        case .escape:
            switch ch {
            case "[":
                parseState = .csi
                escBuffer = ""
            case "]":
                parseState = .oscString
                escBuffer = ""
            case "(", ")": // Character set designation — skip next char
                parseState = .ground
            case "M": // Reverse index
                if cursorRow > 0 { cursorRow -= 1 }
                parseState = .ground
            case "7": // Save cursor
                parseState = .ground
            case "8": // Restore cursor
                parseState = .ground
            case "=", ">": // Keypad modes — ignore
                parseState = .ground
            default:
                parseState = .ground
            }

        case .csi:
            if ch.isLetter || ch == "@" || ch == "`" || ch == "~" {
                escBuffer.append(ch)
                processCSI(escBuffer)
                parseState = .ground
                escBuffer = ""
            } else {
                escBuffer.append(ch)
                // Safety: don't let buffer grow unbounded
                if escBuffer.count > 64 {
                    parseState = .ground
                    escBuffer = ""
                }
            }

        case .oscString:
            // OSC terminated by BEL or ST (ESC\)
            if ch == "\u{07}" || ch == "\\" {
                // Ignore OSC content (window title, etc.)
                parseState = .ground
                escBuffer = ""
            } else {
                escBuffer.append(ch)
                if escBuffer.count > 256 {
                    parseState = .ground
                    escBuffer = ""
                }
            }
        }
    }

    // MARK: - CSI Sequence Processing

    private func processCSI(_ seq: String) {
        guard let command = seq.last else { return }
        let paramStr = String(seq.dropLast())

        // Check for private mode prefix (?)
        let isPrivate = paramStr.hasPrefix("?")
        let cleanParams = isPrivate ? String(paramStr.dropFirst()) : paramStr
        let params = cleanParams.split(separator: ";").compactMap { Int($0) }

        switch command {
        case "m": // SGR — Select Graphic Rendition
            processSGR(params.isEmpty ? [0] : params)

        case "A": // Cursor up
            let n = max(params.first ?? 1, 1)
            cursorRow = max(cursorRow - n, 0)

        case "B": // Cursor down
            let n = max(params.first ?? 1, 1)
            cursorRow = min(cursorRow + n, rows - 1)

        case "C": // Cursor forward
            let n = max(params.first ?? 1, 1)
            cursorCol = min(cursorCol + n, cols - 1)

        case "D": // Cursor back
            let n = max(params.first ?? 1, 1)
            cursorCol = max(cursorCol - n, 0)

        case "E": // Cursor next line
            let n = max(params.first ?? 1, 1)
            cursorRow = min(cursorRow + n, rows - 1)
            cursorCol = 0

        case "F": // Cursor previous line
            let n = max(params.first ?? 1, 1)
            cursorRow = max(cursorRow - n, 0)
            cursorCol = 0

        case "G": // Cursor horizontal absolute
            let n = max(params.first ?? 1, 1)
            cursorCol = min(n - 1, cols - 1)

        case "H", "f": // Cursor position
            let row = max((params.count > 0 ? params[0] : 1), 1)
            let col = max((params.count > 1 ? params[1] : 1), 1)
            cursorRow = min(row - 1, rows - 1)
            cursorCol = min(col - 1, cols - 1)

        case "J": // Erase in display
            let mode = params.first ?? 0
            eraseInDisplay(mode)

        case "K": // Erase in line
            let mode = params.first ?? 0
            eraseInLine(mode)

        case "L": // Insert lines
            let n = max(params.first ?? 1, 1)
            for _ in 0..<n {
                if cursorRow < rows - 1 {
                    cells.remove(at: rows - 1)
                    cells.insert(Array(repeating: Cell(), count: cols), at: cursorRow)
                }
            }

        case "M": // Delete lines
            let n = max(params.first ?? 1, 1)
            for _ in 0..<n {
                if cursorRow < rows {
                    cells.remove(at: cursorRow)
                    cells.append(Array(repeating: Cell(), count: cols))
                }
            }

        case "S": // Scroll up
            let n = max(params.first ?? 1, 1)
            scrollUp(n)

        case "T": // Scroll down
            let n = max(params.first ?? 1, 1)
            for _ in 0..<n {
                cells.removeLast()
                cells.insert(Array(repeating: Cell(), count: cols), at: 0)
            }

        case "d": // Cursor vertical absolute
            let n = max(params.first ?? 1, 1)
            cursorRow = min(n - 1, rows - 1)

        case "h", "l": // Set/reset mode — mostly ignore, but handle cursor visibility etc
            break

        case "n": // Device status report — ignore
            break

        case "r": // Set scrolling region — simplified: ignore
            break

        case "s": // Save cursor position
            break

        case "u": // Restore cursor position
            break

        case "X": // Erase characters
            let n = max(params.first ?? 1, 1)
            for i in 0..<n {
                let c = cursorCol + i
                if c < cols {
                    cells[cursorRow][c] = Cell()
                }
            }

        case "@": // Insert characters
            let n = max(params.first ?? 1, 1)
            for _ in 0..<n {
                if cursorCol < cols {
                    cells[cursorRow].insert(Cell(), at: cursorCol)
                    cells[cursorRow].removeLast()
                }
            }

        case "P": // Delete characters
            let n = max(params.first ?? 1, 1)
            for _ in 0..<n {
                if cursorCol < cols {
                    cells[cursorRow].remove(at: cursorCol)
                    cells[cursorRow].append(Cell())
                }
            }

        default:
            break
        }
    }

    // MARK: - SGR (Colors & Styles)

    private func processSGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentStyle = CellStyle()
            case 1:
                currentStyle.bold = true
            case 2:
                currentStyle.dim = true
            case 3:
                currentStyle.italic = true
            case 4:
                currentStyle.underline = true
            case 7:
                currentStyle.inverse = true
            case 9:
                currentStyle.strikethrough = true
            case 22:
                currentStyle.bold = false
                currentStyle.dim = false
            case 23:
                currentStyle.italic = false
            case 24:
                currentStyle.underline = false
            case 27:
                currentStyle.inverse = false
            case 29:
                currentStyle.strikethrough = false
            case 30...37:
                currentStyle.foreground = .standard(UInt8(p - 30))
            case 38:
                // Extended foreground: 38;5;n or 38;2;r;g;b
                if i + 1 < params.count && params[i + 1] == 5 && i + 2 < params.count {
                    currentStyle.foreground = .color256(UInt8(params[i + 2]))
                    i += 2
                } else if i + 1 < params.count && params[i + 1] == 2 && i + 4 < params.count {
                    currentStyle.foreground = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }
            case 39:
                currentStyle.foreground = .default
            case 40...47:
                currentStyle.background = .standard(UInt8(p - 40))
            case 48:
                if i + 1 < params.count && params[i + 1] == 5 && i + 2 < params.count {
                    currentStyle.background = .color256(UInt8(params[i + 2]))
                    i += 2
                } else if i + 1 < params.count && params[i + 1] == 2 && i + 4 < params.count {
                    currentStyle.background = .rgb(
                        UInt8(clamping: params[i + 2]),
                        UInt8(clamping: params[i + 3]),
                        UInt8(clamping: params[i + 4])
                    )
                    i += 4
                }
            case 49:
                currentStyle.background = .default
            case 90...97:
                currentStyle.foreground = .standard(UInt8(p - 90 + 8))
            case 100...107:
                currentStyle.background = .standard(UInt8(p - 100 + 8))
            default:
                break
            }
            i += 1
        }
    }

    // MARK: - Screen Operations

    private func putChar(_ ch: Character) {
        if cursorCol >= cols {
            cursorCol = 0
            lineFeed()
        }
        cells[cursorRow][cursorCol] = Cell(character: ch, style: currentStyle)
        cursorCol += 1
    }

    private func lineFeed() {
        if cursorRow < rows - 1 {
            cursorRow += 1
        } else {
            scrollUp(1)
        }
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<n {
            cells.removeFirst()
            cells.append(Array(repeating: Cell(), count: cols))
        }
    }

    private func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0: // Erase from cursor to end
            eraseInLine(0)
            for r in (cursorRow + 1)..<rows {
                cells[r] = Array(repeating: Cell(), count: cols)
            }
        case 1: // Erase from start to cursor
            for r in 0..<cursorRow {
                cells[r] = Array(repeating: Cell(), count: cols)
            }
            for c in 0...cursorCol {
                cells[cursorRow][c] = Cell()
            }
        case 2, 3: // Erase entire screen
            cells = Self.makeEmptyBuffer(cols: cols, rows: rows)
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: // Erase from cursor to end of line
            for c in cursorCol..<cols {
                cells[cursorRow][c] = Cell()
            }
        case 1: // Erase from start to cursor
            for c in 0...min(cursorCol, cols - 1) {
                cells[cursorRow][c] = Cell()
            }
        case 2: // Erase entire line
            cells[cursorRow] = Array(repeating: Cell(), count: cols)
        default:
            break
        }
    }

    // MARK: - Rendering

    /// Return the visible buffer as plain text (for clipboard copy).
    func plainText() -> String {
        var lastContentRow = -1
        for r in stride(from: rows - 1, through: 0, by: -1) {
            if cells[r].contains(where: { $0.character != " " }) {
                lastContentRow = r
                break
            }
        }
        guard lastContentRow >= 0 else { return "" }

        var lines: [String] = []
        for rowIdx in 0...lastContentRow {
            let row = cells[rowIdx]
            var lastNonSpace = -1
            for c in stride(from: cols - 1, through: 0, by: -1) {
                if row[c].character != " " { lastNonSpace = c; break }
            }
            if lastNonSpace >= 0 {
                lines.append(String(row[0...lastNonSpace].map(\.character)))
            } else {
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Render the visible screen buffer as an AttributedString.
    /// Only renders up to the last row that has content to avoid blank trailing space.
    func render() -> AttributedString {
        // Find the last row with any content
        var lastContentRow = -1
        for r in stride(from: rows - 1, through: 0, by: -1) {
            let hasContent = cells[r].contains { $0.character != " " || $0.style != CellStyle() }
            if hasContent {
                lastContentRow = r
                break
            }
        }

        guard lastContentRow >= 0 else {
            return AttributedString(" ") // empty terminal
        }

        var result = AttributedString()
        for rowIdx in 0...lastContentRow {
            let row = cells[rowIdx]
            // Find last non-space column to trim trailing spaces
            var lastNonSpace = -1
            for c in stride(from: cols - 1, through: 0, by: -1) {
                if row[c].character != " " || row[c].style != CellStyle() {
                    lastNonSpace = c
                    break
                }
            }

            if lastNonSpace >= 0 {
                var runStyle = row[0].style
                var runChars = ""

                for c in 0...lastNonSpace {
                    let cell = row[c]
                    if cell.style != runStyle {
                        if !runChars.isEmpty {
                            result.append(styledString(runChars, style: runStyle))
                        }
                        runChars = String(cell.character)
                        runStyle = cell.style
                    } else {
                        runChars.append(cell.character)
                    }
                }
                if !runChars.isEmpty {
                    result.append(styledString(runChars, style: runStyle))
                }
            }

            if rowIdx < lastContentRow {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private func styledString(_ text: String, style: CellStyle) -> AttributedString {
        var attrStr = AttributedString(text)
        let fg = style.inverse ? resolveColor(style.background, isBackground: true) : resolveColor(style.foreground, isBackground: false)
        let bg = style.inverse ? resolveColor(style.foreground, isBackground: false) : resolveColor(style.background, isBackground: true)

        attrStr.foregroundColor = fg
        if bg != .clear {
            attrStr.backgroundColor = bg
        }
        if style.bold && style.italic {
            attrStr.font = .system(size: 11, weight: .bold, design: .monospaced).italic()
        } else if style.bold {
            attrStr.font = .system(size: 11, weight: .bold, design: .monospaced)
        } else if style.italic {
            attrStr.font = .system(size: 11, design: .monospaced).italic()
        }
        if style.underline {
            attrStr.underlineStyle = .single
        }
        if style.strikethrough {
            attrStr.strikethroughStyle = .single
        }
        if style.dim {
            attrStr.foregroundColor = fg.opacity(0.5)
        }
        return attrStr
    }

    private func resolveColor(_ color: TermColor, isBackground: Bool) -> Color {
        switch color {
        case .default:
            return isBackground ? .clear : Color(white: 0.85)
        case .standard(let n):
            return standardColor(n)
        case .color256(let n):
            return color256(n)
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    private func standardColor(_ n: UInt8) -> Color {
        switch n {
        case 0:  return Color(red: 0.0, green: 0.0, blue: 0.0)       // Black
        case 1:  return Color(red: 0.8, green: 0.2, blue: 0.2)       // Red
        case 2:  return Color(red: 0.2, green: 0.8, blue: 0.2)       // Green
        case 3:  return Color(red: 0.8, green: 0.8, blue: 0.2)       // Yellow
        case 4:  return Color(red: 0.3, green: 0.4, blue: 0.8)       // Blue
        case 5:  return Color(red: 0.8, green: 0.2, blue: 0.8)       // Magenta
        case 6:  return Color(red: 0.2, green: 0.8, blue: 0.8)       // Cyan
        case 7:  return Color(red: 0.75, green: 0.75, blue: 0.75)    // White
        case 8:  return Color(red: 0.5, green: 0.5, blue: 0.5)       // Bright Black
        case 9:  return Color(red: 1.0, green: 0.33, blue: 0.33)     // Bright Red
        case 10: return Color(red: 0.33, green: 1.0, blue: 0.33)     // Bright Green
        case 11: return Color(red: 1.0, green: 1.0, blue: 0.33)      // Bright Yellow
        case 12: return Color(red: 0.45, green: 0.55, blue: 1.0)     // Bright Blue
        case 13: return Color(red: 1.0, green: 0.33, blue: 1.0)      // Bright Magenta
        case 14: return Color(red: 0.33, green: 1.0, blue: 1.0)      // Bright Cyan
        case 15: return Color(red: 1.0, green: 1.0, blue: 1.0)       // Bright White
        default: return Color(white: 0.85)
        }
    }

    private func color256(_ n: UInt8) -> Color {
        if n < 16 {
            return standardColor(n)
        } else if n < 232 {
            // 6×6×6 color cube
            let idx = Int(n) - 16
            let r = idx / 36
            let g = (idx % 36) / 6
            let b = idx % 6
            return Color(
                red: r == 0 ? 0 : (Double(r) * 40 + 55) / 255,
                green: g == 0 ? 0 : (Double(g) * 40 + 55) / 255,
                blue: b == 0 ? 0 : (Double(b) * 40 + 55) / 255
            )
        } else {
            // Grayscale: 232-255 → 8, 18, ..., 238
            let level = Double(Int(n) - 232) * 10 + 8
            return Color(white: level / 255)
        }
    }
}
