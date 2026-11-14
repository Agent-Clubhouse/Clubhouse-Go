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
        #expect(feature.modes.contains("preset") && feature.scopes.contains("app"))
        #expect(feature.difficulties == ["easy", "medium", "hard"])
        #expect(feature.presetLevels == ["minimum", "easy", "medium", "hard", "maximum"])
        #expect(feature.presetProviders == ["claude-code", "codex-cli", "copilot-cli"])
        #expect(feature.autoCandidates == ["claude-code", "codex-cli", "copilot-cli"])
        #expect(feature.lastResortCandidates == ["copilot-cli"] && feature.copilotAuto == true)
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
            #expect(page.providers["copilot-cli"]?.cells.count == 5)
            #expect(page.label("reason", "preset_on_cli") == "From the helper settings for this difficulty")
            #expect(page.label("skipped", "mapping_changed") == "The mapping changed while this start was being prepared")
            #expect(page.label("reason", "future_reason") == page.labels["generic"]?["unknownCode"])
        }
        let stale = try #require(page("stalePreset").providers["codex-cli"]?.cells["hard"])
        #expect(stale.custom?.model == "gone" && stale.effective?.model == "gpt-6.1-sol")
        #expect(stale.state == "stale" && stale.staleReason == "model_unavailable" && stale.fallback == "builtin_preset")
        #expect(try page("staleNothingValid").providers["codex-cli"]?.cells["hard"]?.effective == nil)
        #expect(try page("staleEffort").providers["codex-cli"]?.cells["hard"]?.custom?.effort == "ultra")
        for (name, reason) in [("dispatcher", "dispatcher_locked"), ("orchestrationOff", "orchestration_off")] {
            #expect(try page(name).agent == .init(usable: false, reason: reason))
        }
        #expect(try page("agent").agent == .init(usable: true))
        #expect(try page().agent == nil)
        #expect(CompanionHelperRouting.label([:], family: "reason", code: "future") == "Other")
    }

    @Test func fiveLevelsPreserveInheritanceAndAdvertisedAutoCandidates() throws {
        let page = try page()
        for id in ["claude-code", "codex-cli", "copilot-cli"] {
            let provider = try #require(page.providers[id])
            #expect(provider.autoEligible)
            #expect(provider.autoCandidate)
            for (level, follows) in [("minimum", "easy"), ("maximum", "hard")] {
                let cell = try #require(provider.cells[level])
                #expect(cell.follows == follows && cell.custom == nil)
                #expect(cell.effective == provider.cells[follows]?.effective)
                #expect(cell.choiceSource == "Same as \(follows.capitalized)")
            }
            #expect(provider.cells["easy"]?.follows == nil)
            #expect(provider.cells["easy"]?.choiceSource == "Built-in")
        }
        let copilot = try #require(try self.page("copilotNoEffort").providers["copilot-cli"])
        let haiku = try #require(copilot.models.first { $0.id == "claude-haiku-4.5" })
        #expect(haiku.efforts.isEmpty)
        #expect(copilot.cells["easy"]?.effective?.effort == nil)
        #expect(copilot.cells["easy"]?.effective?.summary == "claude-haiku-4.5")
    }

    @Test func explicitChoiceAndStaleFallbackRemainDistinctFromInheritanceAndReset() async throws {
        let inherited = try page()
        var explicit = inherited
        var cell = try #require(explicit.providers["codex-cli"]?.cells["minimum"])
        cell.custom = .init(model: "gpt-6.1-sol", effort: "high")
        cell.effective = cell.custom; cell.follows = nil; cell.source = "custom"
        explicit.providers["codex-cli"]?.cells["minimum"] = cell
        #expect(cell.choiceSource == "Custom" && cell.inheritanceSummary == nil)
        // A stale explicit choice can fall back to Easy while retaining its saved choice and Reset.
        cell.follows = "easy"; cell.state = "stale"; cell.effective = inherited.providers["codex-cli"]?.cells["easy"]?.effective
        #expect(cell.choiceSource == "Custom" && cell.inheritanceSummary == "Same as Easy")
        #expect(cell.custom != nil)
        let screen = CompanionHelperPresetsScreen()
        await screen.load { explicit }
        await screen.save { revision in
            let update = AnnexHelperRoutingUpdate(revision: revision, reset: .init(provider: "codex-cli", difficulty: "minimum"))
            #expect(update.reset?.difficulty == "minimum" && update.cells == nil)
            return inherited
        }
        let reset = try #require(screen.settings?.providers["codex-cli"]?.cells["minimum"])
        #expect(reset.custom == nil && reset.follows == "easy" && reset.choiceSource == "Same as Easy")
    }

    @Test func choicesExcludePseudoModelsAndPreserveEmptyEfforts() throws {
        var body = try #require(ContractFixtures.body("helper-routing.json", "copilotNoEffort").object)
        var providers = try #require(body["providers"]?.object)
        var copilot = try #require(providers["copilot-cli"]?.object)
        var choices = try #require(copilot["choices"]?.object)
        choices["models"] = .array(choices["models"].arrayValue + ["auto", "default"].map {
            .object(["id": .string($0), "label": .string($0), "efforts": .array([])])
        })
        copilot["choices"] = .object(choices); providers["copilot-cli"] = .object(copilot); body["providers"] = .object(providers)
        let decoded = try CompanionHelperRouting(json: .object(body))
        #expect(decoded.providers["copilot-cli"]?.models.contains { ["auto", "default"].contains($0.id) } == false)
        #expect(decoded.providers["copilot-cli"]?.models.first { $0.id == "claude-haiku-4.5" }?.efforts.isEmpty == true)
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

    @Test func copilotPolicyAndNewReasonsUseServerWordsAndRemainBackwardCompatible() throws {
        let capability = try #require(try ContractFixtures.body("capabilities.json").decode(AnnexCapabilities.self).helperRouting)
        var page = try page()
        #expect(page.copilotAuto == true)
        #expect(page.autoCandidateText("copilot-cli", capability: capability) == "Auto candidate (last resort)")
        #expect(page.autoCandidateText("codex-cli", capability: capability) == "Auto candidate")
        for (family, code, words) in [
            ("reason", "last_resort_unmeasured", "Its quota is unknown. No provider with readable plan usage was eligible"),
            ("skipped", "auto_disabled", "Turned off for Auto in Settings"),
            ("skipped", "mapping_changed", "The mapping changed while this start was being prepared")
        ] {
            #expect(page.label(family, code) == words)
            page.labels[family]?[code] = "New desktop wording"
            #expect(page.label(family, code) == "New desktop wording")
        }
        page.copilotAuto = false
        #expect(page.autoCandidateText("copilot-cli", capability: capability) == "New desktop wording")
        page.providers["copilot-cli"]?.autoCandidate = false
        #expect(page.autoCandidateText("copilot-cli", capability: capability) == "Preset only. Auto doesn’t choose this provider.")
        var legacy = try #require(ContractFixtures.body("helper-routing.json", "bare").object)
        legacy["copilotAuto"] = nil
        #expect(try CompanionHelperRouting(json: .object(legacy)).copilotAuto == nil)
        let decision = try #require(CompanionHelperRoutingDecision(json: ContractFixtures.json("helper-routing-auto.json")["settingsRouting"]?["copilotLastResort"]))
        #expect(decision.reason == "last_resort_unmeasured")
        #expect(decision.reasonText(labels: page.labels) == decision.displayReason)
        #expect(decision.quota["copilot-cli"]?.state == "unknown")
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
