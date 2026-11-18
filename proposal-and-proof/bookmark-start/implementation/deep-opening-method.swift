import Darwin

/// Identical additive main/head measurement. Opening CPU time is supporting data; work counts are the gate.
@MainActor final class CompanionReadingDeepOpeningCostTests: XCTestCase {
    private func processCPU() -> Double {
        var usage = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &usage), 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func testDeepPausedOpeningReportsWorkForTwoFreshMounts() async throws {
        var reports: [[String: Any]] = []
        for iteration in 0..<2 {
            let service = CompanionPreviewService(showsReadingScenario: true)
            let store = CompanionStore(service: service)
            var events = service.events().makeAsyncIterator()
            let initialEvent = await events.next()
            store.apply(try XCTUnwrap(initialEvent))
            let agent = try XCTUnwrap(store.hosts.flatMap(\.allAgents).first { $0.id == CompanionPreviewService.target })
            let target = agent.id
            let items: [CompanionTimelineItem] = (0..<600).map {
                .message(.init(id: "deep-\($0)", role: .assistant, text: "Deep reading marker \($0). A stable short paragraph."))
            }
            store.apply(.timeline(target, items: items, sequence: 1, reset: true, sessionID: "deep-opening-cost"))
            let bookmark = store.readingBookmark(for: target)
            bookmark.hasMounted = true
            bookmark.position = .init(followsLatest: false, entryID: "message:deep-60", distanceFromEntry: 40,
                                      shownEntries: CompanionTimelineWindow.pageSize)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 800, height: 1_000)
            var body = 0, timeline = 0
            var preparedRows: [Int] = []
            CompanionConversationBuildProbe.record = { kind, observed in
                guard observed == target else { return }
                switch kind { case .body: body += 1; case .timeline: timeline += 1 }
            }
            CompanionConversationBuildProbe.preparedRows = { observed, count in
                if observed == target { preparedRows.append(count) }
            }
            defer {
                CompanionConversationBuildProbe.preparedRows = nil
                CompanionConversationBuildProbe.record = nil
                window.isHidden = true
                window.rootViewController = nil
            }
            let cpu = processCPU(), start = ProcessInfo.processInfo.systemUptime
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                CompanionConversationView(store: store, agent: agent, isVisible: true)
            })
            window.makeKeyAndVisible()
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while bookmark.viewport.restoration?.outcome != .arrived, ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(bookmark.viewport.restoration?.outcome, .arrived)
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let frame = try XCTUnwrap(bookmark.viewport.frames["message:deep-60"])
            let offset = try XCTUnwrap(bookmark.viewport.metrics?.normalizedOffset)
            XCTAssertEqual(offset - frame.lowerBound, 40, accuracy: 6)
            XCTAssertEqual(preparedRows.count, timeline, "Every actual transcript window build must report its prepared rows")
            XCTAssertFalse(preparedRows.isEmpty)
            reports.append(["iteration": iteration, "rows": 600, "bookmarkIndex": 60,
                            "body": body, "timeline": timeline,
                            "preparedRowCount": preparedRows.max() ?? -1,
                            "preparedRowCountTotal": preparedRows.reduce(0, +), "preparedRowCountByBuild": preparedRows,
                            "processCPUSeconds": processCPU() - cpu,
                            "wallSeconds": ProcessInfo.processInfo.systemUptime - start])
            CompanionConversationBuildProbe.preparedRows = nil
            CompanionConversationBuildProbe.record = nil
            window.isHidden = true
            window.rootViewController = nil
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        print("READING_DEEP_OPEN_COST " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Deep paused opening work JSON"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
