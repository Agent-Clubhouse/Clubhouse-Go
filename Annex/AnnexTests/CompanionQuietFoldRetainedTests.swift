import XCTest
@testable import ClubhouseGo

@MainActor final class CompanionQuietFoldRetainedTests: XCTestCase {
    private let target = CompanionTarget(hostID: "studio", projectID: "p", agentID: "quick")

    private func preferences() -> CompanionPreferences {
        CompanionPreferences(defaults: UserDefaults(suiteName: "quiet-fold-\(UUID().uuidString)")!, systemDeviceName: "Tests")
    }

    private func fixture() -> (CompanionAgentTree, CompanionFinishedRun) {
        let sleeping = CompanionAgent(id: .init(hostID: "studio", projectID: "p", agentID: "sleep"), name: "Juniper", subtitle: "", status: .sleeping)
        var quick = CompanionAgent(id: target, name: "Quick", subtitle: "Check changes", status: .completed)
        quick.isQuick = true
        quick.hasExited = true
        let tree = CompanionAgentTree.build([sleeping, quick], sort: .recent, lastActivity: { $0.lastActivity })
        let run = CompanionFinishedRun(target: target, name: "Quick", mission: "Check changes", exitCode: 0, status: .completed, completedAt: Date(), summary: nil)
        return (tree, run)
    }

    func testTheOriginalInitializerKeepsItsCatalogOnlyBehavior() {
        let (tree, _) = fixture()
        let fold = CompanionAgentTreeQuietFold(projectID: "p", tree: tree, preferences: preferences())
        XCTAssertEqual(fold.text, "1 sleeping · 1 finished quick agent")
        XCTAssertEqual(fold.quietRows.map(\.id), tree.sleeping.map(\.id) + tree.finishedQuick.map(\.id))
        XCTAssertTrue(fold.retainedRuns.isEmpty)
    }

    func testARetainedRunReplacesItsCatalogRowAndRetiredRunsAreNotLost() {
        let (tree, run) = fixture()
        var retired = run
        retired.target.agentID = "forgotten"
        let fold = CompanionAgentTreeQuietFold(projectID: "p", tree: tree, preferences: preferences(), finishedRuns: [run, retired, run])
        XCTAssertEqual(fold.text, "1 sleeping · 2 finished quick agents")
        XCTAssertEqual(fold.retainedRuns.map(\.target), [run.target, retired.target])
        XCTAssertEqual(fold.quietRows.map(\.id), tree.sleeping.map(\.id))
    }

    func testAnAuthoritativeEmptyListDoesNotResurrectDismissedCatalogRuns() {
        let (tree, _) = fixture()
        let fold = CompanionAgentTreeQuietFold(projectID: "p", tree: tree, preferences: preferences(), finishedRuns: [])
        XCTAssertEqual(fold.text, "1 sleeping")
        XCTAssertEqual(fold.finishedCount, 0)
        XCTAssertEqual(fold.quietRows.map(\.id), tree.sleeping.map(\.id))
    }
}
