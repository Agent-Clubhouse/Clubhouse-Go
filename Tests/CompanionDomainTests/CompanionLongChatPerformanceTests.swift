import Foundation
import Testing
import ClubhouseTransport
@testable import CompanionDomain

/// Repeatable command-line workload; timings are evidence, never pass/fail thresholds.
@Suite(.serialized) @MainActor struct CompanionLongChatPerformanceTests {
    static func event(_ type: String, _ seq: Int, _ data: [String: AnnexJSON]) -> AnnexJSON {
        .object(["sessionId": .string("long-dispatcher"), "seq": .integer(Int64(seq)), "type": .string(type), "data": .object(data)])
    }
    @Test func profileLongDispatcher() {
        guard ProcessInfo.processInfo.environment["CLUBHOUSE_PROFILE_LONG_CHAT"] == "1" else { return }
        for count in [1_000, 5_000] {
            var projector = CompanionChatProjector()
            let long = String(repeating: "Long routed **markdown** delivery with a link [file](src/main.swift).\n\n", count: 30)
            let start = Date()
            for i in 1...count {
                projector.apply(Self.event("user_message", i, ["messageId": .string("m\(i)"), "source": .string("mcp"),
                    "content": .array([.object(["type": .string("text"), "text": .string(i % 20 == 0 ? long : "[FROM:Builder] Update \(i)")])]),
                    "routed": .array([.object(["sender": .object(["agentId": .string("builder"), "name": .string("Builder")]), "text": .string(i % 20 == 0 ? long : "Update \(i)")])])]))
            }
            let seedMs = Date().timeIntervalSince(start) * 1000
            let store = CompanionStore(service: CompanionPreviewService())
            let target = CompanionTarget(hostID: "fixture", projectID: "__dispatcher__", agentID: "dispatcher")
            store.apply(.timeline(target, items: projector.items, sequence: count, reset: true, sessionID: projector.sessionID))
            var applyMs = 0.0, storeMs = 0.0, layoutMs = 0.0
            for i in 1...200 {
                let begin = Date()
                projector.apply(Self.event("agent_message_chunk", count + i, ["messageId": .string("reply"), "text": .string("Streaming **reply** chunk. ")]))
                applyMs += Date().timeIntervalSince(begin) * 1000
                let merge = Date()
                store.apply(.timeline(target, items: projector.items, sequence: count + i, reset: false, sessionID: projector.sessionID))
                storeMs += Date().timeIntervalSince(merge) * 1000
                let layout = Date()
                let window = CompanionTimelineWindow(CompanionTimelineEntry.entries(for: CompanionTimelineFolding.rows(for: store.conversation(for: target).items)), limit: 150)
                #expect(window.entries.count <= 160)
                layoutMs += Date().timeIntervalSince(layout) * 1000
            }
            let textBytes = projector.items.reduce(0) { result, item in if case .message(let message) = item { result + message.text.utf8.count + message.routed.reduce(0) { $0 + $1.text.utf8.count } } else { result } }
            print("LONG_CHAT items=\(count) events=\(count + 200) retained=\(projector.items.count) textPayloadBytes=\(textBytes) seedMs=\(seedMs) apply200Ms=\(applyMs) store200Ms=\(storeMs) timeline200Ms=\(layoutMs)")
            #expect(store.conversation(for: target).items == projector.items)
        }
    }
}
