import XCTest
import SwiftUI
import Vision
@testable import ClubhouseGo

@MainActor final class CompanionProjectInfoReadTests: XCTestCase {
    func testAProjectInfoReadCannotKeepItsAdmissionAcrossReconnectOrCatalogReplacement() throws {
        let store = CompanionStore(service: CompanionPreviewService())
        var hosts = CompanionPreviewService.hosts(now: Date())
        let project = CompanionProjectTarget(hostID: hosts[0].id, projectID: "clubhouse")
        store.apply(.hosts(hosts))
        let first = try XCTUnwrap(store.createOptionsReadGeneration(for: project))
        hosts[0].connection = .offline
        store.apply(.hosts(hosts))
        XCTAssertNil(store.createOptionsReadGeneration(for: project))
        hosts[0].connection = .connected
        store.apply(.hosts(hosts))
        let second = try XCTUnwrap(store.createOptionsReadGeneration(for: project))
        XCTAssertNotEqual(first, second, "A late reply from the first read cannot populate the visible info sheet")
        let saved = hosts[0].projects
        hosts[0].projects = []
        store.apply(.hosts(hosts))
        XCTAssertNil(store.createOptionsReadGeneration(for: project))
        hosts[0].projects = saved
        store.apply(.hosts(hosts))
        let fresh = try XCTUnwrap(store.createOptionsReadGeneration(for: project))
        XCTAssertNotEqual(second, fresh, "Removing and restoring the same project ID is a new read context")
        store.shutdown()
        XCTAssertNil(store.createOptionsReadGeneration(for: project))
    }

    func testOpenInfoSheetRejectsLateDefaultsAfterReconnectAndDisplaysFreshReply() async throws {
        let service = DelayedProjectInfoService()
        let store = CompanionStore(service: service)
        var hosts = Array(CompanionPreviewService.hosts(now: Date()).prefix(1))
        hosts[0].projects = [.init(id: "clubhouse", name: "Clubhouse", agents: [], path: "/Projects/Clubhouse")]
        hosts[0].projectLinks = nil
        let project = CompanionProjectTarget(hostID: hosts[0].id, projectID: "clubhouse")
        store.apply(.hosts(hosts))
        let initialGeneration = try XCTUnwrap(store.createOptionsReadGeneration(for: project))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView:
            CompanionProjectInfoSheet(store: store, project: project)
                .dynamicTypeSize(.large).companionBackground().companionTheme(.clubhouse)
                .environment(\.colorScheme, .light))
        window.makeKeyAndVisible()
        defer {
            service.finishPendingReads()
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKey()
            store.shutdown()
        }
        try await waitUntil { service.pending.count == 1 }

        // Coalesce both catalog updates before SwiftUI redraws. The final host fields are identical,
        // but the admission generation changes and the real sheet must start a fresh read.
        hosts[0].connection = .offline
        store.apply(.hosts(hosts))
        hosts[0].connection = .connected
        store.apply(.hosts(hosts))
        XCTAssertNotEqual(store.createOptionsReadGeneration(for: project), initialGeneration)
        try await waitUntil { service.pending.count == 2 }

        // The service deliberately ignores task cancellation, as a late transport reply can do.
        service.resolve(0, server: "Obsolete defaults")
        try await waitUntil { service.completedReads == 1 }
        let late = try await renderedText(window, stage: "Late reply rejected")
        XCTAssertTrue(late.contains("Project info"), "Exercise the real presented sheet")
        XCTAssertFalse(late.contains("Obsolete defaults"), "The old generation's reply must never be displayed")
        XCTAssertTrue(late.contains("Reading project defaults"), "Keep the current read pending instead of showing stale values")

        service.resolve(1, server: "Current defaults")
        try await waitUntil { service.completedReads == 2 }
        let fresh = try await renderedText(window, stage: "Fresh reply displayed")
        XCTAssertTrue(fresh.contains("Current defaults"), "A legitimate reply after rotation must still be displayed")
        XCTAssertFalse(fresh.contains("Obsolete defaults"))
        XCTAssertFalse(fresh.contains("Reading project defaults"))
        XCTAssertEqual(service.pending.count, 2, "Rendering a reply must not start a read loop")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try XCTUnwrap(condition() ? true : nil, "The sheet must advance its real async read path")
    }

    private func renderedText(_ window: UIWindow, stage: String) async throws -> String {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "443 \(stage)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: "\n")
    }

    func testUnknownAndUnsupportedProjectsOfferNoInfoReadAdmission() {
        let store = CompanionStore(service: CompanionPreviewService())
        var hosts = CompanionPreviewService.hosts(now: Date())
        hosts[0].canCreateDurable = false
        store.apply(.hosts(hosts))
        XCTAssertNil(store.createOptionsReadGeneration(for: .init(hostID: hosts[0].id, projectID: "clubhouse")))
        XCTAssertNil(store.createOptionsReadGeneration(for: .init(hostID: hosts[0].id, projectID: "missing")))
        store.shutdown()
    }
}

/// Cancellation does not complete these reads: the test chooses exactly when each transport reply arrives.
@MainActor private final class DelayedProjectInfoService: CompanionService {
    let preview = CompanionPreviewService()
    var pending: [CheckedContinuation<String, Never>?] = []
    var completedReads = 0
    func events() -> AsyncStream<CompanionEvent> { preview.events() }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { try await preview.history(for: target) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { try await preview.send(request) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { try await preview.cancel(target, clientCommandID: clientCommandID) }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {
        try await preview.respond(to: approvalID, optionID: optionID, target: target, clientCommandID: clientCommandID)
    }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { try await preview.spawn(request) }
    func reconnect(hostID: String) async {}
    func createOptions(for project: CompanionProjectTarget) async throws -> CompanionCreateOptions {
        var options = try await preview.createOptions(for: project)
        let server = await withCheckedContinuation { pending.append($0) }
        options.mcpCatalog = []
        options.mcpDefaults = [server]
        completedReads += 1
        return options
    }
    func resolve(_ index: Int, server: String) {
        let reply = pending[index]
        pending[index] = nil
        reply?.resume(returning: server)
    }
    func finishPendingReads() {
        for index in pending.indices { resolve(index, server: "Cleanup") }
    }
}
