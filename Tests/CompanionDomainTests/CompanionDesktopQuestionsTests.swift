import Testing
@testable import CompanionDomain

@Suite @MainActor struct CompanionDesktopQuestionsTests {
    private let first = CompanionQuestion(id: "first", prompts: [])
    private let later = CompanionQuestion(id: "later", prompts: [], hasUnreadablePrompts: true)
    private var answerable: CompanionQuestion {
        .init(id: "complete", prompts: [.init(id: "color", text: "Which color?", options: [
            .init(id: "red", label: "Red", detail: nil)
        ], allowsMultiple: false, allowsFreeText: false)])
    }
    private func entries(_ items: [CompanionTimelineItem]) -> [CompanionTimelineEntry] {
        CompanionTimelineWindow(rows: CompanionTimelineFolding.rows(for: items, collapseDesktopQuestions: true), limit: .max).entries
    }

    @Test func firstAndLaterRequestJumpToTheSameVisibleSummary() throws {
        let items: [CompanionTimelineItem] = [.question(first), .notice(id: "between", text: "Progress"), .question(later), .question(answerable)]
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        store.apply(.timeline(target, items: items, sequence: 1, reset: true))
        let rows = store.timelineRows(for: target)
        let all = CompanionTimelineWindow(rows: rows, limit: .max).entries
        let firstTarget = try #require(CompanionTimelineEntry.jumpTarget(for: "question:first", in: all))
        let laterTarget = try #require(CompanionTimelineEntry.jumpTarget(for: "question:later", in: all))
        #expect(firstTarget == laterTarget)
        guard case .row(.desktopQuestions(let group)) = laterTarget else { Issue.record("Jump must land on a visible summary"); return }
        #expect(group.questions == [first, later])
        #expect(group.title == "2 questions this phone can't answer")
        #expect(group.message(hostName: "Studio Mac") == "Answer them in Clubhouse on Studio Mac.")
        #expect(all.map(\.id) == ["question:first", "notice:between", "question:complete"])
        #expect(store.conversation(for: target).items == items, "Presentation never removes authoritative source requests")
    }

    @Test func resolvingMembersUpdatesTheSummaryAndRetainsRecordedHistory() throws {
        var answered = first; answered.resolution = .answered
        let store = CompanionStore(service: CompanionPreviewService())
        let target = CompanionPreviewService.target
        store.apply(.timeline(target, items: [.question(first), .question(later), .question(answerable)], sequence: 1, reset: true))
        _ = store.timelineRows(for: target)
        store.apply(.upsert(target, .question(answered), sequence: 2))
        let all = CompanionTimelineWindow(rows: store.timelineRows(for: target), limit: .max).entries
        #expect(CompanionTimelineEntry.jumpTarget(for: "question:first", in: all) == .row(.item(.question(answered))))
        let remaining = try #require(CompanionTimelineEntry.jumpTarget(for: "question:later", in: all))
        guard case .row(.desktopQuestions(let group)) = remaining else { Issue.record("The pending member stays visible"); return }
        #expect(group.questions == [later])
        #expect(group.title == "1 question this phone can't answer")
        #expect(group.message(hostName: "Work Mac") == "Answer it in Clubhouse on Work Mac.")
        var withdrawn = later; withdrawn.resolution = .cancelled
        store.apply(.upsert(target, .question(withdrawn), sequence: 3))
        let resolved = CompanionTimelineWindow(rows: store.timelineRows(for: target), limit: .max).entries
        #expect(CompanionTimelineEntry.jumpTarget(for: "question:later", in: resolved) == .row(.item(.question(withdrawn))))
        #expect(resolved.count == 3)
        #expect(CompanionDesktopQuestions(items: [.question(answered), .question(withdrawn)]) == nil)
        #expect(CompanionTimelineEntry.jumpTarget(for: "question:removed", in: resolved) == nil)
    }

    @Test func onlyPendingUnreadableQuestionsCollapseAndOtherJumpsStayExact() {
        var submitting = first; submitting.id = "sending"; submitting.resolution = .submitting
        var uncertain = first; uncertain.id = "unknown"; uncertain.resolution = .uncertain
        let items: [CompanionTimelineItem] = [.question(answerable), .question(submitting), .question(uncertain), .question(later)]
        let all = entries(items)
        for item in items.prefix(3) {
            #expect(CompanionTimelineEntry.jumpTarget(for: item.id, in: all) == .row(.item(item)))
        }
        #expect(CompanionTimelineEntry.jumpTarget(for: "question:complete#extra", in: all) == nil)
        #expect(CompanionDesktopQuestions(items: [.question(answerable), .question(submitting), .question(uncertain)]) == nil)
        #expect(CompanionTimelineFolding.rows(for: items) == items.map { .item($0) }, "Archive folding remains unchanged")
    }

    @Test func retainingALaterMemberIncludesItsCanonicalVisibleRow() {
        let items: [CompanionTimelineItem] = [.question(first)] + (0..<200).map { .notice(id: "progress-\($0)", text: "Progress") } + [.question(later)]
        let rows = CompanionTimelineFolding.rows(for: items, collapseDesktopQuestions: true)
        let window = CompanionTimelineWindow(rows: rows, limit: 1, retaining: "question:later")
        #expect(window.hiddenCount == 0)
        #expect(CompanionTimelineEntry.jumpTarget(for: "question:later", in: window.entries)?.id == "question:first")
    }

    @Test func desktopOnlyTranscriptKeepsLatestAndEndClearanceInputs() {
        let single = CompanionTimelineEntry.entries(for: [.item(.question(first))])
        let grouped = entries([.question(first), .question(later)])
        let originalStops = CompanionAssistantNavigation.targets(in: single)
        let groupedStops = CompanionAssistantNavigation.targets(in: grouped)
        #expect(groupedStops == originalStops)
        #expect(!groupedStops.isEmpty, "The existing end-clearance predicate sees a real question stop")
        for follows in [false, true] {
            for offset in [0.0, 500.0] {
                let metrics = CompanionScrollMetrics(offset: offset, contentHeight: 1_000, containerHeight: 500, topInset: 0, bottomInset: 0)
                let latest = CompanionReadingPosition(followsLatest: follows).showsLatestButton(metrics)
                #expect(latest == (!follows && offset < 500))
                #expect((!groupedStops.isEmpty || latest) == (!originalStops.isEmpty || latest))
            }
        }
    }

    @Test func missingDesktopNameUsesHonestFallback() throws {
        let group = try #require(CompanionDesktopQuestions(items: [.question(first)]))
        #expect(group.message(hostName: nil) == "Answer it in Clubhouse on your desktop.")
        #expect(group.message(hostName: "") == group.message(hostName: nil))
    }
}
