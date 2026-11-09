import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionLocalLinkTests {
    @Test func hrefFormsKeepDesktopSpellingOrder() {
        let forms: [(String, [String])] = [
            ("src/main.swift", ["src/main.swift"]),
            ("../README.md", ["../README.md"]),
            ("README", ["README"]),
            ("Some%20Folder/summary.md#next", ["Some%20Folder/summary.md#next", "Some Folder/summary.md#next", "Some%20Folder/summary.md", "Some Folder/summary.md"]),
            ("notes.md#intro", ["notes.md#intro", "notes.md"]),
            ("file:///tmp/Some%20Folder/a.md#intro", ["/tmp/Some Folder/a.md"]),
            ("FILE://localhost/tmp/a.md", ["/tmp/a.md"]),
            ("~/scratch/a.md", ["~/scratch/a.md"]),
            ("/tmp/a.md", ["/tmp/a.md"]),
            (#"C:\outside\a.md"#, [#"C:\outside\a.md"#]),
            ("notes%invalid.md", ["notes%invalid.md"])
        ]
        for (href, expected) in forms {
            #expect(CompanionContentReference.linkPaths(href) == expected)
            #expect(CompanionContentReference.files(in: "[target](\(href))") == [.link(href)])
        }
        #expect(CompanionContentReference.linkPaths("file:///C:/Some%20Folder/a.md", windows: true) == ["C:/Some Folder/a.md"])
        #expect(CompanionContentReference.linkPaths(String(repeating: " ", count: 1024) + "a").isEmpty)
        #expect(CompanionContentReference.files(in: "`~/a #é%20.md`") == [.file("~/a #é%20.md")])
    }

    @Test func webAnchorsAndNetworkDevicePathsAreSeparate() {
        for href in ["", " ", "#intro", "?query=1", "https://example.test/a.md", "mailto:a@b.test", "javascript:alert", "data:text/html,x", "vscode://file/a", "smb://server/a", "//server/share/a", #"\\server\share\a"#, #"/\server\a"#, #"\\?\C:\a"#, #"\\.\pipe\a"#, "file://server/share/a", "file://user@localhost/tmp/a", "file://localhost:123/tmp/a", "file:///net/host/a", "/net/host/a", "/tmp/../net/host/a", "~other/a", "a\0.md", "a\r.md", "a\n.md", String(repeating: "😀", count: 513)] {
            #expect(CompanionContentReference.linkPaths(href).isEmpty, "Refuse \(href.debugDescription)")
            #expect(!CompanionContentReference.link(href).isOffered(roots: .init(anyPath: true)))
        }
        for href in ["https://example.test/a.md", "mailto:a@b.test", "#intro", "//server/share/a", "file://server/share/a"] {
            #expect(CompanionContentReference.files(in: "[target](\(href))").isEmpty)
        }
    }

    @Test func linksStillNeedNegotiatedPathsAndRichContent() {
        let relative = CompanionContentReference.link("Some%20Folder/a.md#intro")
        let absolute = CompanionContentReference.link("file:///tmp/a.md")
        let home = CompanionContentReference.link("~/scratch/a.md")
        #expect(relative.isOffered(roots: .init()))
        #expect(!absolute.isOffered(roots: .init()))
        #expect(!home.isOffered(roots: .init(paths: ["/Users/me"])))
        #expect(absolute.isOffered(roots: .init(paths: ["/tmp"])))
        #expect(absolute.isOffered(roots: .init(anyPath: true)))
        #expect(home.isOffered(roots: .init(anyPath: true)))
        #expect(CompanionContentReference.offered([relative, absolute, home], richContentAvailable: false, roots: .init(anyPath: true)).isEmpty)
    }

    private static let chatLinks: AnnexJSON = .object(["version": .integer(1), "maxEntries": .integer(500),
                                                       "path": .string("/api/v1/mobile/agents/{agentId}/link?href={href}")])
    private static func harness(chatLinks: Bool = true) async throws -> LiveServiceHarness {
        try await LiveServiceHarness.start {
            await $0.setCapability("richContent", .object(["enabled": .bool(true)]))
            if chatLinks { await $0.setCapability("chatLinks", Self.chatLinks) }
        }
    }

    @Test func everyRecordedAnswerDecodes() throws {
        #expect(try CompanionLinkTarget(json: ContractFixtures.body("chat-links.json", "file"))
                == .file(path: "/work/app/docs/guide.md", name: "guide.md", kind: "text", size: 1234))
        #expect(try CompanionLinkTarget(json: ContractFixtures.body("chat-links.json", "plusInName"))
                == .file(path: "/work/app/docs/C++ notes.md", name: "C++ notes.md", kind: "text", size: 88))
        #expect(try CompanionLinkTarget(json: ContractFixtures.body("chat-links.json", "image"))
                == .file(path: "/work/app/docs/screenshot.png", name: "screenshot.png", kind: "image", size: 48213))
        #expect(try CompanionLinkTarget(json: ContractFixtures.body("chat-links.json", "missing")) == .missing)
        #expect(try CompanionLinkTarget(json: ContractFixtures.body("chat-links.json", "notAllowed")) == .notAllowed)
        let docs = CompanionFolderListing(path: "/work/app/docs", name: "docs", entries: [
            .init(name: "guide.md", kind: .file, size: 1234), .init(name: "images", kind: .directory),
            .init(name: "latest.md", kind: .symlink), .init(name: "screenshot.png", kind: .file, size: 48213)
        ], truncated: false)
        #expect(try CompanionLinkTarget(json: ContractFixtures.body("chat-links.json", "directory")) == .directory(docs))
        #expect(try CompanionLinkTarget(json: ContractFixtures.body("chat-links.json", "directoryEncoded"))
                == .directory(.init(path: "/work/app/Release Notes", name: "Release Notes", entries: [], truncated: false)))
        #expect(docs.entries.map(docs.path(of:)) == ["/work/app/docs/guide.md", "/work/app/docs/images", "/work/app/docs/latest.md", "/work/app/docs/screenshot.png"])
    }

    @Test func listingsAreBoundedAndEntriesJoinWithTheHostSeparator() throws {
        func entry(_ name: AnnexJSON, _ kind: String = "file", size: AnnexJSON? = nil) -> AnnexJSON {
            var value: [String: AnnexJSON] = ["name": name, "kind": .string(kind)]
            value["size"] = size
            return .object(value)
        }
        let raw: [AnnexJSON] = [entry(.string("a.md"), size: .integer(1)), entry(.string("dir"), "directory", size: .integer(9)),
                                entry(.string("pipe"), "fifo"), entry(.string("../up")), entry(.string(".")), entry(.string(#"a\b"#)),
                                entry(.integer(1))] + (0..<600).map { entry(.string("f\($0)")) }
        let body: AnnexJSON = .object(["version": .integer(1), "type": .string("directory"), "path": .string(#"C:\work"#),
                                       "name": .string("work"), "entries": .array(raw), "truncated": .bool(false)])
        guard case .directory(let listing) = try CompanionLinkTarget(json: body, windows: true) else { Issue.record("directory"); return }
        #expect(listing.truncated, "More than the desktop's cap is still more")
        #expect(listing.entries.count <= CompanionFolderListing.maximumEntries)
        #expect(listing.entries.prefix(3) == [.init(name: "a.md", kind: .file, size: 1), .init(name: "dir", kind: .directory), .init(name: "pipe", kind: .other)])
        #expect(!listing.entries.contains { $0.name.contains("/") || $0.name.contains("\\") || $0.name == "." })
        #expect(listing.path(of: listing.entries[0]) == #"C:\work\a.md"#)
        #expect(!listing.entries[2].opens && listing.entries[0].opens)
        #expect(CompanionFolderListing(path: "/", name: "/", entries: [], truncated: false).path(of: .init(name: "tmp", kind: .directory)) == "/tmp")
        for bad: AnnexJSON in [.object(["version": .integer(2), "type": .string("missing")]), .object(["version": .integer(1), "type": .string("socket")]),
                               .object(["version": .integer(1), "type": .string("file"), "name": .string("a")]),
                               .object(["version": .integer(1), "type": .string("directory"), "path": .string("/a"), "name": .string("a")])] {
            #expect(throws: AnnexTransportError.malformedResponse) { try CompanionLinkTarget(json: bad) }
        }
    }

    @Test func aFileLinkIsResolvedOnTheDesktopThenReadAtItsRealPath() async throws {
        let h = try await Self.harness()
        defer { h.stop() }
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "plusInName"))
        await h.transport.setRead("chatContent", .object(["kind": .string("text"), "name": .string("C++ notes.md"), "text": .string("Synthetic")]))
        let content = try await h.store.content(.link("docs/C++ notes.md#intro"), target: h.target)
        #expect(content.text == "Synthetic")
        let routes = await h.transport.readRoutes.filter { ["chatLink", "chatContent"].contains($0.name) }
        // One resolve with the href as written, then one read: no phone-side spelling candidates.
        #expect(routes.map(\.name) == ["chatLink", "chatContent"])
        #expect(routes.first?.href == "docs/C++ notes.md#intro")
        #expect(routes.last?.filePath == "/work/app/docs/C++ notes.md")
        #expect(await h.transport.executed.isEmpty, "No desktop shell/Finder command")
    }

    @Test func aFolderLinkListsAndItsEntriesResolveAgain() async throws {
        let h = try await Self.harness()
        defer { h.stop() }
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "directory"))
        let content = try await h.store.content(.link("docs/"), target: h.target)
        let folder = try #require(content.folder)
        #expect(content.kind == "folder" && content.name == "docs" && folder.entries.count == 4 && !folder.truncated)
        #expect(await h.transport.readRoutes.filter { $0.name == "chatContent" }.isEmpty, "A folder is never read as a file")
        // An absolute entry path skips the conversation's path hints: the desktop listed it and authorizes the read.
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "image"))
        await h.transport.setRead("chatContent", .object(["kind": .string("text"), "name": .string("x"), "text": .string("entry")]))
        #expect(try await h.store.linkContent(folder.path(of: folder.entries[3]), target: h.target).text == "entry")
        #expect(await h.transport.readRoutes.compactMap(\.href).last == "/work/app/docs/screenshot.png")
    }

    @Test func missingAndNotAllowedAreNamedWithoutAmbiguity() async throws {
        let h = try await Self.harness()
        defer { h.stop() }
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "missing"))
        await #expect(throws: CompanionLinkError.missing(hostName: "Fixture")) { try await h.store.content(.link("docs/old.md"), target: h.target) }
        #expect(CompanionLinkError.missing(hostName: "Fixture").localizedDescription == "Not found on Fixture")
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "notAllowed"))
        await #expect(throws: CompanionLinkError.notAllowed) { try await h.store.content(.link("private/a.md"), target: h.target) }
        #expect(CompanionLinkError.notAllowed.localizedDescription == "Not shared with the phone")
        // The service path words them the same way.
        await #expect(throws: CompanionLinkError.notAllowed) { try await h.service.content(.link("private/a.md"), target: h.target) }
        #expect(await h.transport.readRoutes.filter { $0.name == "chatContent" }.isEmpty)
    }

    @Test func routeRefusalsAreWorded() async throws {
        let h = try await Self.harness()
        defer { h.stop() }
        func refused(_ error: AnnexTransportError) async -> String? {
            await h.transport.failRead("chatLink", error)
            do { _ = try await h.store.content(.link("a.md"), target: h.target); return nil } catch { return error.localizedDescription }
        }
        #expect(await refused(.rejected(status: 404, code: "agent_not_found")) == "This agent is no longer on Fixture.")
        #expect(await refused(.rejected(status: 404, code: "content_unavailable"))?.hasPrefix("Rich chat content is off on Fixture.") == true)
        #expect(await refused(.rejected(status: 404, code: "not_found")) == CompanionContentReference.linksNeedUpdate)
        #expect(await refused(.rejected(status: 400, code: "invalid_query")) == "This link can't be opened from the phone. Open it on Fixture.")
        await h.transport.setRead("chatLink", .object(["version": .integer(1), "type": .string("socket")]))
        await #expect(throws: CompanionServiceError.self) { try await h.store.content(.link("a.md"), target: h.target) }
    }

    @Test func aDesktopWithoutChatLinksIsAskedToUpdate() async throws {
        let h = try await Self.harness(chatLinks: false)
        defer { h.stop() }
        #expect(h.host?.canResolveLinks == false)
        do { _ = try await h.store.content(.link("a.md"), target: h.target); Issue.record("Needs chatLinks") }
        catch { #expect(error.localizedDescription == CompanionContentReference.linksNeedUpdate) }
        await #expect(throws: CompanionServiceError.self) { try await h.service.resolveLink("a.md", target: h.target) }
        #expect(await h.transport.readRoutes.filter { ["chatLink", "chatContent"].contains($0.name) }.isEmpty)
    }

    @Test func linksStillNeedTheConversationsOwnHints() async throws {
        let h = try await Self.harness()
        defer { h.stop() }
        #expect(h.host?.canResolveLinks == true)
        // Absolute and file: links need the snapshot's any-path hint before anything is asked of the desktop.
        await #expect(throws: CompanionServiceError.self) { try await h.store.content(.link("file:///tmp/a.md"), target: h.target) }
        #expect(await h.transport.readRoutes.filter { $0.name == "chatLink" }.isEmpty)
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["contentAnyPath": .bool(true)]))
        await h.store.load(h.target)
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "missing"))
        await #expect(throws: CompanionLinkError.self) { try await h.store.content(.link("file:///tmp/Some%20Folder/a.md#intro"), target: h.target) }
        #expect(await h.transport.readRoutes.compactMap(\.href) == ["file:///tmp/Some%20Folder/a.md#intro"])
    }

    @Test func codeSpanPathsResolveLikeLinks() async throws {
        let h = try await Self.harness()
        defer { h.stop() }
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "file"))
        await h.transport.setRead("chatContent", .object(["kind": .string("text"), "name": .string("guide.md"), "text": .string("Synthetic")]))
        #expect(try await h.store.content(.file("docs/guide.md"), target: h.target).text == "Synthetic")
        var routes = await h.transport.readRoutes.filter { ["chatLink", "chatContent"].contains($0.name) }
        #expect(routes.map(\.name) == ["chatLink", "chatContent"])
        #expect(routes.first?.href == "docs/guide.md" && routes.last?.filePath == "/work/app/docs/guide.md")

        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "directory"))
        let folder = try await h.store.content(.file("docs/"), target: h.target)
        #expect(folder.kind == "folder" && folder.folder?.entries.count == 4)
        await h.transport.setRead("chatLink", try ContractFixtures.body("chat-links.json", "missing"))
        await #expect(throws: CompanionLinkError.missing(hostName: "Fixture")) { try await h.store.content(.file("docs/old.md"), target: h.target) }
        routes = await h.transport.readRoutes.filter { $0.name == "chatContent" }
        #expect(routes.count == 1, "Neither a folder nor a missing path is read as a file")
        // Path hints still gate a code span before the desktop is asked.
        await #expect(throws: CompanionServiceError.self) { try await h.store.content(.file("/tmp/a.md"), target: h.target) }
        #expect(await h.transport.readRoutes.compactMap(\.href).last == "docs/old.md")
    }

    @Test func codeSpanPathsReadThroughContentWithoutTheRoute() async throws {
        let h = try await Self.harness(chatLinks: false)
        defer { h.stop() }
        await h.transport.setRead("chatContent", .object(["kind": .string("text"), "name": .string("a.md"), "text": .string("direct")]))
        #expect(try await h.store.content(.file("docs/a.md"), target: h.target).text == "direct")
        #expect(await h.transport.readRoutes.filter { $0.name == "chatLink" }.isEmpty)
        #expect(await h.transport.readRoutes.last { $0.name == "chatContent" }?.filePath == "docs/a.md")
    }
}
