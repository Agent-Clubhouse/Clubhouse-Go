import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - Git Commit Tests

struct GitCommitTests {
    @Test func decodeGitCommit() throws {
        let json = """
        {
            "hash": "abc123def456789",
            "shortHash": "abc123d",
            "author": "Mason Allen",
            "email": "mason@example.com",
            "message": "Fix bug in login flow\\n\\nAdded null check for token",
            "timestamp": 1711500000000
        }
        """.data(using: .utf8)!

        let commit = try JSONDecoder().decode(GitCommit.self, from: json)
        #expect(commit.hash == "abc123def456789")
        #expect(commit.shortHash == "abc123d")
        #expect(commit.author == "Mason Allen")
        #expect(commit.email == "mason@example.com")
        #expect(commit.message.contains("Fix bug"))
        #expect(commit.timestamp == 1711500000000)
    }

    @Test func shortMessageExtractsFirstLine() {
        let commit = GitCommit(
            hash: "abc123", shortHash: nil, author: "Test",
            email: nil, message: "First line\nSecond line\nThird line",
            timestamp: 1000
        )
        #expect(commit.shortMessage == "First line")
    }

    @Test func shortMessageSingleLine() {
        let commit = GitCommit(
            hash: "abc123", shortHash: nil, author: "Test",
            email: nil, message: "Just one line",
            timestamp: 1000
        )
        #expect(commit.shortMessage == "Just one line")
    }

    @Test func displayHashUsesShortHash() {
        let commit = GitCommit(
            hash: "abc123def456789", shortHash: "abc123d", author: "Test",
            email: nil, message: "msg", timestamp: 1000
        )
        #expect(commit.displayHash == "abc123d")
    }

    @Test func displayHashFallsBackToPrefix() {
        let commit = GitCommit(
            hash: "abc123def456789", shortHash: nil, author: "Test",
            email: nil, message: "msg", timestamp: 1000
        )
        #expect(commit.displayHash == "abc123d")
    }

    @Test func commitIdentifiable() {
        let commit = GitCommit(
            hash: "abc123", shortHash: nil, author: "Test",
            email: nil, message: "msg", timestamp: 1000
        )
        #expect(commit.id == "abc123")
    }

    @Test func decodeCommitWithoutOptionalFields() throws {
        let json = """
        {
            "hash": "abc123",
            "author": "Test",
            "message": "msg",
            "timestamp": 1000
        }
        """.data(using: .utf8)!

        let commit = try JSONDecoder().decode(GitCommit.self, from: json)
        #expect(commit.shortHash == nil)
        #expect(commit.email == nil)
    }

    @Test func commitRoundTrip() throws {
        let commit = GitCommit(
            hash: "abc123def", shortHash: "abc123d", author: "Mason",
            email: "m@test.com", message: "Test commit", timestamp: 1000
        )
        let data = try JSONEncoder().encode(commit)
        let decoded = try JSONDecoder().decode(GitCommit.self, from: data)
        #expect(decoded.hash == commit.hash)
        #expect(decoded.author == commit.author)
        #expect(decoded.message == commit.message)
    }
}

// MARK: - Git Diff Tests

struct GitDiffTests {
    @Test func decodeDiffFile() throws {
        let json = """
        {
            "path": "src/main.swift",
            "status": "modified",
            "additions": 10,
            "deletions": 3,
            "patch": "+new line\\n-old line"
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder().decode(GitDiffFile.self, from: json)
        #expect(file.path == "src/main.swift")
        #expect(file.status == .modified)
        #expect(file.additions == 10)
        #expect(file.deletions == 3)
        #expect(file.patch != nil)
    }

    @Test func decodeDiffResponse() throws {
        let json = """
        {
            "files": [
                {"path": "a.swift", "status": "added", "additions": 5, "deletions": 0, "patch": "+code"},
                {"path": "b.swift", "status": "deleted", "additions": 0, "deletions": 10, "patch": "-code"}
            ],
            "stats": {
                "totalAdditions": 5,
                "totalDeletions": 10,
                "filesChanged": 2
            }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GitDiffResponse.self, from: json)
        #expect(response.files.count == 2)
        #expect(response.files[0].status == .added)
        #expect(response.files[1].status == .deleted)
        #expect(response.stats?.totalAdditions == 5)
        #expect(response.stats?.totalDeletions == 10)
        #expect(response.stats?.filesChanged == 2)
    }

    @Test func diffFileIdentifiable() {
        let file = GitDiffFile(
            path: "src/test.swift", status: .modified,
            additions: 1, deletions: 1, patch: nil
        )
        #expect(file.id == "src/test.swift")
    }

    @Test func decodeDiffWithoutOptionals() throws {
        let json = """
        {
            "files": [{"path": "a.swift", "status": "added"}],
            "stats": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(GitDiffResponse.self, from: json)
        #expect(response.files.count == 1)
        #expect(response.files[0].additions == nil)
        #expect(response.files[0].patch == nil)
        #expect(response.stats == nil)
    }

    @Test func unknownStatusDecodesToUnknown() throws {
        let json = """
        {"path": "x.swift", "status": "copied"}
        """.data(using: .utf8)!
        let file = try JSONDecoder().decode(GitDiffFile.self, from: json)
        #expect(file.status == .unknown)
    }

    @Test func knownStatusesDecodeCorrectly() throws {
        for status in ["added", "modified", "deleted", "renamed"] {
            let json = """
            {"path": "x.swift", "status": "\(status)"}
            """.data(using: .utf8)!
            let file = try JSONDecoder().decode(GitDiffFile.self, from: json)
            #expect(file.status != .unknown)
        }
    }

    @Test func diffFileRoundTrip() throws {
        let file = GitDiffFile(
            path: "test.swift", status: .modified,
            additions: 5, deletions: 2, patch: "+new\n-old"
        )
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(GitDiffFile.self, from: data)
        #expect(decoded.path == file.path)
        #expect(decoded.status == file.status)
        #expect(decoded.additions == file.additions)
    }
}

// MARK: - File Browser Filter Tests

struct FileBrowserFilterTests {
    private func makeNode(name: String, isDir: Bool = false) -> FileNode {
        FileNode(name: name, path: "/\(name)", isDirectory: isDir, children: nil)
    }

    @Test func filterByName() {
        let nodes = [
            makeNode(name: "main.swift"),
            makeNode(name: "test.swift"),
            makeNode(name: "README.md"),
            makeNode(name: "src", isDir: true),
        ]
        let search = "swift"
        let filtered = nodes.filter { $0.name.localizedCaseInsensitiveContains(search) }
        #expect(filtered.count == 2)
    }

    @Test func filterCaseInsensitive() {
        let nodes = [
            makeNode(name: "README.md"),
            makeNode(name: "readme.txt"),
        ]
        let filtered = nodes.filter { $0.name.localizedCaseInsensitiveContains("readme") }
        #expect(filtered.count == 2)
    }

    @Test func emptyFilterReturnsAll() {
        let nodes = [makeNode(name: "a.swift"), makeNode(name: "b.py")]
        let search = ""
        let filtered = search.isEmpty ? nodes : nodes.filter { $0.name.localizedCaseInsensitiveContains(search) }
        #expect(filtered.count == 2)
    }
}
