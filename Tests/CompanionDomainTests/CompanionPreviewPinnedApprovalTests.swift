import Foundation
import Testing
@testable import CompanionDomain

#if DEBUG
/// The synthetic pinned approvals behind the #448 decision-bar UI tests: launch arguments choose each variant.
@Suite struct CompanionPreviewPinnedApprovalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func defaultApprovalOffersOnceAlwaysAndDenyWithACompleteSummary() {
        let approval = CompanionPreviewService.pinnedApproval(id: "pinned-first", title: "Run preview build", arguments: [], now: now)
        #expect(approval.id == "pinned-first")
        #expect(approval.toolName == "Bash")
        #expect(approval.title == "Run preview build")
        #expect(approval.summary == "Synthetic request for Run preview build. Full context stays in chat.")
        #expect(approval.deadline == now.addingTimeInterval(600))
        #expect(approval.options.map(\.kind) == [.allowOnce, .allowAlways, .rejectOnce])
        #expect(approval.options.first { $0.kind == .allowAlways }?.scope == "preview:*")
    }

    @Test func broaderOnlyDropsTheOneOffAllowAndKeepsAMislabelledCustomKind() {
        let approval = CompanionPreviewService.pinnedApproval(id: "pinned-first", title: "Run preview build",
            arguments: ["--companion-preview-pinned-broader-only"], now: now)
        #expect(!approval.options.contains { $0.kind == .allowOnce })
        #expect(approval.options.map(\.id) == ["always", "deny", "custom"])
        let custom = approval.options.last
        #expect(custom?.label == "Allow once" && custom?.kind == .other, "The label alone never makes a one-off allow")
    }

    @Test func lateArrivalWaitsLongerThanTheDefaultTick() {
        #expect(CompanionPreviewService.pinnedArrivalStep(arguments: []) == 20)
        #expect(CompanionPreviewService.pinnedArrivalStep(arguments: ["--companion-preview-pinned-late"]) == 75)
    }

    @Test func incompleteInputUsesTheReviewSummaryAndKeepsTheDefaultOptions() {
        let approval = CompanionPreviewService.pinnedApproval(id: "pinned-second", title: "Edit preview notes",
            arguments: ["--companion-preview-pinned-incomplete"], now: now)
        #expect(approval.summary == "Incomplete input: synthetic request needs full review.")
        #expect(approval.options.map(\.kind) == [.allowOnce, .allowAlways, .rejectOnce])
    }
}
#endif
