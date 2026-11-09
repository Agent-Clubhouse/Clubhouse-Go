import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Issue 187 local variants are synthetic. Unchanged desktop fixtures are identified by filename.
@Suite struct CompanionContentParityPolicyTests {
    @Test func onlyLiteralTrueEnablesAnyPath() {
        let variants: [AnnexJSON?] = [nil, .bool(false), .null, .string("true"), .integer(1), .array([]), .object([:])]
        for value in variants {
            var fields: [String: AnnexJSON] = ["contentRoots": .array([.string("/a/proj")])]
            fields["contentAnyPath"] = value
            let roots = CompanionLiveService.contentRoots(from: .object(fields), windows: false)
            #expect(!roots.anyPath)
            #expect(CompanionContentReference.file("/a/proj/x.txt").isOffered(roots: roots))
            #expect(!CompanionContentReference.file("/a/project/x.txt").isOffered(roots: roots))
            #expect(!CompanionContentReference.file("/tmp/out.pdf").isOffered(roots: roots))
            #expect(CompanionContentReference.file("../out.txt").isOffered(roots: roots))
        }
        let roots = CompanionLiveService.contentRoots(from: .object(["contentAnyPath": .bool(true)]), windows: false)
        #expect(roots.anyPath && roots.paths.isEmpty)
        #expect(CompanionContentReference.file("/tmp/out.pdf").isOffered(roots: roots))
        #expect(CompanionContentReference.offered([.file("/tmp/out.pdf")], richContentAvailable: false, roots: roots).isEmpty)
    }

    @Test func anyPathKeepsExplicitCandidateGuardsAndDiscoveryScope() {
        let paths = ["", "a\0.txt", String(repeating: "x", count: 1025), "//server/share/a.txt", "\\\\server\\share\\a.txt",
                     "/\\server/share/a.txt", "\\/server/share/a.txt", "\\\\?\\C:\\a.txt", "\\\\.\\pipe\\a.txt",
                     "https://example.test/a.pdf", "smb://server/a.pdf", "file:///tmp/a.pdf", "~someone/a.pdf", "~"]
        for windows in [false, true] {
            let roots = CompanionContentRoots(windows: windows, anyPath: true)
            for path in paths { #expect(!CompanionContentReference.file(path).isOffered(roots: roots)) }
            #expect(CompanionContentReference.file(String(repeating: "x", count: 1024)).isOffered(roots: roots))
            // JS's path length is UTF-16 units, not Swift grapheme clusters.
            #expect(!CompanionContentReference.file(String(repeating: "😀", count: 513)).isOffered(roots: roots))
        }
        let posix = CompanionContentRoots(anyPath: true)
        for path in ["/net", "/net/host/a.txt", "/tmp/../net/host/a.txt", "/net/../tmp/a.txt"] {
            #expect(!CompanionContentReference.file(path).isOffered(roots: posix))
        }
        let text = "`/tmp/a.pdf` `C:\\outside\\a.pdf` `~/a.pdf` [file](file:///tmp/a.pdf) [web](https://example.test/a.pdf)"
        #expect(CompanionContentReference.files(in: text) == [.file("/tmp/a.pdf"), .file("C:\\outside\\a.pdf"), .file("~/a.pdf"), .link("file:///tmp/a.pdf")])
        #expect(CompanionContentReference.file("C:\\outside\\a.pdf").isOffered(roots: .init(windows: true, anyPath: true)))
        #expect(CompanionContentReference.file("c:/proj/a.txt").isOffered(roots: .init(paths: ["C:\\Proj"], windows: true)))
        #expect(!CompanionContentReference.file("/A/Proj/a.txt").isOffered(roots: .init(paths: ["/a/proj"])))
    }

    @Test func desktopHomeScratchFilesAreDiscoveredButRequireAnyPath() {
        let paths = ["~/.clubhouse/scratch/report.pdf", "~\\scratch\\report", "~/scratch/a #é%20.txt"]
        let text = paths.map { "`\($0)`" }.joined(separator: " ")
        let references = paths.map { CompanionContentReference.file($0) }
        #expect(CompanionContentReference.files(in: text) == references)
        for windows in [false, true] {
            #expect(CompanionContentReference.offered(references, richContentAvailable: true,
                roots: .init(windows: windows, anyPath: true)) == references)
            #expect(CompanionContentReference.offered(references, richContentAvailable: true,
                roots: .init(paths: ["/"], windows: windows)).isEmpty)
            #expect(CompanionContentReference.offered(references, richContentAvailable: false,
                roots: .init(windows: windows, anyPath: true)).isEmpty)
        }
        #expect(!CompanionContentReference.isHomeRelative("~another/file.txt"))
    }

    @Test func unchangedContractPagesAlreadyReportAnyPath() throws {
        for name in ["chat-snapshot.json", "chat-snapshot-sleeping.json", "chat-page.json"] {
            let snapshot = try ContractFixtures.body(name)
            #expect(CompanionLiveService.contentRoots(from: snapshot, windows: false).anyPath)
        }
    }
}

