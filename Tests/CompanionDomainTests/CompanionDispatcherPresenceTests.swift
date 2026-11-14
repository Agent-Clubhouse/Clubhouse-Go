import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

private let presenceFeature: AnnexJSON = .object([
    "version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true),
    "presence": .object(["version": .integer(1), "snapshotField": .string("dispatcherPresence"), "event": .string("dispatcher:presence")])
])

/// Synthetic data uses only the documented #3349 shape; the pinned snapshot intentionally has no remotes.
private func presenceJSON(_ state: String = "working", machine: String = "remote") -> AnnexJSON {
    .object(["remotes": .array([.object([
        "machineId": .string(machine), "machineName": .string("Office Mac"),
        "address": .string("dispatcher@office"), "dispatcherName": .string("Navi"),
        "label": .string("Navi on Office Mac"), "state": .string(state),
        "lastSeen": state == "offline" ? .string("2026-11-14T08:00:00.000Z") : .null,
        "link": .object(["state": .string("active")])
    ])])])
}

@Suite struct CompanionDispatcherPresenceTests {
    @Test func pinnedCapabilityAndEmptySnapshotDecodeWithoutAddingCommands() throws {
        let caps = try ContractFixtures.body("capabilities.json").decode(AnnexCapabilities.self)
        #expect(caps.supportsDispatcherPresence)
        #expect(caps.dispatcher?.presence?.snapshotField == "dispatcherPresence")
        #expect(caps.dispatcher?.presence?.event == "dispatcher:presence")
        let snapshot = try #require(try ContractFixtures.json("snapshot.json")["frame"]?["payload"])
        #expect(try snapshot["dispatcherPresence"]?.decode(CompanionDispatcherPresence.self).remotes.isEmpty == true)
        #expect(!caps.commands.contains("dispatcher.presence"))
        guard case .object(var feature) = presenceFeature,
              case .object(var raw) = try ContractFixtures.body("capabilities.json") else {
            Issue.record("Expected object fixtures")
            return
        }
        feature["presence"] = .object(["version": .integer(2), "snapshotField": .string("dispatcherPresence"), "event": .string("dispatcher:presence")])
        raw["dispatcher"] = .object(feature)
        #expect(try !AnnexJSON.object(raw).decode(AnnexCapabilities.self).supportsDispatcherPresence)
        raw["dispatcher"] = .null
        #expect(try !AnnexJSON.object(raw).decode(AnnexCapabilities.self).supportsDispatcherPresence)
    }

    @Test func decodeNullableIdentityAndStateWording() throws {
        let report = try presenceJSON("offline").decode(CompanionDispatcherPresence.self)
        var remote = try #require(report.remotes.first)
        let now = try Date.ISO8601FormatStyle().parse("2026-11-14T08:05:00Z")
        #expect(remote.machineId == "remote" && remote.address == "dispatcher@office")
        #expect(remote.stateText(now: now).hasPrefix("Offline, last seen "))
        for (state, word) in [("online", "Online"), ("working", "Working"), ("asleep", "Asleep"),
                              ("off", "Off"), ("unknown", "Unknown"), ("future", "Unknown")] {
            remote.state = state
            #expect(remote.stateText(now: now) == word, "lastSeen must be ignored outside offline")
        }
        remote.state = "offline"
        remote.lastSeen = "not-a-date"
        #expect(remote.stateText(now: now) == "Offline")
        for (state, word) in [("active", "Link active"), ("paused", "Link paused"), ("unavailable", "Link unavailable")] {
            remote.link = .init(state: state, reason: "network_paused")
            #expect(remote.link.text == word)
        }
        let nullable: AnnexJSON = .object(["remotes": .array([.object([
            "machineId": .string("other"), "machineName": .string("Mac"), "address": .null,
            "dispatcherName": .null, "label": .string("Dispatcher on Mac"), "state": .string("off"),
            "link": .object(["state": .string("paused"), "reason": .string("network_paused")])
        ])])])
        let other = try #require(try nullable.decode(CompanionDispatcherPresence.self).remotes.first)
        #expect(other.address == nil && other.dispatcherName == nil && other.lastSeen == nil)
        #expect(other.link.reason == "network_paused")
    }

    private func host(_ id: String, state: String, received: Date) throws -> CompanionHost {
        var host = CompanionHost(id: id, name: "Paired Mac", endpoint: "", connection: .connected, projects: [])
        host.dispatcherPresence = try presenceJSON(state).decode(CompanionDispatcherPresence.self)
        host.dispatcherPresenceReceivedAt = received
        return host
    }

