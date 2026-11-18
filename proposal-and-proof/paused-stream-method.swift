import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

/// Identical additive overlay on main and head. Uncredited performance measurement, not a new tolerance.
@MainActor final class CompanionReadingPausedCostTests: XCTestCase {
    func testPausedStreamingReportsPerBatchConversationWork() async throws {
        let service = CompanionPreviewService(showsReadingScenario: true)
        let store = CompanionStore(service: service)
        var events = service.events().makeAsyncIterator()
        let next = await events.next()
        store.apply(try XCTUnwrap(next))
        let agent = try XCTUnwrap(store.hosts.flatMap(\.allAgents).first { !$0.isDispatcher })
        let target = agent.id
        await store.load(target)
        let bookmark = store.readingBookmark(for: target)
        bookmark.hasMounted = true
        bookmark.position = .init(followsLatest: false, entryID: "message:reading-90", distanceFromEntry: 0,
                                  offset: 0, shownEntries: 300)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        var body = 0, timeline = 0
        CompanionConversationBuildProbe.record = { kind, observed in
            guard observed == target else { return }
            switch kind { case .body: body += 1; case .timeline: timeline += 1 }
        }
        defer {
            CompanionConversationBuildProbe.record = nil
            window.isHidden = true
            window.rootViewController = nil
        }
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            CompanionConversationView(store: store, agent: agent, isVisible: true)
        })
        window.makeKeyAndVisible()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while bookmark.viewport.restoration?.outcome != .arrived, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(bookmark.viewport.restoration?.outcome, .arrived, "The real product must arrive before measuring")
        try await Task.sleep(for: .milliseconds(250))
        var samples: [[String: Int]] = []
        for batch in 0..<10 {
            let beforeBody = body, beforeTimeline = timeline
            for _ in 0..<10 { store.apply(.textDelta(target, messageID: "reading-helper", text: " streamed", sequence: nil)) }
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            window.layoutIfNeeded()
            XCTAssertFalse(bookmark.position.followsLatest)
            samples.append(["batch": batch, "chunks": 10, "body": body - beforeBody, "timeline": timeline - beforeTimeline])
        }
        let report: [String: Any] = ["uncredited": true, "samples": samples, "chunks": 100,
                                    "notes": "Paused actual transcript, identical fixture on main/head, 10 separately rendered batches; compare body/timeline batch by batch. Per-mount seed/slicing count proven separately on the production head."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print("READING_PAUSED_COST " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Paused streaming conversation work JSON"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
