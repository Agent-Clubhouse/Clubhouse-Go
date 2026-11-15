import XCTest
@testable import ClubhouseGo

@MainActor final class CompanionDesktopChipsTests: XCTestCase {
    private func host(_ id: String, connection: CompanionConnection = .connected) -> CompanionHost {
        .init(id: id, name: id, endpoint: id, connection: connection, projects: [])
    }

    func testRepeatedLinkedMembersProduceOnlyOneChoicePerDesktop() {
        XCTAssertEqual(CompanionDesktopChips.uniqueHosts([host("a"), host("a"), host("b")]).map(\.id), ["a", "b"])
    }

    func testASelectedDesktopThatDisappearsResetsToAll() {
        XCTAssertEqual(CompanionDesktopSelection.host("gone").reconciled(with: [host("a")]), .all)
        XCTAssertEqual(CompanionDesktopSelection.all.reconciled(with: []), .all)
    }

    func testAnOfflineDesktopKeepsItsScopeWithoutGrantingAuthority() {
        let offline = host("a", connection: .offline)
        XCTAssertEqual(CompanionDesktopSelection.host("a").reconciled(with: [offline]), .host("a"))
        XCTAssertFalse(offline.connection.canOperate)
    }

}
