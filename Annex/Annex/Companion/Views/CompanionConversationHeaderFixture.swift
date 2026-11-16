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
    private var pushed: Bool { arguments.contains("--companion-header-pushed") }

    private var theme: CompanionDesktopTheme {
        if arguments.contains("--companion-header-latte") {
            return .init(id: "latte", name: "Catppuccin Latte", source: "Desktop fixture", mode: .light,
                         colors: ["base": "#eff1f5", "mantle": "#e6e9ef", "crust": "#dce0e8", "text": "#4c4f69", "subtext0": "#6c6f85",
                                  "surface0": "#ccd0da", "surface1": "#bcc0cc", "accent": "#1e66f5", "accent2": "#209fb5",
                                  "warning": "#7e5700", "error": "#c4122f", "success": "#347d22"], gradient: [])
        }
        if arguments.contains("--companion-header-mocha") {
            return .init(id: "mocha", name: "Catppuccin Mocha", source: "Desktop fixture", mode: .dark,
                         colors: ["base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4", "subtext0": "#a6adc8",
                                  "surface0": "#313244", "surface1": "#45475a", "accent": "#89b4fa", "accent2": "#74c7ec",
                                  "warning": "#f9e2af", "error": "#f38ba8", "success": "#a6e3a1"], gradient: [])
        }
        return .clubhouse
    }

    private var conversation: some View {
        Group {
            if ready, let agent = store.agent(for: target) {
                CompanionConversationView(store: store, agent: agent)
            } else { ProgressView("Preparing header fixture…") }
        }
    }


    var body: some View {
        NavigationStack {
            Group {
                if pushed {
                    NavigationLink("Open chat") { conversation }
                        .accessibilityIdentifier("header-fixture-open-chat")
                } else { conversation }
            }
            .toolbar {
                if !pushed && !arguments.contains("--companion-header-no-leading") {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button(imageVersion == 0 ? "Use custom profile image" : "Update profile image") {
                                Task { await updateImage() }
                            }
                            .accessibilityIdentifier("header-fixture-image")
                            Button("Require conversation refresh") {
                                store.apply(.resyncRequired(hostID: target.hostID))
                            }
                            .accessibilityIdentifier("header-fixture-refresh")
                            if arguments.contains("--companion-header-held-tail") {
                                Button("Append held reply") {
                                    store.apply(.upsert(target, .message(.init(id: "header-fixture-incoming", role: .assistant,
                                        text: "Held incoming tail.")), sequence: nil))
                                }
                                .accessibilityIdentifier("header-fixture-append")
                            }
                        } label: { Label("Header fixture", systemImage: "photo") }
                        .accessibilityValue("Synthetic profile image version \(imageVersion)")
                        .accessibilityIdentifier("header-fixture-menu")
                    }
                }
            }
        }
        .companionTheme(theme)
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
                agent.access = nil
            }
            if let raw = arguments.first(where: { $0.hasPrefix("--companion-header-saved-access=") })?.split(separator: "=").last,
               let level = CompanionPermissionLevel(rawValue: String(raw)) {
                agent.access = level
                agent.chatControls = nil
                agent.session = nil
            }
            if arguments.contains("--companion-context-sheet-fixture") {
                agent.contextUsage = .init(used: 84_000, size: 200_000, reportedAt: .now.addingTimeInterval(-120))
                if arguments.contains("--companion-context-unknown") { agent.contextUsage = nil }
                if arguments.contains("--companion-context-undated") { agent.contextUsage?.reportedAt = nil }
                if arguments.contains("--companion-context-quota-unknown") { agent.orchestrator = "copilot-cli" }
            }
            agent.emoji = nil; agent.icon = nil
            host.projects = [.init(id: target.projectID, name: "Header fixture", agents: [agent])]
            host.dispatcher = nil
            store.apply(.hosts([host]))
            await store.load(target)
            var items = (1...18).map { index in
                CompanionTimelineItem.message(.init(id: "header-fixture-\(index)", role: index % 4 == 0 ? .user : .assistant,
                    text: "Reading marker \(index). " + String(repeating: "Synthetic transcript content for glass and scroll reachability. ", count: 4)))
            }
            if arguments.contains("--companion-header-held-tail") {
                items = [
                    .message(.init(id: "header-fixture-held-reply", role: .assistant,
                        text: String(repeating: "Held stationary reply paragraph.\n\n", count: 160))),
                    .message(.init(id: "header-fixture-held-end", role: .user, text: "Held final row."))
                ]
            }
            store.apply(.timeline(target, items: items, sequence: 1, reset: true, sessionID: "header-fixture"))
            if arguments.contains("--companion-header-offline") { host.connection = .offline }
            if arguments.contains("--companion-header-reconnecting") { host.connection = .reconnecting }
            store.apply(.hosts([host]))
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
