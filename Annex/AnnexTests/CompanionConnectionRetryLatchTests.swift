import XCTest
import SwiftUI
import UIKit
@testable import ClubhouseGo

@MainActor final class CompanionConnectionRetryLatchTests: XCTestCase {
    func testDoubleTapIssuesOneReconnectUntilTheAttemptFinishes() async throws {
        try await withBanner(hosts: hosts("one")) { store, service, window in
            let button = try XCTUnwrap(self.find("test-retry-one", in: window))
            XCTAssertTrue(button.accessibilityActivate())
            _ = button.accessibilityActivate() // Before SwiftUI has rendered the disabled state.
            try await self.waitUntil { service.calls["one"] == 1 && self.disabled("test-retry-one", in: window) }
            XCTAssertEqual(service.pendingCount, 1)
            self.capture(window, "Retry is disabled while one reconnect is held")
            service.finishFirst("one")
            try await self.waitUntil { self.enabled("test-retry-one", in: window) }
            XCTAssertTrue(try XCTUnwrap(self.find("test-retry-one", in: window)).accessibilityActivate())
            try await self.waitUntil { service.calls["one"] == 2 }
            XCTAssertEqual(service.pendingCount, 1)
        }
    }

    func testReportedStateClearsTheLatchAndAnOldCompletionCannotClearANewerAttempt() async throws {
        try await withBanner(hosts: hosts("one")) { store, service, window in
            XCTAssertTrue(try XCTUnwrap(self.find("test-retry-one", in: window)).accessibilityActivate())
            try await self.waitUntil { service.calls["one"] == 1 && self.disabled("test-retry-one", in: window) }
            self.report(.reconnecting, hostID: "one", store: store)
            try await self.waitUntil { self.find("test-retry-one", in: window) == nil }
            self.report(.offline, hostID: "one", store: store)
            try await self.waitUntil { self.find("test-retry-one", in: window) != nil && self.enabled("test-retry-one", in: window) }
            XCTAssertTrue(try XCTUnwrap(self.find("test-retry-one", in: window)).accessibilityActivate())
            try await self.waitUntil { service.calls["one"] == 2 && self.disabled("test-retry-one", in: window) }
            service.finishFirst("one") // Completion from before the reported connection transitions.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(self.disabled("test-retry-one", in: window), "The second held attempt owns the latch")
            XCTAssertEqual(service.pendingCount, 1)
            service.finishFirst("one")
            try await self.waitUntil { self.enabled("test-retry-one", in: window) }
        }
    }

    func testCombinedRetryLatchesEachHostWithoutBlockingANewOfflineHost() async throws {
        var initial = hosts("one", "two", "three")
        initial[2].connection = .connected
        try await withBanner(hosts: initial) { store, service, window in
            let button = try XCTUnwrap(self.find("test-retry-all", in: window))
            XCTAssertTrue(button.accessibilityActivate())
            _ = button.accessibilityActivate()
            try await self.waitUntil { service.calls["one"] == 1 && service.calls["two"] == 1 && self.disabled("test-retry-all", in: window) }
            XCTAssertNil(service.calls["three"])
            self.report(.offline, hostID: "three", store: store)
            try await self.waitUntil { self.enabled("test-retry-all", in: window) }
            let updated = try XCTUnwrap(self.find("test-retry-all", in: window))
            XCTAssertTrue(updated.accessibilityActivate())
            _ = updated.accessibilityActivate()
            try await self.waitUntil { service.calls["three"] == 1 && self.disabled("test-retry-all", in: window) }
            XCTAssertEqual(service.calls, ["one": 1, "two": 1, "three": 1])
            XCTAssertEqual(service.pendingCount, 3)
        }
    }

    private func hosts(_ ids: String...) -> [CompanionHost] {
        ids.map { .init(id: $0, name: $0.capitalized + " Mac", endpoint: "Fixture only", connection: .offline, projects: []) }
    }

    private func report(_ connection: CompanionConnection, hostID: String, store: CompanionStore) {
        var hosts = store.hosts
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return XCTFail("Fixture host must exist") }
        hosts[index].connection = connection
        store.apply(.hosts(hosts))
    }

    private func withBanner(hosts: [CompanionHost], body: (CompanionStore, HeldReconnectService, UIWindow) async throws -> Void) async throws {
        let service = HeldReconnectService()
        let store = CompanionStore(service: service)
        store.apply(.hosts(hosts))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: VStack {
            CompanionDesktopConnectionBanner(store: store, identifierPrefix: "test")
            Spacer()
        }.padding(16).companionTheme(.clubhouse).environment(\.colorScheme, .light))
        window.makeKeyAndVisible()
        var failure: Error?
        do {
            try await waitUntil { self.find(hosts.filter { !$0.connection.canOperate }.count == 1 ? "test-retry-\(hosts[0].id)" : "test-retry-all", in: window) != nil }
            try await body(store, service, window)
        } catch { failure = error }
        service.beginTeardown()
        window.isHidden = true
        window.rootViewController = nil
        store.stop()
        original?.makeKey()
        await Task.yield()
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertNil(window.rootViewController)
        if let failure { throw failure }
    }

    private func enabled(_ id: String, in window: UIWindow) -> Bool {
        guard let button = find(id, in: window) else { return false }
        return !button.accessibilityTraits.contains(.notEnabled)
    }

    private func disabled(_ id: String, in window: UIWindow) -> Bool {
        find(id, in: window)?.accessibilityTraits.contains(.notEnabled) == true
    }

    private func find(_ id: String, in root: NSObject) -> NSObject? {
        var visited: Set<ObjectIdentifier> = []
        func search(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if (object as? UIAccessibilityIdentification)?.accessibilityIdentifier == id { return object }
            var children: [NSObject] = (object as? UIView)?.subviews ?? []
            children += object.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
            children += object.automationElements?.compactMap { $0 as? NSObject } ?? []
            let count = object.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { children.append(child) }
                }
            }
            for child in children { if let found = search(child) { return found } }
            return nil
        }
        return search(root)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard predicate() else {
            XCTFail("The actual hosted banner must reach the requested state")
            throw NSError(domain: "Retry latch fixture", code: 1)
        }
    }

    private func capture(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor private final class HeldReconnectService: CompanionService {
    var calls: [String: Int] = [:]
    private var pending: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var isTearingDown = false
    var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }
    func reconnect(hostID: String) async {
        calls[hostID, default: 0] += 1
        guard !isTearingDown else { return }
        await withCheckedContinuation { pending[hostID, default: []].append($0) }
    }
    func finishFirst(_ hostID: String) {
        guard var waiting = pending[hostID], !waiting.isEmpty else { return }
        let first = waiting.removeFirst()
        pending[hostID] = waiting.isEmpty ? nil : waiting
        first.resume()
    }
    func beginTeardown() {
        isTearingDown = true
        let held = pending.values.flatMap { $0 }
        pending.removeAll()
        for continuation in held { continuation.resume() }
    }
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { throw CompanionServiceError.unavailable("Fixture only") }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Fixture only") }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Fixture only") }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { throw CompanionServiceError.unavailable("Fixture only") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { throw CompanionServiceError.unavailable("Fixture only") }
}
