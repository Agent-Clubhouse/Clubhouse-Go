#if DEBUG
import SwiftUI

/// Real transcript/archive rows and their normal URL policy. Only the final system open is intercepted;
/// no Safari, paired desktop, credentials, telemetry client or networking is created by this fixture.
struct CompanionLinkTapFixture: View {
    let store: CompanionStore
    @State private var agent: CompanionAgent?
    @State private var opens = 0
    @State private var lastURL = ""

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                if let agent {
                    if CompanionLinkTapScenario.isArchive {
                        CompanionArchiveView(store: store, target: agent.id)
                    } else if CompanionLinkTapScenario.name == "markdown-file" {
                        CompanionMarkdownFileView(text: CompanionLinkTapScenario.fileSource, line: nil, truncated: false)
                    } else {
                        CompanionConversationView(store: store, agent: agent)
                    }
                } else { ProgressView("Loading link fixture") }
            }
            Text("opens=\(opens);url=\(lastURL)")
                .font(.caption2).lineLimit(3).frame(height: 54)
                .accessibilityIdentifier("mobile-link-open-receipt")
        }
        .environment(\.openURL, OpenURLAction { url in
            opens += 1
            lastURL = url.absoluteString
            print("MOBILE_LINK_SYSTEM_OPEN count=\(opens) url=\(lastURL)")
            return .handled
        })
        .task {
            let preview = CompanionPreviewService(showsDispatcher: true)
            var events = preview.events().makeAsyncIterator()
            if let report = await events.next() { store.apply(report) }
            let target = CompanionLinkTapScenario.name == "dispatcher" ? CompanionPreviewService.dispatcherTarget : CompanionPreviewService.target
            await store.load(target)
            store.apply(.timeline(target, items: CompanionLinkTapScenario.items, sequence: 100, reset: true, sessionID: "links"))
            agent = store.agent(for: target)
        }
    }
}

enum CompanionLinkTapScenario {
    static var name: String { ProcessInfo.processInfo.environment["MOBILE_LINK_SCENARIO"] ?? "sent" }
    static var isArchive: Bool { name.hasPrefix("archive-") }
    static let destination = "https://github.com/Agent-Clubhouse/Clubhouse-Go/actions/runs/123?check=a--b&mode=two#job-45"
    static let fileSource = "\"Ready\" -- [File PR](\(destination))\n\n\(destination).\n\n[Blocked](javascript:alert) [Local](./secret.md)\n"
    static var items: [CompanionTimelineItem] {
        let message: CompanionMessage
        switch name {
        case "sent", "archive-sent":
            message = .init(id: "links-sent", role: .user, text: destination)
        case "relayed":
            message = .init(id: "links-relayed", role: .user, text: destination, source: "group_project", routed: [.init(text: destination)])
        case "clubhouse":
            message = .init(id: "links-clubhouse", role: .user, text: destination, source: "mcp", routed: [.init(fromClubhouse: true, text: destination)])
        case "table":
            message = .init(id: "links-table", role: .assistant, text: "| Review |\n|---|\n| [Table PR](\(destination)) |")
        case "code":
            message = .init(id: "links-code", role: .user, text: "`\(destination)`")
        case "blocked":
            message = .init(id: "links-blocked", role: .assistant, text: "[Blocked route](javascript:alert) [Outside file](/outside-secret.md)")
        case "local-file":
            message = .init(id: "links-local", role: .assistant, text: "[Local file](Sources/Companion/Conversation.swift)")
        default:
            message = .init(id: "links-received", role: .assistant, text: "\"Ready\" -- [Review PR](\(destination)).\n\nBare \(destination).")
        }
        return [.message(message)]
    }
}

/// Exercise the actual saved-session loader/view, rather than a second copy of its row renderer.
extension CompanionPreviewService: CompanionArchiveReading {
    func sessions(for target: CompanionTarget) async throws -> [CompanionSessionSummary] {
        guard ProcessInfo.processInfo.arguments.contains("--mobile-links-ui-testing") else {
            throw CompanionServiceError.unavailable("This desktop does not support conversation archives yet.")
        }
        return [.init(id: "links", title: "Saved links")]
    }
    func archive(for target: CompanionTarget, sessionID: String) throws -> any CompanionArchiveReading {
        guard ProcessInfo.processInfo.arguments.contains("--mobile-links-ui-testing"), sessionID == "links" else {
            throw CompanionServiceError.unavailable("This desktop does not support conversation archives yet.")
        }
        return CompanionPreviewService()
    }
    func load(before: Int64?) async throws -> CompanionArchivePage {
        .init(items: CompanionLinkTapScenario.items)
    }
}
#endif
