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

    @Test func encodedAndAnchoredLinkUsesExistingPreviewRouteCandidates() async throws {
        let link = CompanionContentReference.link("Some%20Folder/a.md#intro")
        var fetched: [CompanionContentReference] = []
        let content = try await link.loadLink(roots: .init()) { reference in
            fetched.append(reference)
            guard reference == .file("Some Folder/a.md") else {
                throw CompanionContentError.unavailable("synthetic missing")
            }
            return .init(kind: "text", name: "a.md", text: "# Synthetic preview")
        }
        #expect(content.text == "# Synthetic preview")
        #expect(fetched == CompanionContentReference.linkPaths("Some%20Folder/a.md#intro").map { .file($0) })
    }

    @Test func literalFilenamesWinAndOtherFailuresNeverTriggerFallback() async throws {
        var fetched: [CompanionContentReference] = []
        let link = CompanionContentReference.link("a%20b.md#intro")
        _ = try await link.loadLink(roots: .init()) {
            fetched.append($0)
            return .init(kind: "text", name: "literal", text: "literal")
        }
        #expect(fetched == [.file("a%20b.md#intro")])
        fetched.removeAll()
        await #expect(throws: AnnexTransportError.disconnected) {
            try await link.loadLink(roots: .init()) {
                fetched.append($0)
                throw AnnexTransportError.disconnected
            }
        }
        #expect(fetched.count == 1)
    }

    @Test func everyFallbackUsesArchiveOrLiveRootsWithoutEscaping() async throws {
        var fetched: [CompanionContentReference] = []
        let link = CompanionContentReference.link("/archive/%2E%2E/out.md#intro")
        await #expect(throws: CompanionContentError.self) {
            try await link.loadLink(roots: .init(paths: ["/archive"])) {
                fetched.append($0)
                throw CompanionContentError.unavailable("synthetic missing")
            }
        }
        #expect(fetched == [.file("/archive/%2E%2E/out.md#intro"), .file("/archive/%2E%2E/out.md")])
        fetched.removeAll()
        await #expect(throws: CompanionContentError.self) {
            try await CompanionContentReference.link("file:///tmp/a.md").loadLink(roots: .init()) {
                fetched.append($0)
                return .init(kind: "text", name: "unexpected")
            }
        }
        #expect(fetched.isEmpty)
    }

    @Test func folderSyntaxShowsNativeResultWithoutFalsePreviewOrRoute() async throws {
        for href in ["Some/Folder/", "Some%20Folder/#intro", "file:///tmp/Folder/", "~/Folder/"] {
            var fetched = false
            let content = try await CompanionContentReference.link(href).loadLink(roots: .init(anyPath: true)) { _ in
                fetched = true
                return .init(kind: "text", name: "false preview")
            }
            #expect(content.kind == "folder" && content.bytes == nil)
            #expect(content.text == CompanionContentReference.folderLinkMessage)
            #expect(!fetched)
        }
        #expect(CompanionContentReference.link(#"Some\Folder\"#).folderLinkPath(roots: .init(windows: true)) != nil)
        #expect(CompanionContentReference.link("Some/Folder").folderLinkPath(roots: .init()) == nil)
    }

    @Test func missingOrUnconfirmedFolderGetsHonestErrorThroughStoreAndRoute() async throws {
        let h = try await LiveServiceHarness.start { await $0.setCapability("richContent", .object(["enabled": .bool(true)])) }
        defer { h.stop() }
        await h.transport.failRead("chatContent", .rejected(status: 404, code: "content_unavailable"))
        for href in ["missing.md#intro", "Some/Folder"] {
            do {
                _ = try await h.store.content(.link(href), target: h.target)
                Issue.record("A missing target must not show a preview")
            } catch {
                #expect(error.localizedDescription == CompanionContentReference.unavailableLinkMessage(hostName: "Fixture"))
            }
        }
        #expect(await h.transport.readRoutes.filter { $0.name == "chatContent" }.compactMap(\.filePath) == ["missing.md#intro", "missing.md", "Some/Folder"])
        #expect(await h.transport.executed.isEmpty, "No desktop shell/Finder command")
    }

    @Test func fileURLIsConvertedForThePairedHostAndUsesExistingRoute() async throws {
        let h = try await LiveServiceHarness.start { await $0.setCapability("richContent", .object(["enabled": .bool(true)])) }
        defer { h.stop() }
        await h.transport.setRead("chat", LiveServiceHarness.chatSnapshot(fields: ["contentAnyPath": .bool(true)]))
        await h.store.load(h.target)
        await h.transport.setRead("chatContent", .object(["kind": .string("text"), "name": .string("a.md"), "text": .string("Synthetic file preview")]))
        let content = try await h.store.content(.link("file:///tmp/Some%20Folder/a.md#intro"), target: h.target)
        #expect(content.text == "Synthetic file preview")
        #expect(await h.transport.readRoutes.last?.filePath == "/tmp/Some Folder/a.md")
        await h.transport.failRead("chatContent", .forbidden)
        let before = await h.transport.readRoutes.count
        await #expect(throws: CompanionServiceError.self) {
            try await h.store.content(.link("a%20b.md#intro"), target: h.target)
        }
        #expect(await h.transport.readRoutes.count == before + 1)
    }
}
