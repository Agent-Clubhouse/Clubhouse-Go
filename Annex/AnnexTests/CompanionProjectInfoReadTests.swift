import XCTest
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
