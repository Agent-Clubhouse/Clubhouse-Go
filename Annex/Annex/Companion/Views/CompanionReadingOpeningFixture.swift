#if DEBUG
import SwiftUI
import UIKit

/// Opt-in recording harness. The user/test starts each mount after video recording has begun.
/// Bookmarks use real preview histories; the production view draws immediately without opacity or a paint delay.
struct CompanionReadingOpeningFixture: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var lifetime = CompanionStateLifetime {
        CompanionStore(service: CompanionPreviewService(showsReadingScenario: true))
    }
    @State private var agents: [CompanionAgent] = []
    @State private var selected = 0
    @State private var mounted = false
    @State private var tab = 0
    @State private var presentsDestination = false
    private var visible: Bool { tab == 0 }
    @State private var scenario = "loading"
    @State private var status = "loading"
    private var store: CompanionStore { lifetime.value }
    private var target: CompanionTarget? { agents.indices.contains(selected) ? agents[selected].id : nil }
    private var theme: CompanionDesktopTheme { CompanionPreviewService.appearanceTheme ?? .clubhouse }
    private var colorScheme: ColorScheme {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--companion-preview-light") { return .light }
        if arguments.contains("--companion-preview-dark") { return .dark }
        return theme.mode == .light ? .light : .dark
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                Tab("Chat", systemImage: "bubble.left", value: 0) {
                    NavigationStack {
                        Group {
                            if mounted, agents.indices.contains(selected) {
                                // No identity on this parent: the transcript itself must separate target State.
                                CompanionConversationView(store: store, agent: agents[selected], isVisible: visible)
                            } else { Text("Ready to open a chat").accessibilityIdentifier("reading-opening-unmounted") }
                        }
                        .navigationDestination(isPresented: $presentsDestination) {
                            if agents.indices.contains(selected) {
                                CompanionConversationView(store: store, agent: agents[selected])
                                    .toolbar(.hidden, for: .tabBar)
                            }
                        }
                    }
                }
                Tab("Home", systemImage: "house", value: 1) { Text("Recording fixture Home") }
            }
            Text(status).font(.caption2).lineLimit(3).frame(height: 48).accessibilityIdentifier("reading-opening-state")
                .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--reading-opening-clearance-diagnostic")
                    ? "dynamicTypeSize=\(dynamicTypeSize) deviceModel=\(UIDevice.current.model) system=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion) simulatorModel=\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "none")"
                    : "")
            // DEBUG controls only: two visible rows replace the unreliable offscreen strip.
            // Their offered height is disclosed in the recording; the real chat uses the remaining viewport.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    recordingControl("Latest") { scenario = "latest"; mounted = true }
                        .accessibilityIdentifier("reading-opening-latest")
                    recordingControl("Paused") { Task { await openPaused() } }
                        .accessibilityIdentifier("reading-opening-paused")
                    recordingControl("Hide") { scenario = "hidden"; tab = 1 }
                        .accessibilityIdentifier("reading-opening-hide")
                    recordingControl("Show") { scenario = "tab-return"; tab = 0 }
                        .accessibilityIdentifier("reading-opening-show")
                    recordingControl("Close") {
                        Task { if await closeCurrentMount() { scenario = "closed" } }
                    }
                        .accessibilityIdentifier("reading-opening-close")
                    recordingControl("Reopen") { scenario = "reopen"; presentsDestination = true }
                        .accessibilityIdentifier("reading-opening-reopen")
                    recordingControl("Other") { scenario = "target-switch"; selected = selected == 0 ? 1 : 0 }
                        .accessibilityIdentifier("reading-opening-other")
                    recordingControl("Reload") {
                        guard let target else { return }
                        let wasHidden = !visible
                        scenario = "loading-history"
                        Task {
                            await store.load(target, force: true)
                            scenario = wasHidden ? "hidden-reload" : "open-reload"
                        }
                    }.accessibilityIdentifier("reading-opening-reload")
                    recordingControl("Stream") {
                        guard let target else { return }
                        store.apply(.textDelta(target, messageID: "reading-helper", text: " streamed after drag", sequence: nil))
                        scenario = "streamed"
                    }.accessibilityIdentifier("reading-opening-stream")
                    recordingControl("Append") {
                        guard let target else { return }
                        store.apply(.upsert(target, .message(.init(id: "opening-earlier-tail", role: .assistant,
                            text: "A new tail reply arrives while earlier history is visible.")), sequence: nil))
                        scenario = "tail-arrived"
                    }.accessibilityIdentifier("reading-opening-append")
                    recordingControl("Short") { Task { await openShortPaused() } }
                        .accessibilityIdentifier("reading-opening-short")
                    recordingControl("Replace") { replaceSession() }
                        .accessibilityIdentifier("reading-opening-session")
            }
            .buttonStyle(.bordered).font(.system(size: 12))
            .accessibilityIdentifier("reading-opening-actions")
        }
        .companionTheme(theme)
        .preferredColorScheme(colorScheme)
        .task {
            let preview = CompanionPreviewService(showsReadingScenario: true)
            var events = preview.events().makeAsyncIterator()
            if let event = await events.next() { store.apply(event) }
            agents = Array(store.hosts.flatMap(\.allAgents).filter { !$0.isDispatcher }.prefix(2))
            for agent in agents { await store.load(agent.id) }
            ReadingOpeningRecording.last = nil
            ReadingOpeningRecording.unmounted = []
            ReadingOpeningRecording.handoffs = 0
            CompanionReadingOpeningProbe.didComputeSeed = { target in
                let saved = store.readingBookmark(for: target).position
                print("READING_OPEN_SEED time=\(Date().timeIntervalSince1970) target=\(target.agentID) entry=\(saved.entryID ?? "nil") distance=\(saved.distanceFromEntry) shown=\(saved.shownEntries) follow=\(saved.followsLatest ? 1 : 0)")
            }
            CompanionReadingOpeningProbe.record = { sample in
                ReadingOpeningRecording.last = sample
                if sample.phase == .handoff { ReadingOpeningRecording.handoffs += 1 }
                if sample.phase == .unmounted { ReadingOpeningRecording.unmounted.insert(sample.mountID) }
                print("READING_OPEN time=\(Date().timeIntervalSince1970) case=\(scenario) phase=\(sample.phase.rawValue) mount=\(sample.mountID) target=\(sample.target.agentID) follow=\(sample.followsLatest ? 1 : 0) shown=\(sample.shownEntries) id=\(sample.requestedEntryID ?? "nil") bottom=\(sample.requestedBottom ? 1 : 0) top=\(sample.requestedTop ? 1 : 0) start=\(sample.windowStartID ?? "nil") distance=\(sample.savedDistanceFromEntry) user=\(sample.positionedByUser ? 1 : 0) point=\(sample.pointY ?? -1) first=\(sample.windowFirstID ?? "nil") offset=\(sample.offset ?? -1) lower=\(sample.entryLowerBound ?? -1) latest=\(sample.latestVisible ? 1 : 0)")
            }
            scenario = "ready"
            defer {
                CompanionReadingOpeningProbe.record = nil
                CompanionReadingOpeningProbe.didComputeSeed = nil
                ReadingOpeningRecording.handoffs = 0
                ReadingOpeningRecording.last = nil
                ReadingOpeningRecording.unmounted = []
            }
            while !Task.isCancelled {
                let bookmark = target.map { store.readingBookmark(for: $0) }
                let sample = ReadingOpeningRecording.last
                let next = "case=\(scenario) mounted=\(mounted ? 1 : 0) visible=\(visible ? 1 : 0) target=\(target?.agentID ?? "nil") start=\(sample?.windowStartID ?? "nil") follow=\(bookmark?.position.followsLatest == true ? 1 : 0) entry=\(bookmark?.position.entryID ?? "nil") outcome=\(bookmark?.viewport.restoration?.outcome?.rawValue ?? "none") mount=\(sample?.mountID.uuidString ?? "none") user=\(sample?.positionedByUser == true ? 1 : 0) handoffs=\(ReadingOpeningRecording.handoffs)"
                if status != next { status = next }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    private func recordingControl(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }
    }

    /// Observe the actual outgoing lifecycle, including a native pop, before starting a different recording case.
    /// This is explicit fixture setup; no product mount waits or hides its first paint.
    private func closeCurrentMount() async -> Bool {
        let hadMount = mounted || presentsDestination
        let prior = ReadingOpeningRecording.last?.mountID
        mounted = false
        presentsDestination = false
        if hadMount {
            guard let prior else { scenario = "unmount-not-observed"; return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !ReadingOpeningRecording.unmounted.contains(prior), ProcessInfo.processInfo.systemUptime < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            }
            guard ReadingOpeningRecording.unmounted.contains(prior) else { scenario = "unmount-not-observed"; return false }
            // Explicit removal of a managed fixture root is not a production root-navigation path.
            if let target { store.readingBookmark(for: target).viewport.clearGeometry() }
        }
        return true
    }

    private func openPaused() async {
        guard let target, await closeCurrentMount() else { return }
        let bookmark = store.readingBookmark(for: target)
        bookmark.hasMounted = true
        bookmark.position = .init(followsLatest: false, entryID: "message:reading-90", distanceFromEntry: 0,
                                  offset: 0, shownEntries: 300)
        scenario = "paused-expanded"
        tab = 0
        mounted = true
    }

    private func openShortPaused() async {
        guard let target, await closeCurrentMount() else { return }
        store.apply(.timeline(target, items: [
            .message(.init(id: "before-short", role: .assistant, text: "Earlier short history.")),
            .message(.init(id: "short-bookmark", role: .assistant, text: "Short bookmark."))
        ], sequence: 1, reset: true, sessionID: "opening-short-session"))
        let bookmark = store.readingBookmark(for: target)
        bookmark.hasMounted = true
        bookmark.position = .init(followsLatest: false, entryID: "message:short-bookmark", shownEntries: 300)
        scenario = "short-paused"
        tab = 0
        mounted = true
    }

    private func replaceSession() {
        guard let target else { return }
        scenario = "session-replacement"
        let items: [CompanionTimelineItem] = (1...180).map {
            .message(.init(id: "new-session-\($0)", role: .assistant, text: "New session marker \($0)."))
        }
        store.apply(.timeline(target, items: items, sequence: 1, reset: true, sessionID: "reading-opening-new-session"))
    }
}

@MainActor private enum ReadingOpeningRecording {
    static var last: CompanionReadingOpeningProbe.Sample?
    static var unmounted: Set<UUID> = []
    static var handoffs = 0
}
#endif
