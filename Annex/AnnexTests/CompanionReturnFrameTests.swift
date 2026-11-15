import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

@MainActor private final class ReturnFrameService: CompanionService {
    nonisolated deinit {}
    let preview = CompanionPreviewService()
    let count: Int
    var held = false
    var requested = false

    init(count: Int) { self.count = count }
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        requested = true
        while held { try await Task.sleep(for: .milliseconds(10)) }
        return .init(items: (1...count).map { index in
            .message(.init(id: "return-\(index)", role: .assistant,
                text: "RETURN MARKER \(index)\n\n" + String(repeating: "Marker \(index): a stable paragraph identifies this reading position without a desktop connection. ", count: 8)))
        })
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
}

@MainActor final class CompanionReturnFrameTests: XCTestCase {
    @Observable final class Navigation {
        var visible = true
        var textSize = DynamicTypeSize.large
        var horizontalInset: CGFloat = 0
        var customFont: Font?
    }
    private struct Fixture: View {
        let store: CompanionStore
        let agent: CompanionAgent
        @Bindable var navigation: Navigation
        var body: some View {
            TabView(selection: $navigation.visible) {
                Tab("Chat", systemImage: "bubble", value: true) {
                    NavigationStack {
                        CompanionConversationView(store: store, agent: agent, showsActions: navigation.visible,
                                                  isVisible: navigation.visible)
                    }
                }
                Tab("Home", systemImage: "house", value: false) { Text("HOME - TRANSCRIPT UNMOUNTED") }
            }
            .companionTheme(.clubhouse)
            .dynamicTypeSize(navigation.textSize)
            .padding(.horizontal, navigation.horizontalInset)
            .font(navigation.customFont)
        }
    }

    @MainActor private final class Sampler: NSObject {
        weak var window: UIWindow?
        let bookmark: CompanionReadingBookmark
        let label: UILabel
        let name: String
        let started = ProcessInfo.processInfo.systemUptime
        var link: CADisplayLink?
        var lines: [String] = []
        var tick = 0
        var presentedOffsets: [Double] = []
        var presentedMaximumOffsets: [Double] = []
        var presentedEntryOffsets: [Double] = []
        var presentedScrollIdentities: [ObjectIdentifier] = []
        var readingPosition: CompanionReadingPosition?