    @Test func mergesPairedRowsAndDeduplicatesByReceiptNotOfflineLastSeen() throws {
        let old = try host("source-a", state: "working", received: .init(timeIntervalSince1970: 1))
        var fresh = try host("source-b", state: "offline", received: .init(timeIntervalSince1970: 2))
        fresh.dispatcherPresence?.remotes[0].lastSeen = "2000-01-01T00:00:00Z"
        var paired = CompanionHost(id: "remote", name: "Office Mac", endpoint: "", connection: .connected, projects: [],
                                   dispatcher: .init(enabled: true, flagOn: true))
        paired.dispatcher?.agent = .init(id: .init(hostID: paired.id, projectID: "__dispatcher__", agentID: "dispatcher"),
                                        name: "Navi", subtitle: "", status: .idle)
        let desktop = try #require(CompanionDispatcherDesktop(host: paired))
        for sources in [[old, fresh], [fresh, old]] {
            let rows = CompanionDispatcherSwitcherRow.rows(desktops: [desktop], hosts: sources)
            #expect(rows.count == 1)
            #expect(rows.first?.desktop?.target == desktop.target, "Pairing retains selection authority")
            #expect(rows.first?.presence?.state == "offline")
            #expect(rows.first?.label == "Navi on Office Mac")
            #expect(rows.first?.accessibilityLabel.contains("Offline, last seen") == true)
            #expect(rows.first?.accessibilityLabel.contains("Link active") == true)
            #expect(rows.first?.accessibilityLabel.contains("dispatcher@office") == false)
        }
        let rows = CompanionDispatcherSwitcherRow.rows(desktops: [], hosts: [old, fresh])
        #expect(rows.count == 1 && rows.first?.desktop == nil, "An unpaired remote is informational")
        #expect(CompanionDispatcherSwitcherRow.rows(desktops: [], hosts: []).isEmpty, "Removing sources removes their observations")
    }

    @Test func equalReceiptTimesHaveStableSourceTieBreakAndEmptyReportsReplaceOnlyTheirSource() throws {
        let now = Date()
        let a = try host("a", state: "asleep", received: now)
        var b = try host("b", state: "off", received: now)
        for sources in [[a, b], [b, a]] {
            #expect(CompanionDispatcherSwitcherRow.rows(desktops: [], hosts: sources).first?.presence?.state == "asleep")
        }
        b.dispatcherPresence = .init(remotes: [])
        b.dispatcherPresenceReceivedAt = now.addingTimeInterval(1)
        #expect(CompanionDispatcherSwitcherRow.rows(desktops: [], hosts: [a, b]).first?.presence?.state == "asleep")
    }
}

@MainActor @Suite(.serialized) struct CompanionDispatcherPresenceLiveTests {
    @Test func snapshotsAndEventsReplaceTheEntireReportAndRefreshKeepsItsReceiptTime() async throws {
        let h = try await LiveServiceHarness.start { await $0.setFeature("dispatcher", presenceFeature) }
        defer { h.stop() }
        await h.transport.emit(h.snapshotEvent(["dispatcherPresence": presenceJSON()]))
        try await h.waitUntil { h.host?.dispatcherPresence?.remotes.first?.state == "working" }
        let received = try #require(h.host?.dispatcherPresenceReceivedAt)
        try await h.refreshCatalog()
        #expect(h.host?.dispatcherPresenceReceivedAt == received, "REST refresh must not make an old observation fresher")
        await h.transport.emit(.message(.init(type: "dispatcher:presence", payload: presenceJSON("asleep", machine: "replacement"))))
        try await h.waitUntil { h.host?.dispatcherPresence?.remotes.first?.id == "replacement" }
        #expect(h.host?.dispatcherPresence?.remotes.count == 1)
        #expect(h.host?.dispatcherPresence?.remotes.first?.state == "asleep")
        await h.transport.emit(.message(.init(type: "dispatcher:presence", payload: .object(["remotes": .array([])]))))
        try await h.waitUntil { h.host?.dispatcherPresence?.remotes.isEmpty == true }
        await h.transport.emit(h.snapshotEvent(["dispatcherPresence": presenceJSON("off")]))
        try await h.waitUntil { h.host?.dispatcherPresence?.remotes.first?.state == "off" }
        await h.transport.emit(h.snapshotEvent([:]))
        try await h.waitUntil { h.host?.dispatcherPresence == nil }
    }

    @Test func unsupportedPresenceIsIgnoredAndMalformedReportsAreExplicit() async throws {
        let h = try await LiveServiceHarness.start { await $0.setFeature("dispatcher", presenceFeature) }
        defer { h.stop() }
        await h.transport.emit(h.snapshotEvent(["dispatcherPresence": presenceJSON()]))
        try await h.waitUntil { h.host?.dispatcherPresence != nil }
        await h.transport.emit(.message(.init(type: "dispatcher:presence", payload: .object(["remotes": .string("bad")]))))
        try await h.waitUntil { h.host?.dispatcherPresenceError != nil }
        #expect(h.host?.dispatcherPresence == nil && h.host?.dispatcherPresenceReceivedAt == nil)
        await h.transport.emit(.message(.init(type: "dispatcher:presence", payload: presenceJSON())))
        try await h.waitUntil { h.host?.dispatcherPresence != nil && h.host?.dispatcherPresenceError == nil }
        await h.transport.setFeature("dispatcher", .null)
        try await h.refreshCatalog()
        #expect(h.host?.dispatcherPresence == nil)
        await h.transport.emit(.message(.init(type: "dispatcher:presence", payload: presenceJSON("off"))))
        await h.transport.emit(h.snapshotEvent(["dispatcherPresence": presenceJSON("asleep"),
                                              "idleDays": .integer(42)]))
        try await h.waitUntil { h.host?.idleDays == 42 }
        #expect(h.host?.dispatcherPresence == nil)
    }
}
