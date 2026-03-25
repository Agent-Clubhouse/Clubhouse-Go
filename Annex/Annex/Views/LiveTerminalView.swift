import SwiftUI

struct LiveTerminalView: View {
    let agentId: String
    @Environment(AppStore.self) private var store
    @State private var terminal = ANSITerminal(cols: 80, rows: 200)
    @State private var inputText = ""
    @State private var unsubscribe: (() -> Void)?
    @State private var isAtBottom = true
    @State private var renderVersion = 0
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
                    VStack(spacing: 0) {
                        Text(terminal.render())
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)

                        // Invisible anchor at the very end of content
                        Color.clear
                            .frame(height: 1)
                            .id("end")
                    }
                }
                .onAppear {
                    setupTerminal()
                    scrollToBottom(proxy)
                }
                .onDisappear {
                    unsubscribe?()
                    unsubscribe = nil
                }
                .onChange(of: renderVersion) {
                    if isAtBottom {
                        scrollToBottom(proxy)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom {
                        Button {
                            isAtBottom = true
                            scrollToBottom(proxy)
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 32))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .gray.opacity(0.8))
                                .shadow(radius: 4)
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                    }
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
                        sendInput(inputText + "\r")
                        inputText = ""
                    }

                Button {
                    sendInput(inputText + "\r")
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
        .id(agentId)
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isAtBottom = true
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("end", anchor: .bottom)
        }
    }

    private func setupTerminal() {
        let cols = terminalCols
        terminal = ANSITerminal(cols: cols, rows: 200)
        isAtBottom = true

        // Subscribe to live PTY data first (so we don't miss data during buffer fetch)
        if let inst = store.instance(for: agentId) {
            unsubscribe = inst.subscribePtyData(agentId: agentId) { [terminal] data in
                terminal.write(data)
                renderVersion += 1
            }
            AppLog.shared.info("Terminal", "[\(agentId.suffix(6))] Subscribed to live PTY data")
        }

        // Load from in-memory buffer (accumulated from WebSocket pty:data)
        let memBuffer = store.ptyBuffer(for: agentId)
        if !memBuffer.isEmpty {
            terminal.write(memBuffer)
            AppLog.shared.info("Terminal", "[\(agentId.suffix(6))] Loaded \(memBuffer.count) bytes from memory buffer")
        }

        // Also fetch full buffer from REST API (gets history from before WS connected)
        Task {
            await fetchFullBuffer()
        }

        sendResize(cols: cols, rows: 24)
    }

    private func fetchFullBuffer() async {
        guard let inst = store.instance(for: agentId),
              let apiClient = inst.apiClient,
              let token = inst.token else { return }
        do {
            let fullBuffer = try await apiClient.getBuffer(agentId: agentId, token: token)
            if !fullBuffer.isEmpty {
                // Reset terminal and write full buffer (it's the authoritative source)
                let cols = terminalCols
                terminal = ANSITerminal(cols: cols, rows: 200)
                terminal.write(fullBuffer)
                AppLog.shared.info("Terminal", "[\(agentId.suffix(6))] Fetched \(fullBuffer.count) bytes from REST buffer API")

                // Re-subscribe since we replaced the terminal
                if let inst = store.instance(for: agentId) {
                    unsubscribe?()
                    unsubscribe = inst.subscribePtyData(agentId: agentId) { [terminal] data in
                        terminal.write(data)
                        renderVersion += 1
                    }
                }
                renderVersion += 1
            }
        } catch {
            AppLog.shared.debug("Terminal", "[\(agentId.suffix(6))] Buffer fetch failed (agent may not be running): \(error)")
        }
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
        isAtBottom = true
        renderVersion += 1
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
