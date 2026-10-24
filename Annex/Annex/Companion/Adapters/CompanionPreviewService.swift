#if DEBUG
import Foundation

/// Explicit UI preview adapter. Never selected by a normal launch or by production pairing.
@MainActor final class CompanionPreviewService: CompanionService {
    private var continuation: AsyncStream<CompanionEvent>.Continuation?
    static let target = CompanionTarget(hostID: "preview-studio", projectID: "clubhouse", agentID: "river")
    func events() -> AsyncStream<CompanionEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.hosts([
                .init(id: Self.target.hostID, name: "Studio Mac", endpoint: "studio.local · Local network", connection: .connected, projects: [
                    .init(id: "clubhouse", name: "Clubhouse", agents: [
                        .init(id: Self.target, name: "River", subtitle: "Build the mobile companion", status: .approval, model: "Codex", capabilities: [.chat, .steer, .cancel, .approve]),
                        .init(id: .init(hostID: Self.target.hostID, projectID: "clubhouse", agentID: "cedar"), name: "Cedar", subtitle: "Investigate reconnect behavior", status: .working, model: "Claude", capabilities: [.chat, .steer, .cancel, .approve])
                    ])
                ]),
                .init(id: "preview-laptop", name: "Travel MacBook", endpoint: "travel.tailnet.ts.net · Tailscale", connection: .offline, projects: [
                    .init(id: "notes", name: "Field notes", agents: [
                        .init(id: .init(hostID: "preview-laptop", projectID: "notes", agentID: "river"), name: "River", subtitle: "Organize research notes", status: .idle)
                    ])
                ])
            ]))
        }
    }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        .init(items: [
            .notice(id: "preview", text: "Preview conversation · no desktop commands are sent"),
            .message(.init(id: "user-1", role: .user, text: "Make it easy to continue a desktop agent from my phone. Focus on the conversation and the moments that need me.", timestamp: Date().addingTimeInterval(-180))),
            .message(.init(id: "agent-1", role: .assistant, text: "I’ve mapped out the companion experience. Each desktop keeps its own projects and agents, so you can move between them without losing your place.\n\nThe first pass puts **conversation, progress, and approvals** together. I’m checking the reconnect behavior next.", timestamp: Date().addingTimeInterval(-150))),
            .tool(.init(id: "tool-1", name: "Read project files", summary: "Sources/Companion/Conversation.swift", output: "Read 246 lines from the conversation view.", state: .completed)),
            .tool(.init(id: "tool-2", name: "Run focused tests", summary: "swift test --filter ConversationTests", output: "8 tests passed. No failures.", state: .completed)),
            .message(.init(id: "agent-2", role: .assistant, text: "The draft now stays with its agent while the desktop reconnects. A missed event triggers a history refresh before another command can be sent.\n\n```swift\nlet target = ConversationTarget(\n    host: studio,\n    project: clubhouse,\n    agent: river\n)\n```", timestamp: Date().addingTimeInterval(-60))),
            .approval(.init(id: "approval-1", toolName: "Run build", summary: "Build the iOS application to verify the updated conversation layout.", detail: "xcodebuild -scheme ClubhouseGo -sdk iphonesimulator build", deadline: Date().addingTimeInterval(600), options: [
                .init(id: "allow-once", label: "Allow once", kind: .allowOnce),
                .init(id: "reject-once", label: "Deny", kind: .rejectOnce)
            ]))
        ])
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        throw CompanionServiceError.unavailable("Preview only. Pair a desktop to send messages.")
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw previewError }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw previewError }
    func reconnect(hostID: String) async {}
    private var previewError: CompanionServiceError { .unavailable("Preview only. This action does not contact a desktop.") }
}
#endif
