import Foundation
import Testing

@testable import ClubhouseTransport

@MainActor struct AnnexContractFrameLimitWireTests {
    @Test func snapshotTruncationDecodesOriginalSizeAndOmittedFields() throws {
        let payload = try #require(AnnexContract.json("snapshot-truncated.json")["value"])
        let frame = AnnexEnvelope(type: "snapshot", payload: payload)
        let truncation = try #require(frame.snapshotTruncated)
        #expect(truncation.version == 1 && truncation.reason == "frame_limit")
        #expect(truncation.bytes == 9 * 1024 * 1024)
        #expect(truncation.omitted == ["canvasState", "appCanvasState"])
        #expect(AnnexEnvelope(type: "canvas:state", payload: payload).snapshotTruncated == nil)
        #expect(AnnexEnvelope(type: "snapshot").snapshotTruncated == nil)
        let capability = try #require(try AnnexContract.json("capabilities.json")["response"]?["body"]).decode(AnnexCapabilities.self)
        #expect(capability.snapshotTruncation?.version == 1)
        #expect(capability.snapshotTruncation?.canvasPaths == [
            "app": "/api/v1/mobile/canvas", "project": "/api/v1/mobile/canvas/{projectId}"
        ])
    }

    @Test func canvasOmissionMarkersDecodeWithoutInventingAnEmptyState() throws {
        let fixture = try AnnexContract.json("frames-over-limit.json")
        var cursor = AnnexReplayCursor()
        #expect(cursor.accept(.init(type: "snapshot", lastSeq: 6)) == .deliver)
        for key in ["canvasMarker", "appCanvasMarker"] {
            let recorded = try #require(fixture[key])
            let frame = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(recorded))
            #expect(frame.type == "canvas:state" && frame.seq == nil)
            #expect(frame.payload == recorded["payload"] && frame.payload?["state"] == nil)
            #expect(frame.payload?["stateOmitted"]?["reason"]?.string == "frame_limit")
            #expect(cursor.accept(frame) == .deliver && cursor.lastSequence == 6)
        }
    }

    @Test func omittedTextConsumesOnlyItsGlobalSequenceAndDeduplicates() throws {
        let recorded = try #require(AnnexContract.json("frames-over-limit.json")["omitted"])
        // The canonical fixture documents a variable transport sequence, rather than recording one.
        // Supply global 7, as in go-icon-cache's omitted-final capture; keep its entire payload unchanged.
        #expect(recorded["seq"]?.string == "<the seq the event would have had>")
        guard case .object(var wire) = recorded else {
            Issue.record("Missing omitted frame")
            return
        }
        wire["seq"] = .integer(7)
        let frame = try JSONDecoder().decode(AnnexEnvelope.self, from: AnnexContract.encode(.object(wire)))
        #expect(frame.type == "frame:omitted" && frame.payload == recorded["payload"])
        #expect(frame.payload?["eventSeq"]?.integer == 98)
        var cursor = AnnexReplayCursor()
        #expect(cursor.accept(.init(type: "snapshot", lastSeq: 6)) == .deliver)
        #expect(cursor.accept(frame) == .deliver && cursor.lastSequence == 7)
        #expect(cursor.accept(frame) == .duplicate && cursor.lastSequence == 7)
        // The session-local eventSeq is not a new global checkpoint or a reason to resync.
        #expect(cursor.accept(.init(type: "chat:event", seq: 8)) == .deliver)
        #expect(cursor.lastSequence == 8)
    }
}
