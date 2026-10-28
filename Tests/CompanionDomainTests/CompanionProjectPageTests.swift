import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// The project page (#158): the desktop's "Finished, waiting on you" (`ProjectStartPage.tsx`, `quickAgentStore.ts`),
// and the project root's read-only Changes (`ProjectChanges.tsx`, `ChangesReview.tsx`).

private let project = CompanionProjectTarget(hostID: "host", projectID: "project")
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func quick(_ id: String, status: CompanionAgentStatus = .completed, exited: Bool = true, exitCode: Int? = 0,
                   finishedAgo: TimeInterval? = 60, mission: String = "Fix the build", projectID: String = "project") -> CompanionAgent {
    .init(id: .init(hostID: "host", projectID: projectID, agentID: id), name: id, subtitle: mission, status: status,
          lastActivity: finishedAgo.map { now.addingTimeInterval(-$0) }, isQuick: true, hasExited: exited, exitCode: exitCode)
}
private func host(_ agents: [CompanionAgent], connection: CompanionConnection = .connected) -> CompanionHost {
    let projects = Dictionary(grouping: agents, by: \.id.projectID).map { CompanionProject(id: $0.key, name: $0.key, agents: $0.value) }
    return .init(id: "host", name: "Studio", endpoint: "studio.local", connection: connection,
                 projects: projects.isEmpty ? [.init(id: "project", name: "Project", agents: [])] : projects)
}

// MARK: - Finished, waiting on you

@Suite struct CompanionFinishedRulesTests {
    @Test func onlyQuickAgentsWhoseProcessExitedAreFinished() {
        #expect(CompanionFinishedRuns.hasFinished(quick("done")))
        #expect(CompanionFinishedRuns.hasFinished(quick("failed", status: .failed, exitCode: 2)))
        #expect(CompanionFinishedRuns.hasFinished(quick("cancelled", status: .stopped, exitCode: nil)))
        // A running quick agent with a failed tool reads as failed, but hasn't exited.
        #expect(!CompanionFinishedRuns.hasFinished(quick("tool-error", status: .failed, exited: false, exitCode: nil)))
        #expect(!CompanionFinishedRuns.hasFinished(quick("idle", status: .idle, exited: false, exitCode: nil)))
        var durable = quick("durable", status: .idle)
        durable.isQuick = false
        #expect(!CompanionFinishedRuns.hasFinished(durable))
    }

    @Test func runsAreNewestFirstAndScopedToTheirProject() {
        var runs = CompanionFinishedRuns()
        runs.observe([host([quick("older", finishedAgo: 600), quick("newest", finishedAgo: 5), quick("elsewhere", projectID: "other"),
                            quick("working", status: .working, exited: false, exitCode: nil)])], now: now)
        #expect(runs.runs(in: project).map(\.target.agentID) == ["newest", "older"])
        #expect(runs.runs(in: .init(hostID: "host", projectID: "other")).map(\.target.agentID) == ["elsewhere"])
        #expect(runs.runs(in: .init(hostID: "other-host", projectID: "project")).isEmpty)
        // A later run lands at the top, an earlier one in its place.
        runs.record(quick("middle", finishedAgo: 100), now: now)
        #expect(runs.runs(in: project).map(\.target.agentID) == ["newest", "middle", "older"])
    }

    @Test func aRunIsStampedWhenItExitedAndNeverInTheFuture() {
        var runs = CompanionFinishedRuns()
        runs.record(quick("a", finishedAgo: 120), now: now)
        runs.record(quick("b", finishedAgo: nil), now: now)
        runs.record(quick("c", finishedAgo: -600), now: now)
        let stamps = Dictionary(uniqueKeysWithValues: runs.runs.map { ($0.target.agentID, $0.completedAt) })
        #expect(stamps["a"] == now.addingTimeInterval(-120))
        #expect(stamps["b"] == now && stamps["c"] == now)
    }

    @Test func eachProjectKeepsTheDesktopsFiftyNewest() {
        var runs = CompanionFinishedRuns()
        for index in 0..<55 { runs.record(quick("run-\(index)", finishedAgo: TimeInterval(1000 - index)), now: now) }
        runs.record(quick("other", projectID: "other"), now: now)
        let kept = runs.runs(in: project)
        #expect(kept.count == CompanionFinishedRuns.maximumPerProject)
        #expect(kept.first?.target.agentID == "run-54" && kept.last?.target.agentID == "run-5")
        #expect(runs.runs(in: .init(hostID: "host", projectID: "other")).count == 1)
    }

