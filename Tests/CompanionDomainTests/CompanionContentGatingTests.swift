import Foundation
import Testing
@testable import CompanionDomain
@testable import ClubhouseTransport

@MainActor private final class ContentService: CompanionService {
    var fetched: [CompanionContentReference] = []
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
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

private let mediaRef = String(repeating: "b", count: 64) + ".png"

@Suite struct CompanionContentLinkFilteringTests {
    @Test func absoluteAndHomePathsAreNotOffered() {
        let text = "`/tmp/apple-shot.kqtP/apple.png` `~/Desktop/notes.md` `C:\\Users\\me\\a.txt` `C:/Users/me/b.txt` `src/app.swift` [log](build/test.log) `./README.md`"
        // Absolute paths are candidates for the agent's content roots; home paths never are.
        let files = CompanionContentReference.files(in: text)
        #expect(files == [.file("/tmp/apple-shot.kqtP/apple.png"), .file("C:\\Users\\me\\a.txt"), .file("C:/Users/me/b.txt"),
                          .file("src/app.swift"), .file("build/test.log"), .file("./README.md")])
        #expect(CompanionContentReference.offered(files, richContentAvailable: true) == [.file("src/app.swift"), .file("build/test.log"), .file("./README.md")])
    }

    @Test func onlyRelativePathsCountAsInsideTheAgentsFolders() {
        for inside in ["src/a.swift", "README.md", "./docs/x.md"] { #expect(CompanionContentReference.isInsideAgentFolders(inside)) }
        for outside in ["/tmp/apple.png", "/Users/me/project/a.swift", "~/a.txt", "~", "C:\\a.txt", "c:/a.txt", "\\\\server\\share", ""] {
            #expect(!CompanionContentReference.isInsideAgentFolders(outside))
        }
    }

    @Test func toolReferencesAreDedupedAndStable() {
        let tool = CompanionTool(id: "t", name: "Read", summary: "", output: "`b.txt` `a.txt` `b.txt` `/tmp/x.png`", state: .completed, images: [.image(mediaRef), .image(mediaRef)])
        #expect(CompanionContentReference.references(in: .tool(tool)) == [.file("/tmp/x.png"), .file("a.txt"), .file("b.txt"), .image(mediaRef)])
    }

    @Test func onlyAssistantMessagesOfferFileLinks() {
        let assistant = CompanionMessage(id: "a", role: .assistant, text: "See `src/a.swift`")
        let user = CompanionMessage(id: "u", role: .user, text: "Open `src/a.swift`")
        #expect(CompanionContentReference.references(in: .message(assistant)) == [.file("src/a.swift")])
        #expect(CompanionContentReference.references(in: .message(user)).isEmpty)
        #expect(CompanionContentReference.references(in: .notice(id: "n", text: "`src/a.swift`")).isEmpty)
    }

    @Test func foldedToolGroupsCollectTheirToolsReferences() {
        let a = CompanionTool(id: "a", name: "Read", summary: "", output: "`a.txt`", state: .completed)
        let b = CompanionTool(id: "b", name: "Read", summary: "", output: nil, state: .completed, images: [.image(mediaRef)])
        #expect(CompanionContentReference.references(in: CompanionTimelineRow.tools([a, b])) == [.file("a.txt"), .image(mediaRef)])
    }
}

@Suite struct CompanionContentGatingTests {
    private let rows: [CompanionTimelineRow] = [
        .item(.message(.init(id: "1", role: .assistant, text: "Wrote `a.txt`"))),
        .item(.message(.init(id: "2", role: .assistant, text: "Nothing to open"))),
        .item(.tool(.init(id: "t", name: "Read", summary: "", output: nil, state: .running, images: [.image(mediaRef)]))),
        .item(.message(.init(id: "3", role: .user, text: "`b.txt`")))
    ]

    @Test func linksAreHiddenWhenRichContentIsOff() {
        #expect(CompanionContentReference.offered([.file("a.txt"), .image(mediaRef)], richContentAvailable: false).isEmpty)
        #expect(CompanionContentReference.offered([.file("a.txt")], richContentAvailable: true) == [.file("a.txt")])
    }

    @Test func oneHintSitsUnderTheLatestRowThatWouldHaveHadLinks() {
        #expect(CompanionContentReference.hintRowID(in: rows, richContentAvailable: false) == "tool:t")
        #expect(CompanionContentReference.hintRowID(in: rows, richContentAvailable: true) == nil)
        #expect(CompanionContentReference.hintRowID(in: [rows[1], rows[3]], richContentAvailable: false) == nil)
        // A row with only an absolute path had nothing to offer, since the roots are empty while the setting is off.
        let absolute: CompanionTimelineRow = .item(.message(.init(id: "4", role: .assistant, text: "Wrote `/tmp/x.txt`")))
        #expect(CompanionContentReference.hintRowID(in: [rows[0], absolute], richContentAvailable: false) == rows[0].id)
    }

