import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct AnnexContractProjectLinksTests {
    @Test func additiveCapabilityAndSnapshotDecodeIncludingEmptyAndTruncatedSets() throws {
        let caps = try #require(AnnexContract.json("capabilities.json")["response"]?["body"]).decode(AnnexCapabilities.self)
        #expect(caps.version == 1 && caps.supportsProjectLinks)
        #expect(caps.projectLinks?.snapshotField == "projectLinks")
        #expect(caps.projectLinks?.event == "project-links:changed")
        let snapshot = try #require(AnnexContract.json("snapshot.json")["frame"]?["payload"]).decode(AnnexProjectLinks.self)
        #expect(snapshot.projectLinks.isEmpty && snapshot.projectLinksTruncated == nil)
        let fixture = try AnnexContract.json("project-links.json")
        let accepted = try #require(fixture["snapshot"]).decode(AnnexProjectLinks.self)
        let group = try #require(accepted.projectLinks.first)
        #expect(group.projects.map(\.projectId) == ["proj_app", "proj_app"])
        #expect(Set(group.projects.map(\.machine)).count == 2, "Project IDs are desktop-local")
        #expect(accepted == (try #require(fixture["linked"]?["payload"]).decode(AnnexProjectLinks.self)))
        for key in ["keptSeparate", "unlinked"] {
            #expect(try #require(fixture[key]?["payload"]).decode(AnnexProjectLinks.self).projectLinks.isEmpty)
        }
        var bounded = try #require(fixture["snapshot"])
        if case .object(var fields) = bounded {
            fields["projectLinksTruncated"] = .bool(true)
            bounded = .object(fields)
        }
        let truncated = try bounded.decode(AnnexProjectLinks.self)
        #expect(truncated.projectLinks == accepted.projectLinks && truncated.projectLinksTruncated == true)
    }

    @Test func recordedEventsAreReplayableFullReplacementsNotIncrementalMerges() throws {
        let fixture = try AnnexContract.json("project-links.json")
        let replay = try #require(fixture["replay"]).decode([AnnexEnvelope].self)
        let start = try #require(replay.first)
        let from = try #require(start.fromSeq)
        var cursor = AnnexReplayCursor()
        #expect(cursor.accept(.init(type: "snapshot", lastSeq: from - 1, epoch: start.epoch)) == .deliver)
        var value = AnnexProjectLinks(projectLinks: [])
        var counts: [Int] = []
        for frame in replay {
            #expect(cursor.accept(frame) == .deliver)
            if frame.type == "project-links:changed" {
                #expect(frame.replayed == true && frame.seq != nil)
                value = try #require(frame.payload).decode(AnnexProjectLinks.self)
                counts.append(value.projectLinks.count)
            }
        }
        #expect(counts == [1, 0, 1, 0])
        #expect(value.projectLinks.isEmpty)
        #expect(cursor.lastSequence == start.toSeq)
        let manual = try #require(fixture["manual"]?["payload"]).decode(AnnexProjectLinks.self)
        #expect(manual.projectLinks.first?.projects.first?.projectId == "manual_docs")
        #expect(manual.projectLinks.first?.id != (try #require(fixture["snapshot"]).decode(AnnexProjectLinks.self).projectLinks.first?.id))
    }

    @Test func absentOrIncompleteCapabilityDoesNotEnableGrouping() throws {
        var fields = try #require(AnnexContract.json("capabilities.json")["response"]?["body"])
        guard case .object(var object) = fields else { throw AnnexTransportError.malformedResponse }
        object.removeValue(forKey: "projectLinks")
        fields = .object(object)
        #expect(try !fields.decode(AnnexCapabilities.self).supportsProjectLinks)
        object["projectLinks"] = .object(["version": .integer(1), "snapshotField": .string("wrong"), "event": .string("project-links:changed")])
        #expect(try !AnnexJSON.object(object).decode(AnnexCapabilities.self).supportsProjectLinks)
    }
}