    @Test func dismissedRunsStayGoneWhileTheDesktopStillListsThem() {
        var runs = CompanionFinishedRuns()
        let snapshot = [host([quick("a"), quick("b")])]
        runs.observe(snapshot, now: now)
        runs.dismiss(.init(hostID: "host", projectID: "project", agentID: "a"))
        #expect(runs.runs(in: project).map(\.target.agentID) == ["b"])
        let changed = runs.observe(snapshot, now: now)
        #expect(!changed)
        #expect(runs.runs(in: project).map(\.target.agentID) == ["b"])
    }

    @Test func clearAllEmptiesOnlyThatProject() {
        var runs = CompanionFinishedRuns()
        let snapshot = [host([quick("a"), quick("b"), quick("c", projectID: "other")])]
        runs.observe(snapshot, now: now)
        runs.clear(project)
        #expect(runs.runs(in: project).isEmpty)
        #expect(runs.runs(in: .init(hostID: "host", projectID: "other")).count == 1)
        let changed = runs.observe(snapshot, now: now)
        #expect(!changed, "Cleared runs don't come back")
    }

    @Test func theDismissedListIsBounded() {
        var runs = CompanionFinishedRuns()
        for index in 0..<(CompanionFinishedRuns.maximumDismissed + 10) {
            runs.dismiss(.init(hostID: "host", projectID: "project", agentID: "\(index)"))
        }
        #expect(runs.dismissed.count == CompanionFinishedRuns.maximumDismissed)
        #expect(runs.dismissed.first?.agentID == "10")
    }

    @Test func aLaterReportAddsTheExitCode() {
        var runs = CompanionFinishedRuns()
        runs.record(quick("a", status: .failed, exitCode: nil), now: now)
        #expect(runs.runs.first?.detail == "Stopped with an error")
        let updated = runs.record(quick("a", status: .failed, exitCode: 3), now: now)
        #expect(updated && runs.runs.first?.exitCode == 3)
        let again = runs.record(quick("a", status: .failed, exitCode: 4), now: now)
        #expect(!again && runs.runs.first?.exitCode == 3, "The first code reported stays")
    }

    @Test func rowsUseTheDesktopsWording() {
        func run(_ agent: CompanionAgent) -> CompanionFinishedRun {
            var runs = CompanionFinishedRuns(); runs.record(agent, now: now); return runs.runs[0]
        }
        #expect(run(quick("a", exitCode: 0)).detail == "Finished")
        #expect(run(quick("a", status: .failed, exitCode: 137)).detail == "Exited with code 137")
        #expect(run(quick("a", status: .stopped, exitCode: nil)).detail == "Cancelled")
        #expect(run(quick("a", mission: "Ship it")).title == "Ship it")
        #expect(run(quick("brave-otter", mission: "")).title == "brave-otter", "No mission shows the name")
        #expect(run(quick("a", status: .failed, exitCode: 1)).failed && !run(quick("a")).failed)
    }

    static let agoCases: [(TimeInterval, String)] = [
        (0.0, "just now"), (29.0, "just now"), (30.0, "1m ago"), (59 * 60.0, "59m ago"), (59.5 * 60, "1h ago"),
        (90 * 60.0, "2h ago"), (23 * 3600.0, "23h ago"), (23.5 * 3600, "1d ago"), (36 * 3600.0, "2d ago"), (-60.0, "just now")
    ]
    @Test(arguments: agoCases)
    func agoMatchesTheDesktop(seconds: TimeInterval, text: String) {
        #expect(CompanionFinishedRun.ago(now.addingTimeInterval(-seconds), now: now) == text)
    }

    @Test func runsSurviveARoundTripThroughStorage() throws {
        var runs = CompanionFinishedRuns()
        runs.observe([host([quick("a"), quick("b", status: .failed, exitCode: 1)])], now: now)
        runs.dismiss(.init(hostID: "host", projectID: "project", agentID: "b"))
        let decoded = try JSONDecoder().decode(CompanionFinishedRuns.self, from: JSONEncoder().encode(runs))
        #expect(decoded == runs)
    }
}

// MARK: - Store

@MainActor private final class ProjectPageService: CompanionService {
    var sent: [CompanionSendRequest] = []
    var historyValue = CompanionHistory(items: [])
    var changesValue = CompanionChanges(isRepository: true, branch: "main", files: [])
    var diffs: [String] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { historyValue }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt {
        sent.append(request); return .init(clientCommandID: request.clientCommandID)
    }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
    func changes(for project: CompanionProjectTarget) async throws -> CompanionChanges { changesValue }
    func diff(of file: CompanionChangedFile, in project: CompanionProjectTarget) async throws -> CompanionFileDiff {
        diffs.append(file.path)
        return .make(path: file.path, original: "a\n", modified: "b\n")
    }
}

