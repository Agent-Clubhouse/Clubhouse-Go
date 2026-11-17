import XCTest
import SwiftUI
import Vision
@testable import ClubhouseGo

@MainActor final class CompanionHomeLinkedRowsTests: XCTestCase {
    func testMountedCombinedRowsRenderOriginsAndOneQuietFold() async throws {
        try await mountedRows(quietOnly: false)
    }

    func testMountedExpandedQuietRowsKeepMachineAttributionAndClearTargets() async throws {
        try await mountedRows(quietOnly: true)
    }

    func testMountedLinkedAllRowsKeepFullOriginAtAccessibilitySize() async throws {
        try await mountedRows(quietOnly: false, type: .accessibility5)
    }

    private func mountedRows(quietOnly: Bool, type: DynamicTypeSize = .large) async throws {
        let store = CompanionStore(service: CompanionPreviewService())
        store.apply(.hosts(CompanionHomeLinkedFixture.hosts()))
        let suite = "combined-home-hosted-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = CompanionPreferences(defaults: defaults, systemDeviceName: "Synthetic test")
        let entry = try XCTUnwrap(store.projectEntries.first)
        XCTAssertTrue(entry.isLinked, "This is the actual linked entry routed to CompanionHomeLinkedProjectRows")
        var group = try XCTUnwrap(CompanionHomeLayout.build([entry], sort: .recent, customOrder: [], rule: .init(),
            projectActivity: { _ in Date() }, agentActivity: store.lastActivity(of:)).projects.first)
        let quiet = CompanionHomeLinkedRows(entry: entry, finished: store.finished(in:))
        if quietOnly {
            group.tree.active = []
            preferences.toggleFold("quiet:\(quiet.foldID)")
        }
        let content = NavigationStack {
            List {
                CompanionHomeLinkedProjectRows(group: group, quiet: quiet, preferences: preferences, parentLines: [:],
                    onDismissFinished: { _ in XCTFail("Rendering cannot dismiss a run") },
                    onClearFinished: { _ in XCTFail("Rendering cannot clear runs") }, canOpenFinished: { _ in false })
            }.companionAgentRows(store: store)
        }.dynamicTypeSize(type).companionTheme(.clubhouse)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
        let required = type.isAccessibilitySize ? ["River"] : (quietOnly ? ["Juniper", "Maple", "Birch", "Ash"] : ["River", "Cedar"])
        var text = ""
        for _ in 0..<20 {
            await Task.yield(); window.layoutIfNeeded()
            text = try renderedText(window)
            if required.allSatisfy({ text.contains($0) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for title in required { XCTAssertTrue(text.contains(title), "Mounted rows must render \(title): \(text)") }
        if type.isAccessibilitySize {
            XCTAssertTrue(text.contains("Travel MacBook with a long desktop name"), "The full origin remains visible at AX5")
        } else {
            XCTAssertTrue(text.contains("Studio Mac") && text.contains("Travel MacBook"), "Origin badges render full machine names")
            if quietOnly {
                XCTAssertTrue(text.contains("Archive Mac"), "Quiet-only machine retains its origin")
                XCTAssertTrue(text.contains("Clear finished runs"))
                XCTAssertEqual(quiet.finishedProjects.map(\.hostID), ["combined-0", "combined-1", "combined-2"])
            } else {
                XCTAssertTrue(text.contains("1 sleeping") && text.contains("3 finished quick agents"))
                XCTAssertFalse(text.contains("Juniper"), "The single quiet section starts collapsed")
            }
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "536 hosted All \(quietOnly ? "expanded quiet" : "active") \(type.isAccessibilitySize ? "AX5" : "standard")"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func renderedText(_ window: UIWindow) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
    }
}
