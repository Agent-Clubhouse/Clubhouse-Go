import XCTest
import SwiftUI
import Vision
import ClubhouseTransport
@testable import ClubhouseGo

/// Real Root/TabView/NavigationStack owners, synthetic catalogs and in-memory service only.
@MainActor final class CompanionHomeVisibilityTests: XCTestCase {
    func testHiddenHomeDoesNoWorkDuring100RenderedDispatchUpdatesAndReturnsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        XCTAssertGreaterThan(fixture.counts[.layout, default: 0], 0, "Home really mounted first")
        XCTAssertEqual(fixture.counts[.layout], fixture.counts[.content], "One layout per visible content construction")
        fixture.select(.dispatcher)
        try await fixture.wait { !fixture.homeVisible && fixture.store.selection == fixture.dispatcher && fixture.chatBodies > 0 }
        let hidden = fixture.expensiveCounts
        for batch in 0..<10 {
            let rendered = fixture.chatBodies
            for chunk in 0..<10 {
                fixture.store.apply(.textDelta(fixture.dispatcher, messageID: "perf-stream", text: " x", sequence: batch * 10 + chunk + 1))
            }
            try await fixture.wait { fixture.chatBodies > rendered }
            XCTAssertEqual(fixture.expensiveCounts, hidden, "Rendered batch \(batch) must not build offscreen Home")
        }
        XCTAssertEqual(fixture.store.conversation(for: fixture.dispatcher).items.compactMap { item -> String? in
            if case .message(let message) = item, message.id == "perf-stream" { return message.text }; return nil
        }.first, "start" + String(repeating: " x", count: 100))
        XCTAssertEqual(fixture.store.conversation(for: fixture.dispatcher).lastSequence, 100)
        fixture.hosts[0].projects[0].agents[1].name = "Fresh title"
        fixture.hosts[0].projects[0].agents[1].status = .approval
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.turn()
        XCTAssertEqual(fixture.expensiveCounts, hidden, "A hidden host snapshot does not build Home either")
        fixture.select(.home)
        try await fixture.wait { fixture.group()?.agents.contains { $0.name == "Fresh title" } == true }
        XCTAssertEqual(fixture.group()?.liveStatus, .approval)
        XCTAssertTrue(try fixture.renderedText().contains("Fresh title"), "The returned Home must actually render the fresh title")
        XCTAssertTrue(fixture.projection?.projects.contains { $0.entry.isLinked } == true)
        XCTAssertEqual(fixture.counts[.layout], fixture.counts[.content])
        fixture.capture("Home fresh after 100 rendered Dispatch updates")
    }

    func testPushedHomeRouteAlsoStopsHomeWorkAndReturnsToTheSameScopeAndDisclosures() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let scope = try XCTUnwrap(fixture.scope)
        scope.wrappedValue = .host("synthetic-host-0")
        fixture.preferences.toggleFold("quiet:synthetic-host-0-project-8")
        try await fixture.wait { fixture.projection?.projects.allSatisfy { $0.entry.members.allSatisfy { $0.host.id == "synthetic-host-0" } } == true }
        let navigation = try XCTUnwrap(fixture.navigation)
        var next = navigation.wrappedValue
        next.setPath([.project(.init(hostID: "synthetic-host-0", projectID: "project-0"))], for: .home, hosts: fixture.store.hosts)
        navigation.wrappedValue = next
        try await fixture.turn()
        let before = fixture.expensiveCounts
        for chunk in 0..<10 {
            fixture.store.apply(.textDelta(fixture.dispatcher, messageID: "perf-stream", text: " route", sequence: chunk + 1))
            try await fixture.turn()
        }
        XCTAssertEqual(fixture.expensiveCounts, before, "Home's pushed Project page is not the Home root")
        next = navigation.wrappedValue
        XCTAssertEqual(next.paths[.home]?.count, 1, "Streaming cannot pop the pushed page")
        next.setPath([], for: .home, hosts: fixture.store.hosts)
        navigation.wrappedValue = next
        try await fixture.wait { fixture.counts[.content, default: 0] > before[.content, default: 0] }
        XCTAssertEqual(fixture.scope?.wrappedValue, .host("synthetic-host-0"))
        XCTAssertTrue(fixture.preferences.expandedFolds.contains("quiet:synthetic-host-0-project-8"))
        XCTAssertTrue(fixture.projection?.projects.allSatisfy { $0.entry.members.allSatisfy { $0.host.id == "synthetic-host-0" } } == true)
    }

    func testRecentOrderStaysWhileVisibleThenRefreshesOnReturn() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let original = try XCTUnwrap(fixture.group()).agents.map(\.id)
        let changed = fixture.hosts[0].projects[0].agents[2].id
        fixture.hosts[0].projects[0].agents[2].status = .approval
        fixture.hosts[0].projects[0].agents[2].lastActivity = Date(timeIntervalSince1970: 1_900_000_001)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.agents.first(where: { $0.id == changed })?.status == .approval }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original)
        XCTAssertEqual(fixture.group()?.liveStatus, .approval)
        let newcomer = CompanionAgent(id: .init(hostID: "synthetic-host-0", projectID: "project-0", agentID: "new-peer"),
            name: "New synthetic peer", subtitle: "Generated task", status: .working, lastActivity: Date(timeIntervalSince1970: 1_900_000_002))
        fixture.hosts[0].projects[0].agents.append(newcomer)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.agents.contains { $0.id == newcomer.id } == true }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original + [newcomer.id])
        fixture.hosts[0].projects[0].agents.removeAll { $0.id == changed }
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.agents.contains { $0.id == changed } == false }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original.filter { $0 != changed } + [newcomer.id])
        fixture.select(.dispatcher)
        try await fixture.wait { fixture.store.selection == fixture.dispatcher }
        fixture.select(.home)
        try await fixture.wait { fixture.group()?.agents.first?.id == newcomer.id }
        XCTAssertEqual(fixture.counts[.layout], fixture.counts[.content])
    }

    func testRealListScrollAnchorRestoresAfterDispatchWithoutResettingScope() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let anchor = try XCTUnwrap(fixture.anchor)
        let list = try XCTUnwrap(fixture.list(in: fixture.window))
        XCTAssertGreaterThan(list.contentSize.height, list.bounds.height * 2)
        list.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        try await fixture.wait { anchor.bookmark?.id != nil && anchor.bookmark?.id != .summary && anchor.bookmark?.id != .desktops }
        let saved = try XCTUnwrap(anchor.bookmark)
        let frame = try XCTUnwrap(anchor.testFrames[saved.id])
        XCTAssertTrue(frame.intersects(anchor.testViewport), "The saved anchor is a real visible List row")
        fixture.select(.dispatcher)
        try await fixture.wait { fixture.store.selection == fixture.dispatcher }
        fixture.select(.home)
        try await fixture.wait { !anchor.testRestoring && anchor.testFrames[saved.id]?.intersects(anchor.testViewport) == true }
        XCTAssertTrue(fixture.anchor === anchor, "The Home state owner survives the hidden subtree")
        XCTAssertGreaterThan(try XCTUnwrap(fixture.list(in: fixture.window)).contentOffset.y, 0, "Return cannot silently reset to the top")
        fixture.capture("Home restores an explicit row anchor")
    }

    @MainActor private final class Fixture {
        let service: HomeVisibilityService
        let store: CompanionStore
        let defaults: UserDefaults
        let suite: String
        let preferences: CompanionPreferences
        let window: UIWindow
        let previous: UIWindow?
        let dispatcher = CompanionTarget(hostID: "synthetic-host-0", projectID: CompanionDispatcher.defaultProjectID, agentID: "synthetic-dispatcher")
        var hosts = CompanionLargeCatalogFixture.hosts(hostCount: 4, projectsPerHost: 24, agentsPerProject: 12)
        var navigation: Binding<CompanionNavigation>?
        var scope: Binding<CompanionDesktopSelection>?
        var anchor: CompanionHomeScrollAnchorState?
        var projection: CompanionHomeLayout?
        var counts: [CompanionHomeBuildProbe.Kind: Int] = [:]
        var chatBodies = 0
        var homeVisible = false
        var expensiveCounts: [CompanionHomeBuildProbe.Kind: Int] { counts.filter { $0.key != .owner } }

        init() throws {
            let service = HomeVisibilityService()
            let suite = "home-visibility-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            self.service = service
            self.suite = suite
            self.defaults = defaults
            store = CompanionStore(service: service)
            preferences = CompanionPreferences(defaults: defaults, systemDeviceName: "Synthetic performance fixture")
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            var dispatcherAgent = CompanionAgent(id: dispatcher, name: "Synthetic Dispatcher", subtitle: "Generated stream", status: .working, capabilities: [.chat, .cancel])
            dispatcherAgent.isDispatcher = true
            hosts[0].dispatcher = .init(enabled: true, flagOn: true, agent: dispatcherAgent)
            store.apply(.hosts(hosts))
        }

        func mount() async throws {
            await store.load(dispatcher)
            CompanionHomeBuildProbe.visibility = { [weak self] in self?.homeVisible = $0 }
            CompanionHomeBuildProbe.record = { [weak self] in self?.counts[$0, default: 0] += 1 }
            CompanionHomeBuildProbe.projection = { [weak self] in self?.projection = $0 }
            CompanionHomeBuildProbe.navigation = { [weak self] in self?.navigation = $0 }
            CompanionHomeBuildProbe.state = { [weak self] anchor, scope in self?.anchor = anchor; self?.scope = scope }
            CompanionConversationBuildProbe.record = { [weak self] kind, target in
                guard case .body = kind, target == self?.dispatcher else { return }
                self?.chatBodies += 1
            }
            window.rootViewController = UIHostingController(rootView: CompanionRootView(store: store, preferences: preferences,
                onPair: {}, onSettings: {}).companionTheme(.clubhouse))
            window.makeKeyAndVisible()
            try await wait { self.navigation != nil && self.anchor != nil && self.counts[.header, default: 0] > 0 && self.counts[.quiet, default: 0] > 0 }
            try await turn()
        }

        func group() -> CompanionProjectGroup? { projection?.projects.first { $0.entry.linkID == "synthetic-link-0" } }

        func select(_ tab: CompanionTab) {
            guard let navigation else { XCTFail("Root navigation must be mounted"); return }
            var next = navigation.wrappedValue
            _ = next.selectFromTabBar(tab)
            navigation.wrappedValue = next
        }

        func turn() async throws {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.layoutIfNeeded()
        }

        func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline {
                try await turn()
                try await Task.sleep(for: .milliseconds(20)) // Condition polling, never an action retry.
            }
            XCTAssertTrue(condition(), "Mounted rendering condition did not arrive", file: file, line: line)
        }

        func list(in view: UIView) -> UICollectionView? {
            (view as? UICollectionView) ?? view.subviews.lazy.compactMap { list(in: $0) }.first
        }

        func renderedText() throws -> String {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
        }

        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: name) { $0.add(attachment) }
        }

        func close() {
            CompanionHomeBuildProbe.visibility = nil
            CompanionHomeBuildProbe.record = nil; CompanionHomeBuildProbe.projection = nil
            CompanionHomeBuildProbe.navigation = nil; CompanionHomeBuildProbe.state = nil
            CompanionConversationBuildProbe.record = nil
            navigation = nil; scope = nil; anchor = nil; projection = nil
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor private final class HomeVisibilityService: CompanionService {
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        .init(items: [.message(.init(id: "perf-stream", role: .assistant, text: "start", timestamp: Date(timeIntervalSince1970: 1_800_000_000), isStreaming: true))],
              lastSequence: 0, sessionID: "synthetic-session")
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { XCTFail("No sends in performance tests"); return .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { XCTFail("No cancel in performance tests") }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { XCTFail("No decisions in performance tests") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { XCTFail("No spawn in performance tests"); return .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
}