@MainActor private final class MemoryFinished: CompanionFinishedPersistence {
    var stored: CompanionFinishedRuns?
    var saves = 0
    func load() -> CompanionFinishedRuns? { stored }
    func save(_ runs: CompanionFinishedRuns) { stored = runs; saves += 1 }
}

@Suite @MainActor struct CompanionProjectPageStoreTests {
    @Test func hostUpdatesRecordFinishedRunsAndPersistThem() async {
        let persistence = MemoryFinished()
        let store = CompanionStore(service: ProjectPageService(), finishedPersistence: persistence)
        store.apply(.hosts([host([quick("a", finishedAgo: 30), quick("running", status: .working, exited: false, exitCode: nil)])]))
        #expect(store.finished(in: project).map(\.target.agentID) == ["a"])
        #expect(persistence.stored?.runs.map(\.target.agentID) == ["a"])
        // An unchanged catalog doesn't write again.
        let saves = persistence.saves
        store.apply(.hosts([host([quick("a", finishedAgo: 30)])]))
        #expect(persistence.saves == saves)

        await store.dismissFinished(.init(hostID: "host", projectID: "project", agentID: "a"))
        #expect(store.finished(in: project).isEmpty)
        let relaunched = CompanionStore(service: ProjectPageService(), finishedPersistence: persistence)
        relaunched.apply(.hosts([host([quick("a", finishedAgo: 30)])]))
        #expect(relaunched.finished(in: project).isEmpty, "A dismissal is remembered across launches")
    }

    @Test func runsOutliveTheDesktopForgettingTheAgent() async {
        let store = CompanionStore(service: ProjectPageService())
        store.apply(.hosts([host([quick("a")])]))
        store.apply(.hosts([host([])]))
        #expect(store.finished(in: project).map(\.target.agentID) == ["a"])
        await store.clearFinished(in: project)
        #expect(store.finished(in: project).isEmpty)
    }

    @Test func sleepingAgentsAreTheProjectsDurableOnesAsleep() {
        let store = CompanionStore(service: ProjectPageService())
        func durable(_ id: String, _ status: CompanionAgentStatus) -> CompanionAgent {
            .init(id: .init(hostID: "host", projectID: "project", agentID: id), name: id, subtitle: "", status: status)
        }
        store.apply(.hosts([host([durable("asleep", .sleeping), durable("stopped", .stopped), durable("awake", .idle), quick("q", status: .stopped)])]))
        #expect(store.sleepingAgents(in: project).map(\.id.agentID).sorted() == ["asleep", "stopped"])
    }

    @Test func wakeWithAMessageReadsTheChatSendsTheMessageAndOpensIt() async {
        let service = ProjectPageService()
        let store = CompanionStore(service: service)
        let sleeper = CompanionAgent(id: .init(hostID: "host", projectID: "project", agentID: "juniper"), name: "Juniper", subtitle: "",
                                     status: .sleeping, capabilities: [.chat, .wake])
        store.apply(.hosts([host([sleeper])]))
        await store.wake(sleeper.id, message: "  Draft the release notes  ")
        #expect(store.selection == sleeper.id)
        #expect(service.sent.map(\.text) == ["Draft the release notes"])
        #expect(store.drafts[sleeper.id] == "")
    }

    @Test func wakeWithAMessageKeepsTheMessageWhenTheAgentCantTakeIt() async {
        let service = ProjectPageService()
        let store = CompanionStore(service: service)
        let terminal = CompanionAgent(id: .init(hostID: "host", projectID: "project", agentID: "pty"), name: "Pty", subtitle: "", status: .sleeping)
        store.apply(.hosts([host([terminal])]))
        await store.wake(terminal.id, message: "hello")
        #expect(service.sent.isEmpty)
        #expect(store.drafts[terminal.id] == "hello")
        #expect(store.operationErrors[terminal.id]?.contains("can't be woken") == true)
    }

    @Test func changesNeedAConnectedDesktop() async throws {
        let service = ProjectPageService()
        let store = CompanionStore(service: service)
        store.apply(.hosts([host([], connection: .offline)]))
        await #expect(throws: CompanionServiceError.self) { try await store.changes(for: project) }
        store.apply(.hosts([host([])]))
        #expect(try await store.changes(for: project).branch == "main")
        let file = CompanionChangedFile(path: "a.txt", code: "M", staged: false)
        #expect(try await store.diff(of: file, in: project).added == 1)
        #expect(service.diffs == ["a.txt"])
    }
}

