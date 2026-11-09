#if DEBUG
import SwiftUI
import UIKit

/// Fixed, socket-free UI inputs for the header matrix. This is not the tab-root integration fixture.
struct CompanionConversationHeaderFixture: View {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--companion-preview") && arguments.contains("--companion-preview-header-fixture")
    }

    // Concrete preview service owns value/task state only; no live transport, callbacks or UI fields.
    @State private var store = CompanionStore(service: CompanionPreviewService(showsContextWindow: true, showsAutoQuota: true))
    @State private var ready = false
    @State private var imageVersion = 0
    private let target = CompanionPreviewService.target
    private var arguments: [String] { ProcessInfo.processInfo.arguments }

    var body: some View {
        NavigationStack {
            Group {
                if ready, let agent = store.agent(for: target) {
                    CompanionConversationView(store: store, agent: agent)
                } else { ProgressView("Preparing header fixture…") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button(imageVersion == 0 ? "Use custom profile image" : "Update profile image") {
                            Task { await updateImage() }
                        }
                        .accessibilityIdentifier("header-fixture-image")
                    } label: { Label("Header fixture", systemImage: "photo") }
                    .accessibilityValue("Synthetic profile image version \(imageVersion)")
                    .accessibilityIdentifier("header-fixture-menu")
                }
            }
        }
        .companionTheme(.clubhouse)
        .preferredColorScheme(arguments.contains("--companion-header-light") ? .light : .dark)
        .task {
            guard !ready else { return }
            var host = CompanionPreviewService.hosts(now: .now, helperRequests: CompanionPreviewService.helperRequests,
                                                    contextWindow: true, autoQuota: true)[0]
            guard var agent = host.allAgents.first(where: { $0.id == target }) else { return }
            agent.name = arguments.contains("--companion-header-long-name")
                ? "Alexandria — release coordination and simulator validation"
                : "Header worker"
            agent.status = arguments.contains("--companion-header-idle") ? .idle : .working
            agent.turnStartedAt = agent.status == .working ? Date().addingTimeInterval(-65) : nil
            agent.freeAgentMode = true
            if arguments.contains("--companion-header-boolean-access") {
                // Only the desktop's Auto-or-Full boolean, with no known live level.
                agent.chatControls = nil
                agent.session = nil
            }
            agent.emoji = nil; agent.icon = nil
            host.projects = [.init(id: target.projectID, name: "Header fixture", agents: [agent])]
            host.dispatcher = nil
            store.apply(.hosts([host]))
            await store.load(target)
            let items = (1...18).map { index in
                CompanionTimelineItem.message(.init(id: "header-fixture-\(index)", role: index % 4 == 0 ? .user : .assistant,
                    text: "Reading marker \(index). " + String(repeating: "Synthetic transcript content for glass and scroll reachability. ", count: 4)))
            }
            store.apply(.timeline(target, items: items, sequence: 1, reset: true, sessionID: "header-fixture"))
            ready = true
        }
    }

    private func updateImage() async {
        let next = imageVersion + 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            (next % 2 == 1 ? UIColor.magenta : UIColor.green).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let icon = await CompanionIconStore.shared.ingest(dataURL: "data:image/png;base64," + data.base64EncodedString(),
                                                        host: target.hostID, kind: .agent, id: target.agentID)
        guard let icon, !store.hosts.isEmpty else { return }
        // Make the canonical avatar's request a cache hit before the test waits for this version's label.
        _ = await CompanionIconStore.shared.image(for: icon, points: 28)
        var hosts = store.hosts
        hosts[0].projects[0].agents[0].icon = icon
        store.apply(.hosts(hosts))
        imageVersion = next
    }
}
#endif
