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
    @Observable final class Navigation { var visible = true }
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
            if presented { presentedOffsets.append(presentation) }
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let viewport = bookmark.viewport
            let line = "RETURN_FRAME case=\(name) tick=\(tick) ms=\(ms) offset=\(offset) presentation=\(presentation) visible=\(visible) presented=\(presented) rect=\(rect) initialized=\(viewport.hasInitialized) restoring=\(viewport.isRestoring) outcome=\(viewport.restoration?.outcome?.rawValue ?? "pending")"
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

    private func measure(count: Int, fresh: Bool, remount: Bool = false) async throws {
        let service = ReturnFrameService(count: count)
        var store = CompanionStore(service: service)
        let target = CompanionPreviewService.target
        let hosts = CompanionPreviewService.hosts(now: .now)
        store.apply(.hosts(hosts))
        await store.load(target)
        let agent = try XCTUnwrap(hosts.flatMap(\.allAgents).first { $0.id == target })
        var bookmark = store.readingBookmark(for: target)
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
        }
        let scroll = try XCTUnwrap(Sampler.transcript(window))
        var saved = bookmark.position
        saved.followsLatest = false
        saved.capture(offset: 600, frames: bookmark.viewport.frames)
        XCTAssertNotNil(saved.entryID)
        bookmark.position = saved
        navigation.visible = false
        try await waitUntil("unmount geometry") { bookmark.viewport.metrics == nil }
        XCTAssertEqual(bookmark.position, saved)
        try await Task.sleep(for: .milliseconds(300))

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
        let name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(count)-\(fresh ? "fresh" : "cached")\(remount ? "-navigation" : "")"
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
        if !fresh {
            XCTAssertFalse(sampler.presentedOffsets.isEmpty, "A real presented transcript must be sampled")
            XCTAssertTrue(sampler.presentedOffsets.allSatisfy { abs($0 - saved.offset) <= 2 },
                          "No presented cached-history frame may show the bottom before restoration: \(sampler.presentedOffsets)")
        }
        XCTAssertEqual(bookmark.viewport.metrics?.normalizedOffset ?? -1, saved.offset, accuracy: 2)
        XCTAssertEqual(bookmark.position.offset, saved.offset, accuracy: 2)
        try await Task.sleep(for: .milliseconds(300))
    }
}