@MainActor private final class ContentParityService: CompanionService {
    var policies: [CompanionTarget: CompanionContentRoots] = [:]
    var fetched: [CompanionContentReference] = []
    var holdNextHistory = false
    var heldHistory: CheckedContinuation<Void, Never>?
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async -> CompanionHistory {
        let result = CompanionHistory(items: [], contentRoots: policies[target] ?? .init())
        if holdNextHistory {
            holdNextHistory = false
            await withCheckedContinuation { heldHistory = $0 }
        }
        return result
    }
    func content(_ reference: CompanionContentReference, target: CompanionTarget) async -> CompanionContent {
        fetched.append(reference)
        return .init(kind: "text", name: "a.txt", text: "synthetic")
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
}

@Suite @MainActor struct CompanionContentParityStoreTests {
    private let target = CompanionTarget(hostID: "studio", projectID: "p", agentID: "a")
    private func host(_ id: String, rich: Bool = true, connection: CompanionConnection = .connected) -> CompanionHost {
        .init(id: id, name: id, endpoint: "fixture.invalid", connection: connection, projects: [
            .init(id: "p", name: "P", agents: ["a", "b"].map {
                .init(id: .init(hostID: id, projectID: "p", agentID: $0), name: $0, subtitle: "", status: .working)
            })
        ], richContentAvailable: rich)
    }

