import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite struct CompanionContentRootsTests {
    private let posix = CompanionContentRoots(paths: ["/Users/me/proj/.clubhouse/agents/a", "/Users/me/proj"])
    private let windows = CompanionContentRoots(paths: ["C:\\Users\\Me\\Proj"], windows: true)

    @Test func coversARootAndPathsBelowIt() {
        #expect(posix.covers("/Users/me/proj"))
        #expect(posix.covers("/Users/me/proj/src/a.swift"))
        #expect(posix.covers("/Users/me/proj/.clubhouse/agents/a/out.png"))
    }

    @Test func comparesWholeSegments() {
        #expect(!posix.covers("/Users/me/project/a.swift"))
        #expect(!posix.covers("/Users/me/pro"))
        #expect(!posix.covers("/Users/me"))
        #expect(!posix.covers("/tmp/a.png"))
    }

    @Test func trailingSeparatorsDontMatter() {
        let roots = CompanionContentRoots(paths: ["/Users/me/proj/"])
        #expect(roots.covers("/Users/me/proj"))
        #expect(roots.covers("/Users/me/proj/"))
        #expect(roots.covers("/Users/me/proj/a.txt"))
        #expect(!roots.covers("/Users/me/project"))
    }

    @Test func refusesEscapesHomeAndRelativePaths() {
        #expect(!posix.covers("/Users/me/proj/../secrets/a.txt"))
        #expect(!posix.covers("~/proj/a.txt"))
        #expect(!posix.covers("Users/me/proj/a.txt"))
        #expect(!posix.covers("//Users/me/proj/a.txt"))
        #expect(!CompanionContentRoots(paths: ["/"]).covers("/etc/hosts"))
    }

    @Test func posixHostsAreCaseSensitiveAndTreatBackslashAsAName() {
        #expect(!posix.covers("/users/me/proj/a.txt"))
        #expect(!posix.covers("/Users/me/proj\\a.txt"))
    }

    @Test func windowsHostsMixSeparatorsAndIgnoreCase() {
        #expect(windows.covers("C:\\Users\\Me\\Proj\\src\\a.cs"))
        #expect(windows.covers("c:/users/me/proj/src/a.cs"))
        #expect(windows.covers("C:\\Users\\Me\\Proj"))
        #expect(windows.covers("C:\\Users\\Me\\Proj\\"))
        #expect(!windows.covers("C:\\Users\\Me\\Project\\a.cs"))
        #expect(!windows.covers("D:\\Users\\Me\\Proj\\a.cs"))
        #expect(!windows.covers("C:\\Users\\Me\\Proj\\..\\x.txt"))
        #expect(!windows.covers("\\\\server\\share\\a.txt"))
        let drive = CompanionContentRoots(paths: ["D:\\"], windows: true)
        #expect(drive.covers("d:/a.txt"))
        #expect(!drive.covers("C:\\a.txt"))
    }

    @Test func emptyRootsOfferRelativePathsOnly() {
        let refs: [CompanionContentReference] = [.file("/Users/me/proj/a.txt"), .file("src/b.txt"), .file("~/c.txt")]
        #expect(CompanionContentReference.offered(refs, richContentAvailable: true) == [.file("src/b.txt")])
        #expect(CompanionContentReference.offered(refs, richContentAvailable: true, roots: posix) == [.file("/Users/me/proj/a.txt"), .file("src/b.txt")])
        #expect(CompanionContentReference.offered(refs, richContentAvailable: false, roots: posix).isEmpty)
    }

    @Test func decodesTheSnapshotField() {
        let snapshot: AnnexJSON = .object(["contentRoots": .array([.string("/a/proj"), .string(""), .integer(3), .string("/a/media")])])
        #expect(CompanionLiveService.contentRoots(from: snapshot, windows: false) == .init(paths: ["/a/proj", "/a/media"]))
        #expect(CompanionLiveService.contentRoots(from: snapshot, windows: true).windows)
        #expect(CompanionLiveService.contentRoots(from: .object([:]), windows: false) == .init())
        #expect(CompanionLiveService.contentRoots(from: .object(["contentRoots": .array([])]), windows: false) == .init())
        #expect(CompanionLiveService.contentRoots(from: .object(["contentRoots": .null]), windows: false) == .init())
    }
}

@MainActor private final class RootsService: CompanionService {
    var roots = CompanionContentRoots()
    var fetched: [CompanionContentReference] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: [], contentRoots: roots) }
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async throws -> CompanionContent {
        fetched.append(reference)
        return .init(kind: "text", name: "a.swift", text: "let a = 1")
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
}

@Suite @MainActor struct CompanionContentRootsStoreTests {
    private let target = CompanionTarget(hostID: "studio", projectID: "p", agentID: "a")

    @Test func rootsFollowEachHistoryLoadAndGateFetches() async throws {
        let service = RootsService()
        let store = CompanionStore(service: service)
        store.apply(.hosts([.init(id: "studio", name: "Studio Mac", endpoint: "studio.local", connection: .connected, projects: [
            .init(id: "p", name: "P", agents: [.init(id: target, name: "A", subtitle: "", status: .working)])
        ], richContentAvailable: true)]))
        service.roots = .init(paths: ["/a/proj"])
        await store.load(target)
        #expect(store.contentRoots(for: target) == .init(paths: ["/a/proj"]))
        _ = try await store.content(.file("/a/proj/x.txt"), target: target)
        #expect(service.fetched == [.file("/a/proj/x.txt")])

        service.roots = .init()
        await store.load(target, force: true)
        #expect(store.contentRoots(for: target) == .init())
        await #expect(throws: (any Error).self) { _ = try await store.content(.file("/a/proj/x.txt"), target: target) }
        #expect(service.fetched.count == 1)
    }
}
