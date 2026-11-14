import Foundation
import Testing

/// Static references make this independent of test execution order and filters. A generic decode-all loop is not consumption.
@Suite struct AnnexContractFixtureUsageTests {
    // Intentionally lack dedicated contract assertions; keep these gaps visible rather than counting the decode-all smoke test.
    private static let intentionallyUnused: [String: String] = [
        "canvas-route.json": "Canvas route responses have no dedicated phone contract test.",
        "chat-snapshot-errors.json": "Read failures use synthetic transport responses, not this recorded error matrix.",
        "dispatcher-requests.json": "Dispatcher request cases have no dedicated phone contract test.",
        "pairing-revoke.json": "Revocation uses synthetic transport/registry cases, not this recorded response.",
        "pairing.json": "Pairing tests use throwaway real identities; the recording has redacted credentials."
    ]

    @Test func everyIndexedFixtureHasAContractTestReferenceOrAnExplicitException() throws {
        let tests = AnnexContract.directory.deletingLastPathComponent().deletingLastPathComponent()
        let ownFile = URL(fileURLWithPath: #filePath).standardizedFileURL
        // Skip comments, capturing only quoted literals. Command matrices list full filenames before deriving command types.
        let tokens = try NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/|"([^"\\]*(?:\\.[^"\\]*)*)""#)
        var references: Set<String> = []
        for target in ["ClubhouseTransportTests", "CompanionDomainTests"] {
            let sources = try FileManager.default.contentsOfDirectory(
                at: tests.appending(path: target), includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasSuffix("Tests.swift") && $0.standardizedFileURL != ownFile }
            for source in sources.sorted(by: { $0.path < $1.path }) {
                let text = try String(contentsOf: source, encoding: .utf8)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in tokens.matches(in: text, range: range) {
                    if let literal = Range(match.range(at: 1), in: text) {
                        references.insert(String(text[literal]))
                    }
                }
            }
        }
        let indexed = Set(try AnnexContract.files())
        let allowed = Set(Self.intentionallyUnused.keys)
        #expect(allowed.isSubset(of: indexed), "Remove exceptions for fixtures no longer indexed: \(allowed.subtracting(indexed).sorted())")
        #expect(allowed.isDisjoint(with: references), "Remove exceptions now referenced by tests: \(allowed.intersection(references).sorted())")
        let unused = indexed.subtracting(references).subtracting(allowed).sorted()
        #expect(unused.isEmpty, "Fixtures without a contract test reference: \(unused). Add a test or a documented exception.")
    }
}
