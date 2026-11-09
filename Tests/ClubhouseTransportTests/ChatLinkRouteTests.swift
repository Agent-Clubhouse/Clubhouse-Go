import Foundation
import Testing
@testable import ClubhouseTransport

/// The desktop's chat-link route (`chatLinks` v1, desktop #3208) against its recorded fixtures, and the query encoding
/// it needs: `href` encoded as `encodeURIComponent` does, so a `+` reaches the desktop as a plus, not a space.
@Suite struct ChatLinkRouteTests {
    /// The fixture's href, as the agent wrote it: the query value percent-decoded once.
    private static func href(_ path: String) throws -> String {
        let query = try #require(path.split(separator: "?", maxSplits: 1).last)
        let value = try #require(query.hasPrefix("href=") ? query.dropFirst(5) : nil)
        return try #require(String(value).removingPercentEncoding)
    }

    @Test func everyRecordedAnswerIsRequestedAndReadExactlyAsTheDesktopRecordedIt() async throws {
        let caps = try AnnexContract.json("capabilities.json")["response"]
        guard case .object(let exchanges) = try AnnexContract.json("chat-links.json") else { Issue.record("chat-links.json"); return }
        var checked = 0
        // The phone sends exactly one href, so the duplicate-parameter refusal is the desktop's own check, not a phone request.
        for (name, exchange) in exchanges.sorted(by: { $0.key < $1.key }) where name != "note" && name != "invalidQuery" {
            let path = try #require(exchange["request"]?["path"]?.string)
            let agent = path.split(separator: "/")[4]
            let io = AnnexContractIO([try AnnexContract.response(caps), try AnnexContract.response(exchange["response"])])
            let transport = try await annexContractTransport(io)
            _ = try await transport.read(.capabilities)
            let status = Int(exchange["response"]?["status"]?.integer ?? 0)
            do {
                let value = try await transport.read(.chatLink(agentID: String(agent), href: try Self.href(path)))
                #expect(status == 200, "\(name)")
                #expect(value == exchange["response"]?["body"], "\(name)")
            } catch let AnnexTransportError.rejected(rejected, code, _) {
                #expect(rejected == status, "\(name)")
                #expect(code == exchange["response"]?["body"]?["error"]?.string, "\(name)")
            }
            let url = try #require(await io.requests.last?.url)
            #expect(url.absoluteString == "https://127.0.0.1:7432" + path, "\(name)")
            #expect(await io.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            checked += 1
        }
        #expect(checked == 8)
    }

    @Test func hrefIsEncodedAsEncodeURIComponentDoes() {
        let cases: [(String, String)] = [
            ("C++ notes.md", "C%2B%2B%20notes.md"),
            ("docs/guide.md#setup", "docs%2Fguide.md%23setup"),
            ("Some%20Folder/", "Some%2520Folder%2F"),
            ("100% done.md", "100%25%20done.md"),
            ("a&b=c?.md", "a%26b%3Dc%3F.md"),
            ("résumé 😀.md", "r%C3%A9sum%C3%A9%20%F0%9F%98%80.md"),
            (#"C:\Users\me\a.md"#, "C%3A%5CUsers%5Cme%5Ca.md"),
            ("-_.!~*'()", "-_.!~*'()"),
        ]
        for (href, encoded) in cases { #expect(AnnexEndpoint.uriComponent(href) == encoded, "\(href)") }
    }

    @Test func theDesktopReadsBackExactlyTheHrefTheAgentWrote() throws {
        let endpoint = try AnnexEndpoint(host: "127.0.0.1", port: 7432)
        for href in ["C++ notes.md", "a b.md", "a#b.md", "100%.md", "%41.md", "a&b=c.md", "日本語/ファイル.md", "x+y=z & w#h"] {
            let url = try endpoint.url(path: ["api", "v1", "mobile", "agents", "a", "link"], encodedQuery: "href=" + AnnexEndpoint.uriComponent(href))
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            #expect(!query.contains("+") && !query.contains(" ") && query.split(separator: "&").count == 1, "\(href)")
            // URLSearchParams: `+` is a space, then percent-decoding.
            let form = String(query.dropFirst(5)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            #expect(form == href, "\(href)")
        }
    }

    @Test func anEmptyHrefIsNeverSent() async throws {
        let io = AnnexContractIO([])
        let transport = try await annexContractTransport(io)
        await #expect(throws: AnnexTransportError.invalidEndpoint) { try await transport.read(.chatLink(agentID: "a", href: "")) }
        #expect(await io.requests.isEmpty)
    }

    @Test func otherQueriesStillEncodeAPlus() throws {
        let url = try AnnexEndpoint(host: "127.0.0.1", port: 7432).url(path: ["x"], query: [.init(name: "path", value: "C++ a.md")])
        #expect(url.query(percentEncoded: true) == "path=C%2B%2B%20a.md")
    }
}
