import Foundation

/// Recovery concerns the paired desktop's visible chat, never its hidden work controller.
struct CompanionDispatcherRecovery: Equatable {
    let target: CompanionTarget
    let name: String
    let hostName: String
    let canInterrupt: Bool
    let canStop: Bool
    let canStartNewChat: Bool
    let unavailableReason: String?

    static let controllerUnavailable = "This desktop doesn't offer controller history or Restart Dispatcher from this phone. Use Clubhouse on that desktop. Restart is different from stopping this chat or starting a new chat."
    static let unknownReset = "The new-chat reply was lost or couldn't be verified. Check this Dispatcher on its desktop before another action. Refreshing or reopening does not repeat the request."
}

struct CompanionDispatcherChatPrompt: Equatable, Identifiable {
    enum Action { case interrupt, stop }
    let id = UUID()
    let action: Action
    let target: CompanionTarget
    let epoch: String
    let sessionID: String
    let name: String
    let hostName: String
    var title: String { action == .interrupt ? "Interrupt this chat turn?" : "Stop this chat session?" }
    var button: String { action == .interrupt ? "Interrupt chat turn" : "Stop chat session" }
    var message: String {
        if action == .interrupt {
            return "Interrupt the current turn in \(name) on \(hostName)? Its conversation stays. This does not restart the work controller."
        }
        return "Request a stop of \(name)'s visible chat on \(hostName). Its saved conversation stays. Wait for the desktop to report Sleeping. The work controller is separate; this does not restart it."
    }
}
