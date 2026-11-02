import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@MainActor @Suite(.serialized) struct Build147SnapshotShapeTests {
    enum Shape: String, CaseIterable { case absent, object, null, array
        var value: AnnexJSON? { switch self { case .absent: nil; case .object: .object([:]); case .null: .null; case .array: .array([]) } }
    }
    private func deliver(_ harness: LiveServiceHarness, fields: [String: AnnexJSON], marker: String) async throws {
        var payload: [String: AnnexJSON] = [
            "projects": .array([.object(["id": .string("project"), "name": .string(marker)])]),
            "agents": .object(["project": .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("idle")])])]),
            "quickAgents": .object([:]), "dispatcher": .null, "protocolVersion": .integer(1)
        ]
        payload.merge(fields) { _, new in new }
        let frame: AnnexJSON = .object(["type": .string("snapshot"), "payload": .object(payload),
                                       "snapshotTruncated": .object(["version": .integer(1), "reason": .string("frame_limit")])])
        let encoded = try JSONEncoder().encode(frame)
        let envelope = try JSONDecoder().decode(AnnexEnvelope.self, from: encoded)
        #expect(envelope.type == "snapshot")
        await harness.transport.emit(.message(envelope))
        try await harness.waitUntil { harness.host?.projects.first?.name == marker }
        #expect(harness.host?.connection == .connected)
        #expect(harness.host?.projects.count == 1)
        #expect(harness.host?.projects.first?.agents.count == 1)
    }
    @Test func optionalOverflowFieldsThroughEnvelopeReceiveAndApplyCatalog() async throws {
        let harness = try await LiveServiceHarness.start(); defer { harness.stop() }
        for field in ["canvasState", "appCanvasState", "bulletinDigests", "snapshotTruncated"] {
            for shape in Shape.allCases {
                var fields: [String: AnnexJSON] = [:]; fields[field] = shape.value
                let marker = field + "-" + shape.rawValue
                try await deliver(harness, fields: fields, marker: marker)
                print("BUILD147_SHAPE field=\(field) shape=\(shape.rawValue) decoded=true catalog=true connected=true malformed=false")
            }
        }
        for shape in Shape.allCases {
            var plugin: [String: AnnexJSON] = ["id": .string("fixture")]; plugin["contributes"] = shape.value
            try await deliver(harness, fields: ["plugins": .array([.object(plugin)])], marker: "contributes-" + shape.rawValue)
            print("BUILD147_SHAPE field=plugins.contributes shape=\(shape.rawValue) decoded=true catalog=true connected=true malformed=false")
        }
        for shape in Shape.allCases {
            var fields: [String: AnnexJSON] = [:]
            for field in ["canvasState", "appCanvasState", "bulletinDigests"] { fields[field] = shape.value }
            fields["plugins"] = .array([.object(["id": .string("fixture"), "contributes": shape.value ?? .null])])
            fields["snapshotTruncated"] = .object(["version": .integer(1), "reason": .string("frame_limit"), "omitted": .array([]), "bytes": .integer(8388608)])
            try await deliver(harness, fields: fields, marker: "combined-" + shape.rawValue)
            print("BUILD147_SHAPE field=combined shape=\(shape.rawValue) decoded=true catalog=true connected=true malformed=false")
        }
    }
    @Test func iconMapsMissingEmptyAndNull() async throws {
        let harness = try await LiveServiceHarness.start(); defer { harness.stop() }
        let icon = AnnexJSON.string("data:image/png;base64,AQID")
        for projectShape in [Shape.absent, .object, .null] {
            for agentShape in [Shape.absent, .object, .null] {
                let marker = projectShape.rawValue + "-" + agentShape.rawValue
                try await deliver(harness, fields: ["agentIcons": .object(["agent": icon]), "projectIcons": .object(["project": icon])], marker: "seed-" + marker)
                #expect(harness.host?.projects.first?.iconData == Data([1, 2, 3]))
                #expect(harness.host?.projects.first?.agents.first?.iconData == Data([1, 2, 3]))
                var fields: [String: AnnexJSON] = [:]
                fields["projectIcons"] = projectShape.value; fields["agentIcons"] = agentShape.value
                try await deliver(harness, fields: fields, marker: marker)
                let retained = projectShape == .absent && agentShape == .absent
                #expect((harness.host?.projects.first?.iconData != nil) == retained)
                #expect((harness.host?.projects.first?.agents.first?.iconData != nil) == retained)
                print("BUILD147_ICONS projects=\(projectShape.rawValue) agents=\(agentShape.rawValue) decoded=true catalog=true connected=true malformed=false projectRetained=\(retained) agentRetained=\(retained)")
            }
        }
    }
}
