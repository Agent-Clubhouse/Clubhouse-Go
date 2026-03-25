import SwiftUI

struct LiveTerminalView: View {
    let agentId: String
    @Environment(AppStore.self) private var store
    @State private var terminal = ANSITerminal(cols: 80, rows: 200)
    @State private var lastProcessedLength = 0
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    /// Calculate terminal columns from screen width
    private var terminalCols: Int {
        let screenWidth = UIScreen.main.bounds.width - 16 // padding
        let charWidth: CGFloat = 6.7 // approximate monospace char width at size 11
        return max(Int(screenWidth / charWidth), 40)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminal.render())
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .id("bottom")
                }
                .onChange(of: store.ptyBuffer(for: agentId)) { oldValue, newValue in
                    if oldValue.count != newValue.count {
                        AppLog.shared.debug("Terminal", "[\(agentId.suffix(6))] onChange fired: \(oldValue.count) -> \(newValue.count)")
                        processNewPtyData()
                        withAnimation {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    setupTerminal()
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            // Input bar
            HStack(spacing: 8) {
                TextField("Type command...", text: $inputText)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .onSubmit {
                        sendInput(inputText + "\n")
                        inputText = ""
                    }

                Button {
                    sendInput(inputText + "\n")
                    inputText = ""
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(inputText.isEmpty)

                // Ctrl+C button
                Button {
                    sendInput("\u{03}") // ETX
                } label: {
                    Text("^C")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.95))
            .overlay(alignment: .top) {
                Divider().background(Color.gray.opacity(0.3))
            }
        }
        .id(agentId) // Force fresh view identity per agent — prevents cross-agent PTY bleed
        .background(.black)
        .navigationTitle("Live Output")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    inputFocused.toggle()
                } label: {
                    Image(systemName: "keyboard")
                }
            }
        }
    }

    private func setupTerminal() {
        let cols = terminalCols
        terminal.resize(cols: cols, rows: 200) // large row buffer for scrollback
        lastProcessedLength = 0
        processNewPtyData()
        sendResize(cols: cols, rows: 24) // tell server our visible rows
    }

    private func processNewPtyData() {
        let buffer = store.ptyBuffer(for: agentId)
        guard buffer.count > lastProcessedLength else { return }
        let newBytes = buffer.count - lastProcessedLength
        AppLog.shared.debug("Terminal", "[\(agentId.suffix(6))] Processing \(newBytes) new bytes (total=\(buffer.count))")
        let startIndex = buffer.index(buffer.startIndex, offsetBy: lastProcessedLength)
        let newData = String(buffer[startIndex...])
        terminal.write(newData)
        lastProcessedLength = buffer.count
    }

    private func sendInput(_ text: String) {
        guard let inst = store.instance(for: agentId) else {
            AppLog.shared.warn("Terminal", "No instance found for agent \(agentId)")
            return
        }
        let msg = PtyInputMessage(
            type: "pty:input",
            payload: PtyInputPayload(agentId: agentId, data: text)
        )
        inst.webSocket?.send(msg)
        AppLog.shared.info("Terminal", "Sent pty:input (\(text.count) chars) to \(agentId)")
    }

    private func sendResize(cols: Int, rows: Int) {
        guard let inst = store.instance(for: agentId) else { return }
        let msg = PtyResizeMessage(
            type: "pty:resize",
            payload: PtyResizePayload(agentId: agentId, cols: cols, rows: rows)
        )
        inst.webSocket?.send(msg)
        AppLog.shared.info("Terminal", "Sent pty:resize \(cols)x\(rows) to \(agentId)")
    }
}

// MARK: - WebSocket Control Messages

struct PtyInputPayload: Codable, Sendable {
    let agentId: String
    let data: String
}

struct PtyInputMessage: Codable, Sendable {
    let type: String
    let payload: PtyInputPayload
}

struct PtyResizePayload: Codable, Sendable {
    let agentId: String
    let cols: Int
    let rows: Int
}

struct PtyResizeMessage: Codable, Sendable {
    let type: String
    let payload: PtyResizePayload
}
