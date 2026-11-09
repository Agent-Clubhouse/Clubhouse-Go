import XCTest
@testable import ClubhouseGo

@MainActor final class CompanionHelperMessagePresentationTests: XCTestCase {
    func testHelperReplySeparatesItsToolsAndStatusInChronologicalOrder() {
        let rows = CompanionTimelineFolding.rows(for: CompanionPreviewService.helperMessageHistory)
        XCTAssertEqual(rows.map(\.id), [
            "notice:subagent-preview", "activity:tool:helper-read", "routed:helper-report:0",
            "activity:tool:helper-check", "routed:helper-status:0", "message:parent-reply"
        ])
        guard case .routed(let message, let index) = rows[2], case .others(let parts) = message.display else {
            return XCTFail("The helper's reply must remain an inline message")
        }
        XCTAssertEqual(parts[index].text, "The transcript fix is ready for review.")
        let resolver = CompanionSenderResolver(agents: CompanionPreviewService.hosts(now: .now).flatMap(\.allAgents))
        XCTAssertEqual(resolver.avatarIdentity(for: parts[index].sender)?.name, "Cedar")
        XCTAssertFalse(parts[index].text.contains("[FROM:"))
    }

    func testLongHelperRepliesStartOpenAndExplicitCollapsePersists() {
        let expansion = CompanionTranscriptExpansion()
        let first = expansion.part(messageID: "reply", index: 0)
        let second = expansion.part(messageID: "reply", index: 1)
        let text = String(repeating: "Helper report.\n", count: 100)
        XCTAssertTrue(first.isOpen(for: text))
        XCTAssertTrue(second.isOpen(for: text))
        first.open = false
        XCTAssertFalse(expansion.part(messageID: "reply", index: 0).isOpen(for: text))
        XCTAssertTrue(second.isOpen(for: text))
    }

    func testLegacyHelperRepliesAlsoStayVisible() {
        let message = CompanionMessage(id: "legacy", role: .user, text: "[FROM HELPER:Builder (helper-id)] Tests pass.", source: "mcp")
        let rows = CompanionTimelineFolding.rows(for: [.message(message)])
        XCTAssertEqual(rows.map(\.id), ["routed:legacy:0"])
        guard case .others(let parts) = message.display else { return XCTFail("Missing legacy route") }
        XCTAssertEqual(parts.first?.sender?.name, "Builder")
        XCTAssertEqual(parts.first?.text, "Tests pass.")
    }

    func testClubhouseAndQuestionPartsNeverHideBehindALongMessageToggle() {
        XCTAssertFalse(CompanionTimelineFolding.canCollapse(.init(fromClubhouse: true, text: String(repeating: "Status\n", count: 100))))
        XCTAssertFalse(CompanionTimelineFolding.canCollapse(.init(sender: .init(name: "Builder"), text: "[QUESTION FROM HELPER:Builder] Which branch?")))
    }

    func testPendingDeliveryAndToolFailuresKeepTheirActionableRows() {
        let message = CompanionMessage(id: "pending", role: .user, text: "raw", delivery: .uncertain("Refresh"), source: "mcp", routed: [.init(sender: .init(name: "Builder"), text: "Done")])
        let tool = CompanionTool(id: "failure", name: "Test", summary: "", state: .failed, subagentID: "helper")
        let rows = CompanionTimelineFolding.rows(for: [.message(message), .tool(tool)])
        XCTAssertEqual(rows, [.item(.message(message)), .item(.tool(tool))])
    }
}