    @Test func homePathUsesOwnSnapshotAndPreservesRawReference() async throws {
        let service = ContentParityService(), store = CompanionStore(service: service)
        store.apply(.hosts([host("studio")]))
        let reference = CompanionContentReference.file("~/.clubhouse/scratch/a #é.pdf")
        await store.load(target)
        await #expect(throws: CompanionServiceError.self) { try await store.content(reference, target: target) }
        service.policies[target] = .init(anyPath: true)
        await store.load(target, force: true)
        _ = try await store.content(reference, target: target)
        await #expect(throws: CompanionServiceError.self) {
            try await store.content(reference, target: target, contentRoots: .init())
        }
        service.policies[target] = .init()
        await store.load(target, force: true)
        _ = try await store.content(reference, target: target, contentRoots: .init(anyPath: true))
        for gates in [host("studio", rich: false), host("studio", connection: .offline)] {
            store.apply(.hosts([gates]))
            await #expect(throws: CompanionServiceError.self) {
                try await store.content(reference, target: target, contentRoots: .init(anyPath: true))
            }
        }
        #expect(service.fetched == [reference, reference])
    }

    @Test func newerPolicyReplacesOlderPolicyAndDoesNotLeakAcrossTargetsOrHosts() async throws {
        let service = ContentParityService(), store = CompanionStore(service: service)
        store.apply(.hosts([host("studio"), host("other")]))
        service.policies[target] = .init(anyPath: true)
        await store.load(target)
        _ = try await store.content(.file("/tmp/out.pdf"), target: target)
        for other in [CompanionTarget(hostID: "studio", projectID: "p", agentID: "b"),
                      CompanionTarget(hostID: "other", projectID: "p", agentID: "a")] {
            await store.load(other)
            await #expect(throws: CompanionServiceError.self) { try await store.content(.file("/tmp/out.pdf"), target: other) }
        }
        service.policies[target] = .init(paths: ["/a/proj"])
        await store.load(target, force: true)
        #expect(!store.contentRoots(for: target).anyPath)
        await #expect(throws: CompanionServiceError.self) { try await store.content(.file("/tmp/out.pdf"), target: target) }
        _ = try await store.content(.file("/a/proj/x.txt"), target: target)
        service.policies[target] = .init(anyPath: true)
        await store.load(target, force: true)
        _ = try await store.content(.file("/tmp/out.pdf"), target: target)
        #expect(service.fetched == [.file("/tmp/out.pdf"), .file("/a/proj/x.txt"), .file("/tmp/out.pdf")])
        store.apply(.hosts([host("other")]))
        #expect(store.contentRoots(for: target) == .init(), "Removing a conversation makes its old hint inactive")
    }

    @Test func obsoleteHistoryCannotRestoreAnyPath() async throws {
        let service = ContentParityService(), store = CompanionStore(service: service)
        store.apply(.hosts([host("studio")]))
        service.policies[target] = .init(anyPath: true)
        service.holdNextHistory = true
        let oldLoad = Task { await store.load(target) }
        // The synthetic service has no IO before suspending; wait for that boundary with a finite budget.
        for _ in 0..<1000 {
            if service.heldHistory != nil { break }
            await Task.yield()
        }
        guard let held = service.heldHistory else {
            service.holdNextHistory = false
            oldLoad.cancel()
            await oldLoad.value
            Issue.record("History did not pause")
            return
        }
        service.policies[target] = .init()
        await store.load(target, force: true)
        held.resume()
        await oldLoad.value
        #expect(!store.contentRoots(for: target).anyPath)
        await #expect(throws: CompanionServiceError.self) { try await store.content(.file("/tmp/out.pdf"), target: target) }
        #expect(service.fetched.isEmpty)
    }

    @Test func archiveOverrideStaysSeparateAndStillNeedsCurrentHostGates() async throws {
        let service = ContentParityService(), store = CompanionStore(service: service)
        store.apply(.hosts([host("studio")]))
        service.policies[target] = .init(anyPath: true)
        await store.load(target)
        let live = store.conversation(for: target)
        await #expect(throws: CompanionServiceError.self) {
            try await store.content(.file("/tmp/out.pdf"), target: target, contentRoots: .init())
        }
        #expect(store.contentRoots(for: target).anyPath && store.conversation(for: target) == live)
        service.policies[target] = .init()
        await store.load(target, force: true)
        _ = try await store.content(.file("/tmp/out.pdf"), target: target, contentRoots: .init(anyPath: true))
        #expect(!store.contentRoots(for: target).anyPath)
        for gates in [host("studio", rich: false), host("studio", connection: .offline)] {
            store.apply(.hosts([gates]))
            await #expect(throws: CompanionServiceError.self) {
                try await store.content(.file("/tmp/out.pdf"), target: target, contentRoots: .init(anyPath: true))
            }
        }
        #expect(service.fetched == [.file("/tmp/out.pdf")])
    }
}

@Suite @MainActor struct CompanionContentParityServiceTests {
    private func harness() async throws -> LiveServiceHarness {
        try await LiveServiceHarness.start { await $0.setCapability("richContent", .object(["enabled": .bool(true)])) }
    }