        init(window: UIWindow, bookmark: CompanionReadingBookmark, label: UILabel, name: String) {
            self.window = window
            self.bookmark = bookmark
            self.label = label
            self.name = name
        }
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(sample))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        func stop() { link?.invalidate(); link = nil }
        @objc private func sample() {
            guard let window else { return }
            tick += 1
            let scroll = Self.transcript(window)
            let offset = scroll.map { $0.contentOffset.y + $0.adjustedContentInset.top } ?? -1
            let presentation = scroll.map { ($0.layer.presentation()?.bounds.minY ?? -1) + $0.adjustedContentInset.top } ?? -1
            var visible = scroll != nil && window.isKeyWindow && !window.isHidden
            var presented = visible
            var ancestor: UIView? = scroll
            while let view = ancestor {
                visible = visible && !view.isHidden && view.alpha > 0.01
                presented = presented && !view.isHidden && (view.layer.presentation()?.opacity ?? 0) > 0.01
                ancestor = view.superview
            }
            let rect = scroll.map { $0.convert($0.bounds, to: window).intersection(window.bounds) } ?? .zero
            visible = visible && !rect.isEmpty
            presented = presented && !rect.isEmpty && presentation >= 0
            if presented, let scroll {
                presentedOffsets.append(presentation)
                presentedMaximumOffsets.append(max(0, scroll.contentSize.height + scroll.adjustedContentInset.top
                    + scroll.adjustedContentInset.bottom - scroll.bounds.height))
                presentedEntryOffsets.append(readingPosition?.restoredOffset(frames: bookmark.viewport.frames) ?? -1)
                presentedScrollIdentities.append(ObjectIdentifier(scroll))
            }
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let viewport = bookmark.viewport
            let line = "RETURN_FRAME case=\(name) tick=\(tick) ms=\(ms) offset=\(offset) presentation=\(presentation) maximum=\(presentedMaximumOffsets.last ?? -1) entryOffset=\(presentedEntryOffsets.last ?? -1) width=\(scroll?.bounds.width ?? 0) visible=\(visible) presented=\(presented) rect=\(rect) initialized=\(viewport.hasInitialized) restoring=\(viewport.isRestoring) outcome=\(viewport.restoration?.outcome?.rawValue ?? "pending")"
            lines.append(line)
            label.text = "\(name) #\(tick) \(Int(ms))ms y=\(Int(offset))"
        }
        static func transcript(_ view: UIView) -> UIScrollView? {
            if view.isHidden || view.alpha < 0.01 { return nil }
            if let scroll = view as? UIScrollView, scroll.bounds.width > 300,
               scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap(transcript).first
        }
    }

    private func waitUntil(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "The real-window return fixture must settle: \(stage)")
    }

    func testCachedReturnNeverPresentsTheBottomAndFreshHistoryStillRestores() async throws {
        for count in [12, 100] {
            for fresh in [false, true] {
                try await measure(count: count, fresh: fresh)
            }
        }
    }

    func testCachedNavigationRemountNeverPresentsTheBottom() async throws {
        try await measure(count: 12, fresh: false, remount: true)
    }

    func testHiddenAppendDoesNotPresentAnOffsetFromTheOldWindow() async throws {
        for remount in [false, true] {
            try await measure(count: 200, fresh: false, remount: remount, hiddenMutation: .append)
        }
    }

    func testHiddenHistoryRevisionDoesNotPresentAnOffsetFromTheOldLayout() async throws {
        for remount in [false, true] {
            try await measure(count: 12, fresh: false, remount: remount, hiddenMutation: .historyPrefix)
        }
    }

    func testHiddenSessionReplacementDoesNotSeedAReusedEntryID() async throws {
        try await measure(count: 12, fresh: false, hiddenMutation: .session)
    }

    func testHiddenDynamicTypeChangeDoesNotSeedThePriorLayout() async throws {
        try await measure(count: 12, fresh: false, hiddenMutation: .dynamicType)
    }

    func testHiddenWidthChangeDoesNotSeedThePriorLayout() async throws {
        for remount in [false, true] {
            try await measure(count: 12, fresh: false, remount: remount, hiddenMutation: .width)
        }
    }

    func testRejectedSeedKeepsTheExpandedWindowFromTheFirstFrame() async throws {
        try await measure(count: 200, fresh: false, remount: true, hiddenMutation: .append,
                          priorShownEntries: 300, savedOffset: 12_000)
    }

    func testUnknownTypographyUsesTheBottomFallback() async throws {
        try await measure(count: 12, fresh: false, hiddenMutation: .customFont)
    }

    func testLiveWidthAndTypeChangesKeepTheNativeReaderAndComposer() async throws {
        try await measureLiveLayout(rotate: false, following: false)
    }

    func testLiveRotationKeepsTheNativeReaderAndComposer() async throws {
        try await measureLiveLayout(rotate: true, following: false)
    }

    func testLiveRotationKeepsTheStreamingFollowerAndComposerMounted() async throws {
        try await measureLiveLayout(rotate: true, following: true)
    }

    private func measureLiveLayout(rotate: Bool, following: Bool) async throws {
        try XCTSkipIf(rotate && UIDevice.current.userInterfaceIdiom == .pad,
                      "Windowed iPad hosted scenes reject public rotation with UISceneError 101; live width/type is covered separately")
        let service = ReturnFrameService(count: 200)
        let store = CompanionStore(service: service)
        let target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts))
        await store.load(target)
        store.drafts[target] = "Keep this live-layout draft and caret"
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        let bookmark = store.readingBookmark(for: target)
        let navigation = Navigation()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: Fixture(store: store, agent: agent, navigation: navigation))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil("live layout initialized") {
            bookmark.viewport.hasInitialized && bookmark.viewport.metrics?.isAtTrueBottom == true
        }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(Sampler.transcript(window))
        func input(in view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap { input(in: $0) }.first
        }
        let composer = try XCTUnwrap(input(in: window))
        XCTAssertTrue(composer.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(400))
        let selection = NSRange(location: 5, length: 4)
        composer.selectedRange = selection
        if !following {
            scroll.setContentOffset(CGPoint(x: 0, y: 600 - scroll.adjustedContentInset.top), animated: false)
            try await waitUntil("live reader captured") {
                !bookmark.position.followsLatest && abs(bookmark.position.offset - 600) <= 2
            }
        }
        let saved = bookmark.position
        let restorationID = bookmark.viewport.restoration?.id
        let label = UILabel(frame: CGRect(x: 4, y: window.safeAreaInsets.top, width: 300, height: 22))
        window.addSubview(label)
        let name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-live-\(rotate ? "rotation" : "width-type")-\(following ? "following" : "reading")"
        let sampler = Sampler(window: window, bookmark: bookmark, label: label, name: name)
        sampler.readingPosition = saved
        sampler.start()
        defer { sampler.stop() }
        store.apply(.textDelta(target, messageID: "return-200", text: "\n\nA streaming chunk remains in flight during layout.", sequence: nil))
        if rotate {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                XCTFail("The owned scene must rotate: \(error)")
            }
            try await waitUntil("landscape geometry") { scene.interfaceOrientation.isLandscape }
        } else {
            navigation.horizontalInset = 30
        }
        try await Task.sleep(for: .milliseconds(700))
        if !rotate {
            navigation.textSize = .accessibility1
            try await Task.sleep(for: .milliseconds(700))
        }
        sampler.stop()
        let attachment = XCTAttachment(string: sampler.lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(sampler.presentedOffsets.isEmpty)
        XCTAssertEqual(Set(sampler.presentedScrollIdentities), [ObjectIdentifier(scroll)], "Live reflow must not remount the transcript")
        XCTAssertEqual(bookmark.viewport.restoration?.id, restorationID, "Live reflow must not restart initial restoration")
        // Live reflow offsets have a separate baseline defect (#422); this test protects mounted ownership.
        XCTAssertEqual(bookmark.position.followsLatest, following)
        XCTAssertTrue(composer === input(in: window))
        XCTAssertTrue(composer.isFirstResponder)
        XCTAssertEqual(composer.text, "Keep this live-layout draft and caret")
        XCTAssertEqual(composer.selectedRange, selection)
        if case .message(let message) = store.conversation(for: target).items.last {
            XCTAssertTrue(message.isStreaming)
            XCTAssertTrue(message.text.contains("remains in flight"))
        } else { XCTFail("The in-flight reply must survive live layout") }
        XCTAssertTrue(scroll.delegate?.scrollViewShouldScrollToTop?(scroll) == true)
        XCTAssertFalse(bookmark.position.followsLatest, "Native top must still take ownership after live layout")
        try await waitUntil("native top after live layout") {
            abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) <= 1
        }
        XCTAssertTrue(scroll === Sampler.transcript(window))
        XCTAssertTrue(composer.isFirstResponder)
        XCTAssertEqual(composer.text, "Keep this live-layout draft and caret")
        XCTAssertEqual(composer.selectedRange, selection)
        if rotate {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
                XCTFail("The owned scene must restore portrait: \(error)")
            }
            try await waitUntil("portrait cleanup") { scene.interfaceOrientation.isPortrait }
        }
    }

    private enum HiddenMutation: String { case append, historyPrefix, session, dynamicType, width, customFont }

    private func measure(count: Int, fresh: Bool, remount: Bool = false, hiddenMutation: HiddenMutation? = nil,
                         priorShownEntries: Int? = nil, savedOffset: Double = 600) async throws {
        let service = ReturnFrameService(count: count)
        var store = CompanionStore(service: service)
        let target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts))
        await store.load(target)
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        var bookmark = store.readingBookmark(for: target)
        if let priorShownEntries {
            bookmark.position.shownEntries = priorShownEntries
            bookmark.hasMounted = true
        }
        let initialFrameCount = CompanionTimelineWindow(rows: store.timelineRows(for: target),
            limit: priorShownEntries ?? CompanionTimelineWindow.pageSize).entries.count
        let navigation = Navigation()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: Fixture(store: store, agent: agent, navigation: navigation))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil("initial layout") {
            bookmark.viewport.hasInitialized && bookmark.viewport.metrics != nil
                && abs((bookmark.viewport.metrics?.contentHeight ?? -1) - (bookmark.viewport.frameContentHeight ?? -2)) < 1
                && bookmark.viewport.frames.count == initialFrameCount
        }
        if let priorShownEntries { XCTAssertEqual(bookmark.position.shownEntries, priorShownEntries) }
        let scroll = try XCTUnwrap(Sampler.transcript(window))
        try await Task.sleep(for: .milliseconds(300))
        scroll.setContentOffset(CGPoint(x: 0, y: savedOffset - scroll.adjustedContentInset.top), animated: false)
        try await waitUntil("accepted reading geometry") {
            !bookmark.position.followsLatest && abs(bookmark.position.offset - savedOffset) <= 2
                && bookmark.coordinateContext != nil
        }
        let capturedContext = try XCTUnwrap(bookmark.coordinateContext)
        XCTAssertNotNil(capturedContext.layout, "The standard fixture must establish known layout provenance")
        var saved = bookmark.position
        saved.followsLatest = false
        saved.capture(offset: savedOffset, frames: bookmark.viewport.frames)
        XCTAssertNotNil(saved.entryID)
        bookmark.position = saved
        bookmark.coordinateContext = capturedContext
        navigation.visible = false
        try await waitUntil("unmount geometry") { bookmark.viewport.metrics == nil }
        XCTAssertEqual(bookmark.position, saved)
        try await Task.sleep(for: .milliseconds(300))

        if hiddenMutation == .dynamicType {
            navigation.textSize = .accessibility1
        } else if hiddenMutation == .width {
            // The iPad fixture needs a larger reduction to cross a paragraph's wrapping boundary.
            navigation.horizontalInset = UIDevice.current.userInterfaceIdiom == .pad ? 120 : 30
        } else if hiddenMutation == .customFont {
            navigation.customFont = .largeTitle
        } else if hiddenMutation == .append {
            for index in (count + 1)...(count + 10) {
                store.apply(.upsert(target, .message(.init(id: "return-\(index)", role: .assistant,
                    text: "RETURN MARKER \(index)\n\n" + String(repeating: "An additional hidden message changes the newest-entry window. ", count: 8))), sequence: nil))
            }
        } else if hiddenMutation != nil {
            var items = store.conversation(for: target).items
            if case .message(var message) = items[0] {
                message.text += String(repeating: "\n\nA refreshed older paragraph changes geometry above the saved entry.", count: 20)
                items[0] = .message(message)
            }
            store.apply(.timeline(target, items: items, sequence: 1_000, reset: true,
                sessionID: hiddenMutation == .session ? "replacement-session" : nil))
        }
        if hiddenMutation != nil { try await Task.sleep(for: .milliseconds(50)) }

        var reload: Task<Void, Never>?
        if remount {
            window.rootViewController = UIHostingController(rootView: Fixture(store: store, agent: agent, navigation: navigation))
            try await Task.sleep(for: .milliseconds(50))
        }
        if fresh {
            store = CompanionStore(service: service)
            store.apply(.hosts(hosts))
            bookmark = store.readingBookmark(for: target)
            bookmark.position = saved
            bookmark.hasMounted = true
            window.rootViewController = UIHostingController(rootView: Fixture(store: store, agent: agent, navigation: navigation))
            try await Task.sleep(for: .milliseconds(50))
            service.requested = false
            service.held = true
            reload = Task { await store.load(target, force: true) }
            try await waitUntil("fresh history request") { service.requested }
        }
        defer { service.held = false; reload?.cancel() }
        let historyState = hiddenMutation == nil ? (fresh ? "fresh" : "cached") : "changed"
        let name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(count)-\(historyState)\(remount ? "-navigation" : "")\(hiddenMutation.map { "-\($0.rawValue)" } ?? "")\(priorShownEntries.map { "-window\($0)" } ?? "")"
        let label = UILabel(frame: CGRect(x: 4, y: window.safeAreaInsets.top + 2, width: window.bounds.width - 8, height: 22))
        label.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        label.backgroundColor = .yellow
        label.textColor = .black
        label.text = name + " waiting for first tick"
        window.addSubview(label)
        let sampler = Sampler(window: window, bookmark: bookmark, label: label, name: name)
        sampler.start()
        defer { sampler.stop() }
        print("RETURN_START case=\(name) uptime=\(sampler.started) saved=\(saved.offset) height=\(scroll.contentSize.height) screen=\(window.bounds)")
        navigation.visible = true
        try await Task.sleep(for: .milliseconds(300))
        service.held = false
        await reload?.value
        try await waitUntil("completed restoration") {
            bookmark.viewport.hasInitialized && !bookmark.viewport.isRestoring
                && bookmark.viewport.restoration?.outcome == .arrived
        }
        try await Task.sleep(for: .milliseconds(300))
        sampler.stop()
        for line in sampler.lines { print(line) }
        let attachment = XCTAttachment(string: sampler.lines.joined(separator: "\n"))
        attachment.name = name + "-display-link"
        attachment.lifetime = .keepAlways
        add(attachment)
        let expected = hiddenMutation == nil ? saved.offset : saved.restoredOffset(frames: bookmark.viewport.frames)
        if !fresh {
            XCTAssertFalse(sampler.presentedOffsets.isEmpty, "A real presented transcript must be sampled")
            if hiddenMutation == nil {
                XCTAssertTrue(sampler.presentedOffsets.allSatisfy { abs($0 - expected) <= 2 },
                              "No unchanged cached-history frame may show the bottom before restoration: \(sampler.presentedOffsets)")
            } else {
                if priorShownEntries == nil {
                    XCTAssertNotEqual(saved.offset, expected, accuracy: 2, "The mutation must move the saved entry")
                }
                XCTAssertTrue(zip(sampler.presentedOffsets, sampler.presentedMaximumOffsets).allSatisfy { offset, maximum in
                    abs(offset - expected) <= 2 || abs(offset - maximum) <= 2
                }, "Changed coordinates must use the current entry or bottom fallback, never stale saved-y: \(sampler.presentedOffsets); expected=\(expected)")
                print("RETURN_CONTEXT case=\(name) entry=\(saved.entryID ?? "nil") oldOffset=\(saved.offset) expected=\(expected) presented=\(sampler.presentedOffsets) maximum=\(sampler.presentedMaximumOffsets)")
            }
        }
        XCTAssertEqual(bookmark.viewport.metrics?.normalizedOffset ?? -1, expected, accuracy: 2)
        XCTAssertEqual(bookmark.position.offset, expected, accuracy: 2)
        XCTAssertFalse(bookmark.position.followsLatest, "A temporary fallback must preserve the reader's choice")
        try await Task.sleep(for: .milliseconds(300))
    }
}
