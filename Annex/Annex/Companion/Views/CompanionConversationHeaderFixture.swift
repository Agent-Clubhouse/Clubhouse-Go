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
    @State private var activityStep = 0
    /// The feedback screenshot path's own render of the window, shown over it for comparison.
    @State private var feedbackCapture: UIImage?
    private let target = CompanionPreviewService.target
    private var arguments: [String] { ProcessInfo.processInfo.arguments }
    private var pushed: Bool { arguments.contains("--companion-header-pushed") }

    private var theme: CompanionDesktopTheme {
        if arguments.contains("--companion-header-terminal") {
            return .init(id: "terminal", name: "Terminal", source: "Desktop fixture", mode: .dark,
                         colors: ["base": "#0a0a0a", "mantle": "#050505", "crust": "#000000", "text": "#00ff00",
                                  "subtext0": "#00aa00", "surface0": "#1a1a1a", "surface1": "#252525", "accent": "#00ff00",
                                  "accent2": "#00ffff", "warning": "#ffff00", "error": "#ff3333", "success": "#00ff00",
                                  "info": "#00aaff"], gradient: [])
        }
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
        if arguments.contains("--companion-header-bright-wash") {
            // A dark theme whose wash is bright green under the bar, like the reported phone.
            return .init(id: "bright-wash", name: "Bright wash", source: "Desktop fixture", mode: .dark,
                         colors: ["base": "#11181c", "mantle": "#0c1215", "crust": "#070b0d", "text": "#e8f0ee", "subtext0": "#9fb0ab",
                                  "surface0": "#1f2a2e", "surface1": "#2c3a3f", "accent": "#5fd08a", "warning": "#f5c451",
                                  "error": "#ff6b6b", "success": "#7be495"], gradient: ["#7dffb0", "#c8ff7a"])
        }
        return .clubhouse
    }

    @ViewBuilder private var conversation: some View {
        if arguments.contains("--companion-header-activity-floor-room") {
            // Real viewport room puts the new SE activity-floor fixture clearly below
            // its floor. Non-flag launches keep the original content without an inset.
            conversationContent.safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 20).accessibilityHidden(true)
            }
        } else {
            conversationContent
        }
    }

    private var conversationContent: some View {
        Group {
            if ready, let agent = store.agent(for: target) {
                CompanionConversationView(store: store, agent: agent)
            } else { ProgressView("Preparing header fixture…") }
        }
        // `--companion-preview-toolbar-scheme-flip` (#534): a synthetic mismatch. The palette keeps the launch
        // appearance while the conversation and its bar items see the opposite colorScheme. It shows the bar glass
        // keeps to the palette over an opposite environment, not that this is how iOS 27 drew it white.
        .environment(\.colorScheme, arguments.contains("--companion-preview-toolbar-scheme-flip") != isLight ? .light : .dark)
    }

    private var isLight: Bool { arguments.contains("--companion-header-light") }


    var body: some View {
        NavigationStack {
            Group {
                if pushed {
                    NavigationLink("Open chat") { conversation }
                        .accessibilityIdentifier("header-fixture-open-chat")
                } else { conversation }
            }
            .toolbar {
                if arguments.contains("--companion-header-activity-transitions") {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { advanceActivity() } label: { Image(systemName: "forward.end") }
                            .accessibilityLabel("Next activity fixture state")
                            .accessibilityValue(String(activityStep))
                            .accessibilityIdentifier("activity-fixture-next")
                    }
                } else if !pushed && !arguments.contains("--companion-header-no-leading") {
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
                            Button("Show feedback capture") {
                                let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                                    .flatMap(\.windows).first(where: \.isKeyWindow)
                                feedbackCapture = window.flatMap(CompanionFeedbackPresenter.freeze).map { UIImage(cgImage: $0) }
                            }
                            .accessibilityIdentifier("header-fixture-feedback-capture")
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
        .overlay {
            if let feedbackCapture {
                Image(uiImage: feedbackCapture).resizable().ignoresSafeArea()
                    .onTapGesture { self.feedbackCapture = nil }
                    .accessibilityIdentifier("header-fixture-capture-image")
            }
        }
        .companionTheme(theme)
        .preferredColorScheme(isLight ? .light : .dark)
        .task {
            guard !ready else { return }
            var host = CompanionPreviewService.hosts(now: .now, helperRequests: CompanionPreviewService.helperRequests,
                                                    contextWindow: true, autoQuota: true)[0]
            guard var agent = host.allAgents.first(where: { $0.id == target }) else { return }
            agent.name = arguments.contains("--companion-header-long-name")
                ? "Alexandria — release coordination and simulator validation"
                // One unbroken word, like the #554 report.
                : arguments.contains("--companion-header-orchestrator-name") ? "Clubhouse-Orchestrator" : "Header worker"
            agent.status = arguments.contains("--companion-header-idle") ? .idle : .working
            if arguments.contains("--companion-header-queue") {
                agent.capabilities.remove(.steer)
                agent.capabilities.insert(.queue)
            }
            agent.turnStartedAt = agent.status == .working && !arguments.contains("--companion-header-activity-transitions")
                ? Date().addingTimeInterval(-65) : nil
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
            if arguments.contains("--companion-header-activity-transitions") {
                items += [
                    .tool(.init(id: "activity-tool-0", name: "Read file", summary: "Synthetic activity", state: .running))
                ]
                if !arguments.contains("--companion-header-activity-no-requests") {
                    items += [.approval(.init(id: "activity-approval", toolName: "Bash", summary: "Synthetic pending request",
                        title: "Review fixture action", options: [.init(id: "allow", label: "Allow once", kind: .allowOnce),
                                                                .init(id: "deny", label: "Deny", kind: .rejectOnce)]))]
                }
            }
            store.apply(.timeline(target, items: items, sequence: 1, reset: true, sessionID: "header-fixture"))
            if arguments.contains("--companion-header-offline") { host.connection = .offline }
            if arguments.contains("--companion-header-reconnecting") { host.connection = .reconnecting }
            if arguments.contains("--companion-header-synchronizing") { host.connection = .synchronizing }
            store.apply(.hosts([host]))
            ready = true
            // `--companion-header-stream` (#554): a reply grows and the context ring moves, four ticks a second for 20s.
            guard arguments.contains("--companion-header-stream") else { return }
            for tick in 1...80 {
                try? await Task.sleep(for: .milliseconds(250))
                store.apply(.upsert(target, .message(.init(id: "header-fixture-stream", role: .assistant,
                    text: String(repeating: "Streaming reply chunk. ", count: tick))), sequence: nil))
                host.projects[0].agents[0].contextUsage = .init(used: 40_000 + 1_000 * tick, size: 200_000, reportedAt: .now)
                store.apply(.hosts([host]))
            }
        }
    }

    /// Explicit inputs through real store events, never a layout override or a repeating timer.
    private func advanceActivity() {
        guard activityStep < 6, var host = store.host(for: target),
              let project = host.projects.firstIndex(where: { $0.id == target.projectID }),
              let index = host.projects[project].agents.firstIndex(where: { $0.id == target }) else { return }
        activityStep += 1
        host.projects[project].agents[index].status = activityStep == 6 ? .idle : .working
        host.projects[project].agents[index].turnStartedAt = nil
        if activityStep < 6 {
            let group = activityStep / 2
            let name = ["Read file", "Edit file", "mcp__clubhouse__message_parent"][group]
            store.apply(.upsert(target, .tool(.init(id: "activity-tool-\(group)", name: name,
                summary: "Synthetic activity", state: activityStep.isMultiple(of: 2) ? .running : .completed)), sequence: nil))
        }
        store.apply(.hosts([host]))
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