    @Test func pdfAndUnknownKindsPreserveBoundsButOnlyKnownKindsCarryActiveContent() async throws {
        let h = try await harness()
        defer { h.stop() }
        // Synthetic bytes with a PDF header, not a complete renderable PDF or captured desktop response.
        let data = Data("%PDF-1.7\nsynthetic".utf8)
        await h.transport.setRead("chatContent", .object(["kind": .string("pdf"), "name": .string("out.pdf"),
            "mimeType": .string("application/pdf"), "base64": .string(data.base64EncodedString())]))
        let pdf = try await h.service.content(.file("out.pdf"), target: h.target)
        #expect(pdf.kind == "pdf" && pdf.bytes == data && pdf.mimeType == "application/pdf" && pdf.text == nil)
        await h.transport.setRead("chatContent", .object(["kind": .string("pdf"), "name": .string("large.pdf"), "tooLarge": .bool(true)]))
        let large = try await h.service.content(.file("large.pdf"), target: h.target)
        #expect(large.kind == "pdf" && large.tooLarge && large.bytes == nil && large.pdfBytes == nil)
        #expect(pdf.pdfBytes == data)
        for kind in ["hologram", "other"] {
            await h.transport.setRead("chatContent", .object(["kind": .string(kind), "name": .string("future.bin"),
                "mimeType": .string("image/svg+xml"), "text": .string("not a text preview"),
                "base64": .string(data.base64EncodedString()), "truncated": .bool(true)]))
            let content = try await h.service.content(.file("future.bin"), target: h.target)
            #expect(content.kind == "other" && content.name == "future.bin" && content.pdfBytes == nil)
            if kind == "other" {
                #expect(content.bytes == data && content.text != nil && content.mimeType == "image/svg+xml" && content.truncated)
            } else {
                #expect(content.bytes == nil && content.text == nil && content.mimeType == nil && !content.truncated)
            }
        }
        let malformed: [AnnexJSON] = [
            .object(["name": .string("a.bin")]), .object(["kind": .integer(1), "name": .string("a.bin")]),
            .object(["kind": .string("hologram"), "name": .integer(1)]),
            .object(["kind": .string("hologram"), "name": .string("a.bin"), "base64": .string("bad!")])
        ]
        for response in malformed {
            await h.transport.setRead("chatContent", response)
            await #expect(throws: CompanionServiceError.self) { try await h.service.content(.file("a.bin"), target: h.target) }
        }
    }

    @Test func onlyABoundedPDFKindReachesPDFKit() {
        // Synthetic header bytes; whether PDFKit can open them is the hosted app tests' concern.
        let data = Data("%PDF-1.7\nsynthetic".utf8)
        #expect(CompanionContent(kind: "pdf", name: "a.pdf", bytes: data).pdfBytes == data)
        #expect(CompanionContent(kind: "pdf", name: "a.pdf", bytes: data, tooLarge: true).pdfBytes == nil)
        #expect(CompanionContent(kind: "pdf", name: "a.pdf").pdfBytes == nil)
        let limit = Data(count: 8 * 1024 * 1024)
        #expect(CompanionContent(kind: "pdf", name: "a.pdf", bytes: limit).pdfBytes?.count == limit.count)
        #expect(CompanionContent(kind: "pdf", name: "a.pdf", bytes: limit + Data([0])).pdfBytes == nil)
        for kind in ["other", "text", "image", "video", "audio"] {
            #expect(CompanionContent(kind: kind, name: "a.pdf", mimeType: "application/pdf", bytes: data).pdfBytes == nil)
        }
    }

    @Test func pdfAtMobileLimitAndUnknownOverLimitUseExistingCaps() async throws {
        let h = try await harness()
        defer { h.stop() }
        let atLimit = Data(repeating: 0, count: 8 * 1024 * 1024)
        await h.transport.setRead("chatContent", .object(["kind": .string("pdf"), "name": .string("limit.pdf"),
            "base64": .string(atLimit.base64EncodedString())]))
        #expect(try await h.service.content(.file("limit.pdf"), target: h.target).bytes?.count == atLimit.count)
        for encoded in [Data(count: 8 * 1024 * 1024 + 1).base64EncodedString(), String(repeating: "A", count: 12 * 1024 * 1024 + 4)] {
            await h.transport.setRead("chatContent", .object(["kind": .string("hologram"), "name": .string("large.bin"), "base64": .string(encoded)]))
            await #expect(throws: CompanionServiceError.self) { try await h.service.content(.file("large.bin"), target: h.target) }
        }
    }

