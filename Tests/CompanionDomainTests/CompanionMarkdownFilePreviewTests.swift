import Foundation
import Testing
@testable import CompanionDomain

@Suite struct CompanionMarkdownFilePreviewTests {
    @Test func detectsOnlyAvailableMarkdownText() {
        for name in ["notes.md", "notes.markdown", "notes.mdx", "NOTES.MD", "some.folder/a.Markdown"] {
            #expect(CompanionMarkdownFilePreview.isMarkdown(.init(kind: "text", name: name, text: "")))
        }
        for name in ["notes.txt", "notes.md.txt", "markdown", "notes"] {
            #expect(!CompanionMarkdownFilePreview.isMarkdown(.init(kind: "text", name: name, text: "# title")))
        }
        for kind in ["image", "pdf", "other", "folder"] {
            #expect(!CompanionMarkdownFilePreview.isMarkdown(.init(kind: kind, name: "notes.md", text: "# title")))
        }
        #expect(!CompanionMarkdownFilePreview.isMarkdown(.init(kind: "text", name: "notes.md", text: "partial", tooLarge: true)))
        #expect(!CompanionMarkdownFilePreview.isMarkdown(.init(kind: "text", name: "notes.md")))
    }

    @Test func exactSourceAndLineOffsetsPreserveCRLFWhitespaceAndUnicode() {
        let source = "# Caf\u{00e9}\r\n\r\n**Keep**  \r\n\u{1f680} \t \r\n"
        let preview = CompanionMarkdownFilePreview(source: source)
        #expect(Array(preview.source.utf8) == Array(source.utf8))
        #expect(preview.sourceRange(line: 1).location == 0)
        #expect(preview.sourceRange(line: 3).location == ("# Caf\u{00e9}\r\n\r\n" as NSString).length)
        #expect(preview.sourceRange(line: 4).location == ("# Caf\u{00e9}\r\n\r\n**Keep**  \r\n" as NSString).length)
        #expect(preview.sourceRange(line: Int.max).location == (source as NSString).length)
        #expect(preview.sourceRange(line: 0).location == 0)
        #expect(CompanionMarkdownFilePreview(source: "").sourceRange(line: 8).location == 0)
        #expect(CompanionMarkdownFilePreview(source: "one\ntwo").sourceRange(line: 2).location == 4)
    }

    @Test func onlyWebMailAndSameDocumentLinksAreAllowed() {
        for destination in ["https://example.test/a", "HTTP://example.test/a", "mailto:hello@example.test"] {
            #expect(CompanionMarkdownFilePolicy.link(destination) == .external(URL(string: destination)!))
        }
        #expect(CompanionMarkdownFilePolicy.link("#caf%C3%A9") == .fragment("caf\u{00e9}"))
        for destination in ["", "#", "#invalid%xx", "next.md", "./next.md", "/tmp/next.md", "~/next.md",
                            "file:///tmp/a.md", "javascript:alert(1)", "data:text/html,x", "//example.test/a",
                            "https:", "https:///a", "mailto:", "https://user:pass@example.test", " https://example.test",
                            "https://example.test/\n", "https://example.test/\0"] {
            #expect(CompanionMarkdownFilePolicy.link(destination) == .blocked, "\(destination.debugDescription)")
        }
    }

    @Test func imageAllowlistIsExplicitRasterAndBounded() {
        #expect(CompanionMarkdownFilePolicy.image("https://example.test/a.png") == .remote(URL(string: "https://example.test/a.png")!))
        let bytes = Data([0, 1, 2])
        #expect(CompanionMarkdownFilePolicy.image("data:image/png;base64,\(bytes.base64EncodedString())") == .data(bytes))
        for destination: String? in [nil, "", "a.png", "/tmp/a.png", "file:///tmp/a.png", "//example.test/a.png",
                                     "http://example.test/a.png", "https://example.test/a.svg#shape",
                                     "data:image/svg+xml;base64,PHN2Zz48dXNlIGhyZWY9J2h0dHBzOi8vZXhhbXBsZS50ZXN0L2EnLz48L3N2Zz4=",
                                     "data:text/html;base64,YQ==", "data:image/png,YQ==", "data:image/png;base64,",
                                     "data:image/png;base64,?", "data:image/png;base64;base64,YQ=="] {
            #expect(CompanionMarkdownFilePolicy.image(destination) == .blocked)
        }
        let limit = Data(repeating: 1, count: CompanionMarkdownFilePolicy.maximumImageBytes)
        #expect(CompanionMarkdownFilePolicy.image("data:image/png;base64,\(limit.base64EncodedString())") == .data(limit))
        #expect(CompanionMarkdownFilePolicy.image("data:image/png;base64,\((limit + Data([1])).base64EncodedString())") == .blocked)
    }

