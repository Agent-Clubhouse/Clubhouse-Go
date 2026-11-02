import XCTest
import SwiftUI
import ClubhouseTransport
@testable import ClubhouseGo

/// Hosted by XCTest in the owned simulator. Captures body construction, not GPU frame rate.
@MainActor final class CompanionLongChatRenderingTests: XCTestCase {
    func testLongChatStreamingTypingAndReconnectFanout() async throws {
        // Let the host app finish its initial scene transition before adding a test-only, non-key window.
        try await Task.sleep(for: .seconds(2))
        let service = CompanionPreviewService(showsDispatcher: true)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.dispatcherTarget
        var hosts = CompanionPreviewService.hosts(now: Date(), dispatcher: true)
        store.apply(.hosts(hosts))
        await store.load(target)
        let items: [CompanionTimelineItem] = (1...5_000).map { i in
            .message(.init(id: "history-\(i)", role: .user, text: "[FROM:River] Update \(i)", source: "mcp",
                routed: [.init(sender: .init(agentID: "river", name: "River"), text: i % 20 == 0 ? String(repeating: "Long **folded** delivery.\n\n", count: 100) : "Update \(i)")]))
        }
        store.apply(.timeline(target, items: items, sequence: 5_000, reset: true, sessionID: "fixture"))
        let agent = try XCTUnwrap(hosts[0].dispatcher?.agent)
        let controller = UIHostingController(rootView: NavigationStack { CompanionConversationView(store: store, agent: agent) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; AnnexTelemetry.shared.setEnabled(false) }
        try await Task.sleep(for: .milliseconds(300))
        let telemetry = AnnexTelemetry.shared; telemetry.setEnabled(true)
        func report(_ phase: String) {
            for summary in telemetry.drainSummaries() {
                print("LONG_CHAT_RENDER phase=\(phase) operation=\(summary.operation.rawValue) count=\(summary.count) totalMs=\(summary.totalMs) maxMs=\(summary.maxMs) messages=\(summary.messageCount) textBytes=\(summary.textBytes)")
            }
        }
        for i in 1...40 {
            store.apply(.upsert(target, .message(.init(id: "reply", role: .assistant, text: String(repeating: "Stream **chunk**. ", count: i), isStreaming: true)), sequence: 5_000 + i))
            try await Task.sleep(for: .milliseconds(17))
        }
        report("stream")
        for i in 1...20 {
            store.drafts[target] = String(repeating: "x", count: i)
            try await Task.sleep(for: .milliseconds(17))
        }
        report("typing")
        let started = ContinuousClock.now
        // Separate completion turns mimic a reconnect's catalog fan-out; no live transport is contacted.
        for i in 0..<26 {
            hosts[0].name = "Fixture catalog \(i)"
            store.apply(.hosts(hosts))
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<2 { store.apply(.timeline(target, items: items, sequence: 6_000, reset: true, sessionID: "fixture")) }
        try await Task.sleep(for: .milliseconds(100))
        print("LONG_CHAT_RECONNECT fanout=26 histories=2 elapsed=\(started.duration(to: .now))")
        report("reconnect")
        XCTAssertEqual(store.conversation(for: target).items.count, 5_000)
        XCTAssertEqual(store.drafts[target], String(repeating: "x", count: 20))
    }
}