// MARK: - Changes

@Suite struct CompanionChangesTests {
    static let statusCases: [(String, Bool, CompanionChangedFile.Status)] = [
        ("M", false, .modified), ("MM", true, .modified), ("A", true, .added), ("AM", true, .added),
        ("??", false, .added), ("D", true, .deleted), ("AD", true, .added), ("R", true, .renamed), ("RM", true, .renamed),
        ("C", true, .modified), ("UU", false, .modified), ("T", false, .modified)
    ]
    @Test(arguments: statusCases)
    func statusFollowsTheDesktopsChangesReview(code: String, staged: Bool, status: CompanionChangedFile.Status) {
        #expect(CompanionChangedFile(path: "a", code: code, staged: staged).status == status)
    }

    @Test func lettersMatchTheDesktop() {
        #expect(CompanionChangedFile.Status.allCases.map(\.letter) == ["A", "M", "D", "R"])
    }

    @Test func stagedFilesDiffAgainstTheIndexAndUntrackedOnesAgainstTheWorkingTree() {
        #expect(CompanionChangedFile(path: "a", code: "M", staged: true).diffsStaged)
        #expect(!CompanionChangedFile(path: "a", code: "M", staged: false).diffsStaged)
        let untracked = CompanionChangedFile(path: "a", code: "??", staged: true)
        #expect(untracked.untracked && !untracked.diffsStaged)
    }

    @Test func gitInfoDecodes() throws {
        let json: AnnexJSON = .object([
            "hasGit": .bool(true), "branch": .string("feature/x"), "ahead": .integer(2), "behind": .integer(0), "hasConflicts": .bool(false),
            "status": .array([
                .object(["path": .string("Sources/App.swift"), "status": .string("M"), "staged": .bool(false)]),
                .object(["path": .string("new.txt"), "status": .string("??"), "staged": .bool(false)]),
                .object(["path": .string("b.txt"), "origPath": .string("a.txt"), "status": .string("R"), "staged": .bool(true)]),
                .object(["status": .string("M")])
            ]),
            "log": .array([]), "branches": .array([])
        ])
        let changes = try CompanionChanges(json: json)
        #expect(changes.isRepository && changes.branch == "feature/x" && changes.ahead == 2)
        #expect(changes.files.map(\.path) == ["Sources/App.swift", "new.txt", "b.txt"], "A file without a path is skipped")
        #expect(changes.files.map(\.status) == [.modified, .added, .renamed])
        #expect(changes.files[2].originalPath == "a.txt" && changes.files[2].staged)
        #expect(changes.files[0].name == "App.swift" && changes.files[0].folder == "Sources/" && changes.files[1].folder == "")
    }

    @Test func aFolderThatIsntARepositoryDecodesAsSuch() throws {
        let changes = try CompanionChanges(json: .object(["hasGit": .bool(false), "branch": .string(""), "status": .array([])]))
        #expect(!changes.isRepository && changes.files.isEmpty)
    }

    @Test func somethingElseIsRefused() {
        #expect(throws: CompanionServiceError.self) { try CompanionChanges(json: .object(["error": .string("git_info_failed")])) }
    }
}

// MARK: - Diffs

@Suite struct CompanionDiffTests {
    private func kinds(_ lines: [CompanionDiffLine]) -> String {
        lines.map { switch $0.kind { case .added: "+"; case .removed: "-"; case .context: " "; case .hunk: "@" } }.joined()
    }
    private func rows(_ diff: CompanionFileDiff) -> [CompanionDiffLine] {
        if case .lines(let lines) = diff.body { lines } else { [] }
    }

    @Test func aFinalNewlineEndsTheLastLine() {
        #expect(CompanionDiff.textLines("a\nb\n") == ["a", "b"])
        #expect(CompanionDiff.textLines("a\nb") == ["a", "b"])
        #expect(CompanionDiff.textLines("") == [])
        #expect(CompanionDiff.textLines("\n") == [""])
        #expect(CompanionDiff.textLines("a\r\nb\r\n") == ["a\r", "b\r"], "CRLF splits too")
    }