    @Test func invalidDirectServicePathsNeverReachContentRoute() async throws {
        let h = try await harness()
        defer { h.stop() }
        for path in ["", "x\0.txt", String(repeating: "x", count: 1025), "//host/share/a.txt", "\\\\?\\C:\\a.txt",
                     "/net/host/a.txt", "https://example.test/a.txt", "file:///tmp/a.txt", "~other/a.txt"] {
            await #expect(throws: CompanionServiceError.self) { try await h.service.content(.file(path), target: h.target) }
        }
        #expect(await !h.transport.readRoutes.contains { $0.name == "chatContent" })
    }

    @Test func directServiceForwardsDesktopHomePathWithoutExpansion() async throws {
        let h = try await harness()
        defer { h.stop() }
        await h.transport.setRead("chatContent", .object(["kind": .string("text"), "name": .string("scratch.txt"), "text": .string("Scratch preview")]))
        for path in ["~/scratch/a #é%20.txt", "~\\scratch\\a.txt"] {
            let result = try await h.service.content(.file(path), target: h.target)
            #expect(result.text == "Scratch preview")
            let routes = await h.transport.readRoutes
            guard let route = routes.last else {
                Issue.record("Expected a content route")
                return
            }
            #expect(route.name == "chatContent" && route.mediaRef == nil && route.filePath == path)
        }
    }

    @Test func coldArchiveUsesItsOwnSnapshotAndOmissionRevokesOnlyArchivePolicy() async throws {
        let h = try await harness()
        defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["contentAnyPath": .bool(true)]))
        await h.store.load(h.target)
        let live = h.store.conversation(for: h.target)
        let archive = try h.store.archive(for: h.target, sessionID: "old")
        #expect(!archive.contentRoots.anyPath)
        let first = LiveServiceHarness.chatSnapshot(session: "old", fields: ["readOnly": .bool(true),
            "capabilities": .null, "contentAnyPath": .bool(true), "contentRoots": .array([.string("/archive")]), "nextBeforeSeq": .integer(10)])
        await h.transport.setRead("chatHistory", first)
        await archive.loadEarlier()
        #expect(archive.contentRoots == .init(paths: ["/archive"], anyPath: true))
        await h.transport.failRead("chatHistory", .disconnected)
        await archive.loadEarlier()
        #expect(archive.contentRoots.anyPath && archive.nextBeforeSequence == 10 && archive.error != nil)
        await h.transport.setRead("chatHistory", LiveServiceHarness.chatSnapshot(session: "old", fields: ["readOnly": .bool(true), "capabilities": .null]))
        await archive.loadEarlier()
        #expect(archive.error == nil && archive.contentRoots == .init())
        #expect(h.store.contentRoots(for: h.target).anyPath && h.store.conversation(for: h.target) == live)
        // Reading the archive did not replace the service's live command session either.
        _ = try await h.service.send(.init(target: h.target, text: "current", clientCommandID: "current-command", isSteering: false))
        #expect(await h.transport.executed.last?.kind == .send(agentID: "agent", sessionID: "s1", text: "current", delivery: .auto))
    }

    @Test func archiveUsesReportedHostPlatformWithoutBorrowingLiveAnyPath() async throws {
        let h = try await harness()
        defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["contentAnyPath": .bool(true)]))
        await h.transport.emit(h.snapshotEvent(["ptyHost": .object(["platform": .string("win32")])]))
        try await h.waitUntil {
            await h.store.load(h.target, force: true)
            return h.store.contentRoots(for: h.target).windows
        }
        await h.transport.setRead("chatHistory", LiveServiceHarness.chatSnapshot(session: "old", fields: [
            "contentAnyPath": .bool(false), "contentRoots": .array([.string("C:\\Archive")])]))
        let archive = try h.store.archive(for: h.target, sessionID: "old")
        await archive.loadEarlier()
        #expect(archive.contentRoots == .init(paths: ["C:\\Archive"], windows: true))
        #expect(CompanionContentReference.file("c:/archive/a.pdf").isOffered(roots: archive.contentRoots))
        #expect(!CompanionContentReference.file("D:\\outside\\a.pdf").isOffered(roots: archive.contentRoots))
        #expect(h.store.contentRoots(for: h.target).anyPath)
    }
}
