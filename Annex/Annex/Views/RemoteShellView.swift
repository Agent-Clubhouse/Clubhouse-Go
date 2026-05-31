import SwiftUI

/// Interactive remote shell terminal — spawns a shell at the project root
/// and provides full PTY input/output via the mTLS WebSocket.
struct RemoteShellView: View {
    let projectId: String
    let instanceId: ServerInstanceID
    let shellLabel: String

    @Environment(AppStore.self) private var store
    @State private var terminal = ANSITerminal(cols: 80, rows: 200)
    @State private var inputText = ""
    @State private var sessionId = UUID().uuidString
    @State private var isConnected = false
    @State private var isAtBottom = true
    @State private var renderVersion = 0
    @State private var unsubscribe: (() -> Void)?
    @FocusState private var inputFocused: Bool

    private var instance: ServerInstance? {
        store.instanceByID(instanceId)
    }

    private var terminalCols: Int {
        let screenWidth = UIScreen.main.bounds.width - 16
        let charWidth: CGFloat = 6.7
        return max(Int(screenWidth / charWidth), 40)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Text(terminal.render())
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)

                        Color.clear
                            .frame(height: 1)
                            .id("end")
                    }
                }
                .onChange(of: renderVersion) {
                    if isAtBottom {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("end", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            HStack(spacing: 8) {
                Circle()
                    .fill(isConnected ? .green : .orange)
                    .frame(width: 8, height: 8)

                TextField("Shell command...", text: $inputText)
                    .font(.system(size: 14, design: .monospaced))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.send)
                    .focused($inputFocused)
                    .onSubmit { submitInput() }
                    .onChange(of: inputText) { oldValue, newValue in
                        handleInputChange(from: oldValue, to: newValue)
                    }

                Button {
                    submitInput()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                }
                .disabled(inputText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(store.theme.mantleColor)
        }
        .background(store.theme.baseColor)
        .navigationTitle(shellLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sendInput("\u{03}") // Ctrl+C
                } label: {
                    Text("Ctrl+C")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            spawnShell()
        }
        .onDisappear {
            killShell()
        }
    }

    private func spawnShell() {
        guard let instance else { return }

        let cols = terminalCols
        terminal = ANSITerminal(cols: cols, rows: 200)

        // Subscribe to pty:data for our sessionId (server sends with agentId = sessionId)
        unsubscribe = instance.subscribePtyData(agentId: sessionId) { [terminal] data in
            terminal.write(data)
            renderVersion += 1
        }
        AppLog.shared.info("Shell", "[\(sessionId.prefix(8))] Subscribed to shell PTY data")

        // Spawn the shell
        instance.spawnShell(sessionId: sessionId, projectId: projectId)
        isConnected = true

        // Send resize
        instance.sendPtyResize(sessionId: sessionId, cols: cols, rows: 24)
    }

    private func killShell() {
        // Send Ctrl+C then exit to clean up the shell process
        sendInput("\u{03}\nexit\n")
        unsubscribe?()
        unsubscribe = nil
        AppLog.shared.info("Shell", "[\(sessionId.prefix(8))] Shell terminated")
    }

    private func sendInput(_ text: String) {
        instance?.sendPtyInput(sessionId: sessionId, data: text)
        isAtBottom = true
        renderVersion += 1
    }

    /// Route a binding change through `PTYInputSubmit` to distinguish an
    /// explicit Return (submit) from a paste/dictation (don't submit).
    private func handleInputChange(from oldValue: String, to newValue: String) {
        switch PTYInputSubmit.evaluate(previous: oldValue, current: newValue) {
        case .none:
            break
        case .clear:
            inputText = ""
        case .replace(let cleaned):
            inputText = cleaned
        case .submit(let command):
            submit(command: command)
        }
    }

    /// Submit whatever is currently in the field (Send button / `.onSubmit`).
    private func submitInput() {
        // Normalize defensively in case stray newlines reached the binding.
        submit(command: inputText.filter { $0 != "\n" && $0 != "\r" })
    }

    /// Send `command` to the shell, clear the field, and keep the keyboard up.
    private func submit(command: String) {
        inputText = ""
        // Re-assert focus: clearing the field can otherwise drop first responder
        // and dismiss the keyboard after every send (issue #95, Problem B).
        inputFocused = true
        guard !command.isEmpty else { return }
        sendInput(command + "\r")
    }
}

#Preview {
    let store = AppStore()
    store.loadMockData()
    return NavigationStack {
        RemoteShellView(
            projectId: "proj_001",
            instanceId: store.instances[0].id,
            shellLabel: "Project Shell"
        )
    }
    .environment(store)
}
