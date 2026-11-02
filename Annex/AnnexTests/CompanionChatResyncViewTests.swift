import XCTest
import SwiftUI
import Observation
import ClubhouseTransport
@testable import ClubhouseGo

@MainActor private final class ResyncCountingService: CompanionService {
    let preview = CompanionPreviewService(showsDispatcher: true)
    var reads = 0
    let items = (1...5_000).map { CompanionTimelineItem.message(.init(id: "m\($0)", role: .user, text: "History \($0)")) }
    func events() -> AsyncStream<CompanionEvent> { preview.events() }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        reads += 1
        // Keeps the loading flag observable while both real view hooks get a chance to run.
        try await Task.sleep(for: .milliseconds(50))
        return .init(items: items, lastSequence: 5_000, sessionID: "fixture")
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
}

@MainActor @Observable private final class ResyncNavigation {
    var open = false
    var phase = ScenePhase.active
}
@MainActor private struct ResyncNavigationView: View {
    let store: CompanionStore
    let agent: CompanionAgent
    @Bindable var navigation: ResyncNavigation
    var body: some View {
        NavigationStack {
            Text("Fixture navigation")
                .navigationDestination(isPresented: $navigation.open) { CompanionConversationView(store: store, agent: agent) }
        }
        .environment(\.scenePhase, navigation.phase)
    }
}

/// Drives the actual navigation destination and view hooks with the store states emitted at foreground.
/// The 50 ms read is synthetic; request counts/body counts are evidence, not real network timings.
@MainActor final class CompanionChatResyncViewTests: XCTestCase {
    func testNavigationAndForegroundResyncRequestCounts() async throws {
        guard #available(iOS 26.1, *) else {
            throw XCTSkip("iOS 26.0 actor-isolated deinit abort (#218); this resync measurement runs on newer runtimes, including CI iOS 26.5")
        }
        try await Task.sleep(for: .seconds(2))
        let service = ResyncCountingService(), navigation = ResyncNavigation()
        let store = CompanionStore(service: service), target = CompanionPreviewService.dispatcherTarget
        var hosts = CompanionPreviewService.hosts(now: Date(), dispatcher: true)
        store.apply(.hosts(hosts)); await store.load(target)
        let agent = try XCTUnwrap(hosts[0].dispatcher?.agent)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let controller = UIHostingController(rootView: ResyncNavigationView(store: store, agent: agent, navigation: navigation))
        LongChatMeasurementLifetime.retain([service, store, controller, navigation])
        window.rootViewController = controller
        window.isHidden = false
        let telemetry = AnnexTelemetry.shared; telemetry.setEnabled(true)
        defer { window.isHidden = true; window.rootViewController = nil; telemetry.setEnabled(false) }
        func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
        func report(_ phase: String, before: Int) {
            let summaries = telemetry.drainSummaries()
            let body = summaries.first { $0.operation == .conversationBody }
            let rows = summaries.first { $0.operation == .messageBody }
            print("LONG_CHAT_VIEW_RESYNC phase=\(phase) requests=\(service.reads - before) conversationBodies=\(body?.count ?? 0) messageBodies=\(rows?.count ?? 0) bodyMs=\(body?.totalMs ?? 0) retained=\(store.conversation(for: target).items.count)")
        }
        var before = service.reads
        navigation.open = true; try await settle()
        report("navigation-loaded", before: before)
        before = service.reads
        navigation.phase = .background
        hosts[0].connection = .offline
        store.apply(.resyncRequired(hostID: target.hostID)); store.apply(.hosts(hosts)); try await settle()
        navigation.phase = .active
        hosts[0].connection = .synchronizing; store.apply(.hosts(hosts)); await Task.yield()
        hosts[0].connection = .connected; store.apply(.hosts(hosts)); try await settle()
        report("foreground-open", before: before)
        before = service.reads
        navigation.open = false; try await settle()
        store.apply(.resyncRequired(hostID: target.hostID))
        hosts[0].connection = .synchronizing; store.apply(.hosts(hosts))
        navigation.open = true
        hosts[0].connection = .connected; store.apply(.hosts(hosts)); try await settle()
        report("navigation-and-reconnect", before: before)
        XCTAssertEqual(store.conversation(for: target).items.count, 5_000)
        XCTAssertFalse(store.conversation(for: target).requiresResync)
    }
}