    @Test func filePolicyReachesNestedBlocksWithoutChangingChat() throws {
        let source = """
        # Intro
        # Intro

        [web](https://example.test) [local](next.md) [anchor](#intro)

        > [private](file:///tmp/a)

        - [relative](../a)

        | [local](next.md) |
        |---|
        | [mail](mailto:a@example.test) |

        ![local image](./secret.png)

        ![remote image](https://example.test/a.png)

        inline ![secret](file:///tmp/a.png)

        <input type="image" src="https://example.test/a.png">
        <script>alert(1)</script>

        <Component run={execute()} />
        """
        let preview = CompanionMarkdownFilePreview(source: source)
        #expect(preview.anchors == ["intro": 0, "intro-1": 1])
        #expect(preview.elements.contains(.image(alt: "local image", resource: .blocked)))
        #expect(preview.elements.contains(.image(alt: "remote image", resource: .remote(URL(string: "https://example.test/a.png")!))))
        guard case .block(.paragraph(let paragraph)) = preview.elements[2] else { Issue.record("paragraph"); return }
        #expect(paragraph.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.test", "#intro"])
        guard case .block(.quote(let quote)) = preview.elements[3], case .paragraph(let quoted) = quote[0] else { Issue.record("quote"); return }
        #expect(quoted.runs.compactMap(\.link).isEmpty)
        guard case .block(.list(let list)) = preview.elements[4], case .paragraph(let item) = list.items[0].blocks[0] else { Issue.record("list"); return }
        #expect(item.runs.compactMap(\.link).isEmpty)
        guard case .block(.table(let table)) = preview.elements[5] else { Issue.record("table"); return }
        #expect(table.header[0].runs.compactMap(\.link).isEmpty)
        #expect(table.rows[0][0].runs.first?.link == URL(string: "mailto:a@example.test"))
        #expect(preview.elements.contains(.block(.paragraph("inline [Image not shown: secret]"))))
        #expect(preview.elements.contains { if case .block(.plain(let raw)) = $0 { raw.contains("<script>") } else { false } })
        #expect(preview.elements.contains { if case .block(.plain(let raw)) = $0 { raw.contains("<Component") } else { false } })
        guard case .paragraph(let chat) = CompanionMarkdown.parse("[local](next.md) ![secret](secret.png)").blocks[0] else { Issue.record("chat"); return }
        #expect(chat.runs.first?.link == URL(string: "next.md"))
        #expect(String(chat.characters) == "local secret")
    }

    @Test func explicitLineReferencesKeepDiscoveryAndAuthorization() {
        for value in ["notes.md:42", "notes.markdown:42:3", "notes.mdx#L42", "notes.md#L42-L50"] {
            let target = CompanionContentReference.link(value).markdownLineTarget
            #expect(target?.line == 42)
            #expect(CompanionContentReference.files(in: "[line](\(value))") == [.link(value)])
            #expect(CompanionContentReference.link(value).isOffered(roots: .init()))
        }
        let reference = CompanionContentReference.file("/tmp/notes.md:42")
        #expect(reference.markdownLineTarget?.reference == .file("/tmp/notes.md"))
        #expect(!reference.isOffered(roots: .init()))
        #expect(reference.isOffered(roots: .init(paths: ["/tmp"])))
        #expect(CompanionContentReference.files(in: "`notes.md:42`") == [.file("notes.md:42")])
        for reference: CompanionContentReference in [.link("notes.md#intro"), .file("notes.md:0"), .file("notes.txt:42"),
                                                       .link("notes.md:999999999999999999999999"), .image("notes.md:42"), .localImage("notes.md:42")] {
            #expect(reference.markdownLineTarget == nil)
        }
    }
}
