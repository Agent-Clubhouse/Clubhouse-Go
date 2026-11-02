import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Committed desktop responses: these tests establish wire compatibility, not live provider behavior.
@MainActor @Suite struct CompanionHelperRoutingTests {
    private func page(_ name: String = "bare") throws -> CompanionHelperRouting {
        try CompanionHelperRouting(json: #require(try ContractFixtures.json("helper-routing.json")[name]?["response"]?["body"]))
    }

    @Test func capabilityOnlyOffersAdvertisedPresets() throws {
        let raw = try ContractFixtures.body("capabilities.json")
        let caps = try raw.decode(AnnexCapabilities.self)
        #expect(caps.supportsHelperRouting)
        let feature = try #require(caps.helperRouting)
        #expect(feature.modes == ["explicit", "preset"] && feature.scopes == ["app"] && !feature.quota)
        #expect(feature.difficulties == ["easy", "medium", "hard"])
        var fields = try #require(raw.object)
        fields["helperRouting"] = nil
        #expect(try !AnnexJSON.object(fields).decode(AnnexCapabilities.self).supportsHelperRouting)
        fields["helperRouting"] = .object(["version": .integer(1)])
        #expect(try !AnnexJSON.object(fields).decode(AnnexCapabilities.self).supportsHelperRouting)
    }

    @Test func readsEveryPageAndPreservesStaleSavedAndEffectiveChoices() throws {
        let raw = try ContractFixtures.json("helper-routing.json")
        for (name, entry) in try #require(raw.object) where entry["response"]?["status"] == .integer(200) {
            let page = try page(name)
            #expect(!page.revision.isEmpty)
            #expect(page.providers["copilot-cli"]?.cells.isEmpty == true)
            #expect(page.label("reason", "preset_on_cli") == "From the helper settings for this difficulty")
            #expect(page.label("reason", "future_reason") == page.labels["generic"]?["unknownCode"])
        }
        let stale = try #require(page("stalePreset").providers["codex-cli"]?.cells["hard"])
        #expect(stale.custom?.model == "gone" && stale.effective?.model == "gpt-6.1-sol")
        #expect(stale.state == "stale" && stale.staleReason == "model_unavailable" && stale.fallback == "builtin_preset")
        #expect(try page("staleNothingValid").providers["codex-cli"]?.cells["hard"]?.effective == nil)
        #expect(try page("staleEffort").providers["codex-cli"]?.cells["hard"]?.custom?.effort == "ultra")
        for (name, reason) in [("dispatcher", "dispatcher_locked"), ("mcpOff", "mcp_off"), ("orchestrationOff", "orchestration_off")] {
            #expect(try page(name).agent == .init(usable: false, reason: reason))
        }
        #expect(try page("agent").agent == .init(usable: true))
        #expect(try page().agent == nil)
        #expect(CompanionHelperRouting.label([:], family: "reason", code: "future") == "Other")
    }

    @Test func encodesAcceptedUpdatesAndRetainsFreshSettingsInStaleReceipt() throws {
        for item in try ContractFixtures.cases("commands/helperRouting.update.json") {
            let raw = try #require(item["request"])
            if item["name"]?.string?.hasPrefix("accepted") == true {
                let update = try raw.decode(AnnexHelperRoutingUpdate.self)
                let command = AnnexCommand(commandID: try #require(raw["commandId"]?.string), epoch: try #require(raw["epoch"]?.string), kind: .updateHelperRouting(update))
                #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == raw)
            }
            let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
            if receipt.error?.code == "helper_routing_stale" {
                let fresh = try CompanionHelperRouting(json: #require(receipt.settings))
                #expect(receipt.revision == fresh.revision && fresh.revision != raw["revision"]?.string)
            }
            if receipt.status == .completed { _ = try CompanionHelperRouting(json: #require(receipt.result)) }
        }
    }

    @Test func helperDetailsUseDisplayAndRowsAndRequestsKeepCodes() throws {
        let raw = try ContractFixtures.json("helper-routing-helper.json")
        for (_, value) in try #require(raw["cases"]?.object) {
            let routing = try #require(CompanionHelperRoutingDecision(json: value))
            #expect(routing.summary == value["display"]?["summary"]?.string)
            var settingsFields = try #require(ContractFixtures.body("agent-settings-helper.json").object)
            settingsFields["routing"] = value
            let settings = try CompanionAgentSettings(json: .object(settingsFields))
            #expect(settings.routing == routing)
            // context.status stays a code; this decision creates no extra context warning.
            #expect(settings.contextWindowReset == nil)
            #expect(routing.reasonText(labels: try page().labels) == value["display"]?["reason"]?.string)
        }
        let row = try #require(CompanionHelperRoutingDecision(json: raw["snapshotRow"]))
        #expect(row.summary == nil && row.selection.model == "gpt-6.1-sol")
        #expect(row.reasonText(labels: try page().labels) == "From the helper settings for this difficulty")
        #expect(CompanionHelperRoutingDecision(json: nil) == nil)
        let requests = CompanionLiveService.helperRequests(from: try #require(ContractFixtures.json("snapshot-helper-requests.json")["value"]), hostID: "fixture")
        let requested = try #require(requests.first { $0.requestedRouting != nil }?.requestedRouting)
        #expect(requested.model == "opus" && requested.difficulty == nil && requested.provider == nil)
    }
}

private extension AnnexJSON {
    var object: [String: AnnexJSON]? { if case .object(let value) = self { value } else { nil } }
}