    @Test func removalsComeBeforeAdditionsWithBothLineNumbers() {
        let lines = CompanionDiff.lines(old: "one\ntwo\nthree\n", new: "one\n2\nthree\nfour\n")
        #expect(kinds(lines) == " -+ +")
        #expect(lines.map(\.text) == ["one", "two", "2", "three", "four"])
        #expect(lines.map(\.oldNumber) == [1, 2, nil, 3, nil])
        #expect(lines.map(\.newNumber) == [1, nil, 2, 3, 4])
    }

    @Test func aMovedLineIsALongestCommonSubsequence() {
        let lines = CompanionDiff.lines(old: "a\nb\nc\nd\n", new: "b\nc\na\nd\n")
        #expect(kinds(lines) == "-  + ")
    }

    @Test func windowsLineEndingsCompareAsWrittenAndDisplayWithout() {
        let lines = CompanionDiff.lines(old: "a\r\nb\r\n", new: "a\r\nc\r\n")
        #expect(kinds(lines) == " -+")
        #expect(lines.map(\.text) == ["a", "b", "c"])
    }

    @Test func unchangedRunsFoldIntoHunksWithThreeLinesOfContext() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        var lines = (1...20).map(String.init)
        lines[1] = "two"; lines[17] = "eighteen"
        let diff = CompanionFileDiff.make(path: "n.txt", original: old, modified: lines.joined(separator: "\n"))
        let shown = rows(diff)
        #expect(diff.added == 2 && diff.removed == 2)
        #expect(shown.filter { $0.kind == .hunk }.map(\.text) == ["@@ -1,5 +1,5 @@", "@@ -15,6 +15,6 @@"])
        #expect(kinds(shown) == "@ -+   @   -+  ")
        #expect(shown.last?.text == "20")
    }

    @Test func nearbyChangesShareAHunk() {
        let old = (1...10).map(String.init).joined(separator: "\n")
        var lines = (1...10).map(String.init)
        lines[2] = "x"; lines[8] = "y"
        let shown = rows(CompanionFileDiff.make(path: "n", original: old, modified: lines.joined(separator: "\n")))
        #expect(shown.filter { $0.kind == .hunk }.map(\.text) == ["@@ -1,10 +1,10 @@"])
    }

    @Test func aHunkThatOnlyAddsStartsAtTheLineBefore() {
        let shown = rows(CompanionFileDiff.make(path: "n", original: "a\nb\nc\nd\ne\nf\ng\nh\n", modified: "a\nb\nc\nd\ne\nf\ng\nh\ni\n", context: 0))
        #expect(shown.map(\.text) == ["@@ -8,0 +9,1 @@", "i"])
    }

    @Test func newFilesAreAllAdditionsAndDeletedFilesAllRemovals() {
        let created = CompanionFileDiff.make(path: "new.swift", original: "", modified: "a\nb\n")
        #expect(created.isCreated && !created.isDeleted && created.added == 2 && created.removed == 0)
        #expect(rows(created).first?.text == "@@ -0,0 +1,2 @@")
        let deleted = CompanionFileDiff.make(path: "old.swift", original: "a\nb\nc\n", modified: nil)
        #expect(deleted.isDeleted && deleted.removed == 3 && deleted.added == 0)
        #expect(rows(deleted).first?.text == "@@ -1,3 +0,0 @@")
    }

    @Test func binaryAndUnchangedFilesHaveNoLines() {
        #expect(CompanionFileDiff.make(path: "logo.png", original: "PNG\0\u{1}", modified: "PNG\0\u{2}").body == .binary)
        #expect(CompanionFileDiff.make(path: "same", original: "a\n", modified: "a\n").body == .unchanged)
    }

    @Test func aHugeMiddleIsShownAsReplaced() {
        // 2,100 × 2,100 differing lines is past the desktop's four million cells.
        let old = (0..<2100).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<2100).map { "new \($0)" }.joined(separator: "\n")
        let lines = CompanionDiff.lines(old: "same\n" + old + "\nend", new: "same\n" + new + "\nend")
        #expect(lines.count == 2 + 4200)
        #expect(lines[1].kind == .removed && lines[2100].kind == .removed && lines[2101].kind == .added)
        #expect(lines.first?.kind == .context && lines.last?.kind == .context && lines.last?.newNumber == 2102)
    }

    @Test func aSmallEditToALongFileIsCheap() {
        let base = (0..<50_000).map { "line \($0)" }
        var edited = base
        edited[25_000] = "changed"
        let start = Date()
        let diff = CompanionFileDiff.make(path: "big", original: base.joined(separator: "\n"), modified: edited.joined(separator: "\n"))
        #expect(diff.added == 1 && diff.removed == 1)
        #expect(rows(diff).count == 1 + 3 + 2 + 3)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
