import SwiftUI

/// Human-operated recovery for one paired host's visible chat. No hidden controller command is synthesized.
struct CompanionDispatcherRecoveryView: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    @Environment(\.dismiss) private var dismiss

    private var recovery: CompanionDispatcherRecovery? { store.dispatcherRecovery(for: target) }
    private var chatPrompt: CompanionDispatcherChatPrompt? {
        store.dispatcherChatPrompt.flatMap { $0.target == target ? $0 : nil }
    }
    private var prompt: CompanionDispatcherResetPrompt? {
        store.dispatcherResetPrompt.flatMap { $0.hostID == target.hostID && $0.reset == .clearChat ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let recovery {
                    Section("Visible Dispatcher chat") {
                        LabeledContent("Dispatcher", value: recovery.name)
                        LabeledContent("Desktop", value: recovery.hostName)
                        Text("These controls affect the chat you talk to on this desktop. The separate controller does the Dispatcher's background work.")
                            .accessibilityIdentifier("dispatcher-recovery-target")
                        if let reason = recovery.unavailableReason {
                            Text(reason).accessibilityIdentifier("dispatcher-recovery-unavailable")
                        }
                    }
                    Section {
                        Button("Interrupt chat turn", systemImage: "stop.circle", role: .destructive) { store.askDispatcherChatAction(.interrupt, target: target) }
                            .disabled(!recovery.canInterrupt)
                            .accessibilityIdentifier("dispatcher-recovery-interrupt")
                    } footer: {
                        Text("Interrupts the visible chat's current turn. Keeps the conversation; this is not a Dispatcher restart.")
                    }
                    Section {
                        if store.sleepRequests.contains(target) {
                            Text("Chat stop requested. Waiting for the desktop to confirm.")
                                .accessibilityIdentifier("dispatcher-recovery-stop-pending")
                            Button("Check chat stop status", systemImage: "arrow.clockwise") {
                                Task { await store.refreshSleepState(target) }
                            }
                            .disabled(store.sleepRefreshes.contains(target) || store.host(for: target)?.connection.canOperate != true)
                        } else {
                            Button("Stop chat session", systemImage: "stop.fill", role: .destructive) { store.askDispatcherChatAction(.stop, target: target) }
                                .disabled(!recovery.canStop)
                                .accessibilityIdentifier("dispatcher-recovery-stop")
                        }
                        if let agent = store.agent(for: target), agent.isSleepingOnDesktop == true {
                            Text("The desktop reports this chat is sleeping. Starting it again is a separate action.")
                                .accessibilityIdentifier("dispatcher-recovery-stopped")
                        }
                    } footer: {
                        Text("Requests a stop of this visible chat's session, keeping its saved conversation. It does not restart or stop the separate work controller.")
                    }
                    Section {
                        Button("Start new chat", systemImage: "bubble.left.and.bubble.right", role: .destructive) {
                            Task { await store.askDispatcherRecoveryNewChat(target) }
                        }
                        .disabled(!recovery.canStartNewChat)
                        .accessibilityIdentifier("dispatcher-recovery-new-chat")
                        if store.dispatcherRecoveryPreparing.contains(target) { ProgressView("Reading confirmation…") }
                        if let notice = store.dispatcherResetNotices[target.hostID] {
                            Text(notice).accessibilityIdentifier("dispatcher-recovery-result")
                        }
                    } footer: {
                        Text("Starts only the visible conversation over after confirmation. Memory, agents, connections, Actions and settings stay. It does not restart the controller.")
                    }
                    Section("Controller recovery") {
                        Text(CompanionDispatcherRecovery.controllerUnavailable)
                            .accessibilityIdentifier("dispatcher-recovery-host-required")
                    }
                    if let error = store.operationErrors[target] { Text(error).accessibilityIdentifier("dispatcher-recovery-error") }
                } else {
                    ContentUnavailableView("Dispatcher changed", systemImage: "arrow.clockwise",
                        description: Text("Close this sheet and select the Dispatcher on the intended desktop again."))
                }
            }
            .navigationTitle("Dispatcher recovery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert(chatPrompt?.title ?? "", isPresented: Binding(get: { chatPrompt != nil }, set: { if !$0 { store.dispatcherChatPrompt = nil } }), presenting: chatPrompt) { prompt in
                Button(prompt.button, role: .destructive) { Task { await store.confirmDispatcherChatAction(prompt) } }
                Button("Cancel", role: .cancel) { store.dispatcherChatPrompt = nil }
            } message: { prompt in Text(prompt.message) }
            .alert("Start a new chat?", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { store.cancelDispatcherReset() } }), presenting: prompt) { prompt in
                Button("Start new chat", role: .destructive) { Task { await store.confirmDispatcherRecoveryNewChat(prompt, target: target) } }
                Button("Cancel", role: .cancel) { store.cancelDispatcherReset() }
            } message: { prompt in
                Text("\(prompt.name) on \(recovery?.hostName ?? "the selected desktop").\n\n\(prompt.message) The work controller is not restarted.")
            }
        }
    }
}