    @Test func hintNamesTheDesktopSetting() {
        #expect(CompanionContentReference.richContentOffHint.contains("Rich chat content"))
        #expect(CompanionContentReference.richContentOffHint.contains("Experimental settings"))
    }
}

@Suite @MainActor struct CompanionContentStoreTests {
    private let target = CompanionTarget(hostID: "studio", projectID: "p", agentID: "a")
    private func store(rich: Bool, connection: CompanionConnection = .connected) -> (CompanionStore, ContentService) {
        let service = ContentService()
        let store = CompanionStore(service: service)
        store.apply(.hosts([.init(id: "studio", name: "Studio Mac", endpoint: "studio.local", connection: connection, projects: [
            .init(id: "p", name: "P", agents: [.init(id: target, name: "A", subtitle: "", status: .working)])
        ], richContentAvailable: rich)]))
        return (store, service)
    }
    private func message(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch { return error.localizedDescription }
    }

    @Test func storeReportsWhetherLinksCanBeOffered() {
        #expect(store(rich: true).0.richContentAvailable(for: target))
        #expect(!store(rich: false).0.richContentAvailable(for: target))
    }

    @Test func richContentOffNamesTheDesktopAndNeverFetches() async {
        let (store, service) = store(rich: false)
        let error = await message { _ = try await store.content(.file("a.txt"), target: target) }
        #expect(error?.contains("Rich chat content is off on Studio Mac") == true)
        #expect(service.fetched.isEmpty)
    }

    @Test func pathsOutsideTheAgentsFoldersAreRefusedWithAReason() async {
        let (store, service) = store(rich: true)
        let error = await message { _ = try await store.content(.file("/tmp/apple-shot/apple.png"), target: target) }
        #expect(error?.contains("outside the agent's folders") == true)
        #expect(service.fetched.isEmpty)
    }

    @Test func offlineAsksToReconnect() async {
        let (store, service) = store(rich: true, connection: .offline)
        let error = await message { _ = try await store.content(.file("a.txt"), target: target) }
        #expect(error?.contains("Reconnect") == true)
        #expect(service.fetched.isEmpty)
    }

    @Test func allowedContentIsFetched() async throws {
        let (store, service) = store(rich: true)
        _ = try await store.content(.file("src/a.swift"), target: target)
        _ = try await store.content(.image(mediaRef), target: target)
        #expect(service.fetched == [.file("src/a.swift"), .image(mediaRef)])
    }
}

@Suite @MainActor struct CompanionContentErrorMessageTests {
    @Test func desktopRefusalsBecomeSpecificMessages() {
        let missingFile = CompanionLiveService.contentErrorMessage(AnnexTransportError.rejected(status: 404, code: "content_unavailable"), reference: .file("a.txt"), hostName: "Studio Mac")
        #expect(missingFile.contains("Studio Mac") && missingFile.contains("agent's folders"))
        let missingImage = CompanionLiveService.contentErrorMessage(AnnexTransportError.rejected(status: 404, code: "content_unavailable"), reference: .image(mediaRef), hostName: "Studio Mac")
        #expect(missingImage.contains("image") && missingImage.contains("Studio Mac"))
        let agentGone = CompanionLiveService.contentErrorMessage(AnnexTransportError.rejected(status: 404, code: "agent_not_found"), reference: .file("a.txt"), hostName: "Studio Mac")
        #expect(agentGone.contains("agent"))
        #expect(CompanionLiveService.contentErrorMessage(AnnexTransportError.responseTooLarge, reference: .file("a.txt"), hostName: "Studio Mac").contains("too large"))
        #expect(CompanionLiveService.contentErrorMessage(AnnexTransportError.forbidden, reference: .file("a.txt"), hostName: "Studio Mac").contains("Pair"))
    }
}

@Suite @MainActor struct CompanionPreviewContentTests {
    @Test func previewDesktopOffersAndOpensSampleFiles() async throws {
        let service = CompanionPreviewService()
        let store = CompanionStore(service: service)
        let events = service.events()
        for await event in events { store.apply(event); break }
        #expect(store.richContentAvailable(for: CompanionPreviewService.target))
        let value = try await store.content(.file("Sources/Companion/Conversation.swift"), target: CompanionPreviewService.target)
        #expect(value.kind == "text" && value.text?.isEmpty == false)
    }
}
