import Foundation
import Testing
@testable import ClubhouseTransport

/// Actual merged desktop wire fixtures, not a running desktop or provider.
@Suite struct ProviderControlV2ValueTests {
    private func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ProviderControlV2"))
        return try Data(contentsOf: url)
    }
    private func fixture() throws -> AnnexJSON { try JSONDecoder().decode(AnnexJSON.self, from: data("provider-control-v2")) }
    private func capabilities() throws -> AnnexJSON {
        try #require(JSONDecoder().decode(AnnexJSON.self, from: data("capabilities"))["response"]?["body"])
    }
    private func at(_ value: AnnexJSON, _ path: String) throws -> AnnexJSON {
        var result = value
        for part in path.split(separator: "/") { result = try #require(result[String(part)]) }
        return result
    }
    private func envelopes(_ value: AnnexJSON) -> [AnnexJSON] {
        if value["request"] != nil && value["body"] != nil && value["status"] != nil { return [value] }
        switch value {
        case .object(let fields): return fields.keys.sorted().flatMap { envelopes(fields[$0]!) }
        case .array(let values): return values.flatMap(envelopes)
        default: return []
        }
    }
    private func selection(_ request: AnnexJSON) throws -> AnnexProviderSelectionV2 {
        var fields = ["contractVersion": try #require(request["contractVersion"])]
        for key in ["model", "effort"] { if let value = request[key] { fields[key] = value } }
        return try AnnexJSON.object(fields).decode(AnnexProviderSelectionV2.self)
    }
    private func replace(_ value: AnnexJSON, key: String, with replacement: AnnexJSON?) throws -> AnnexJSON {
        guard case .object(var fields) = value else { throw AnnexTransportError.malformedResponse }
        fields[key] = replacement
        return .object(fields)
    }

    @Test func mergedCanonicalInputsMatchTheirFrozenDigests() throws {
        #expect(try AnnexCertificatePin.digest(data("provider-control-v2")) == "5e2da9b877b3038066e25c7d54b866977657dedc3713f5b8a170f8daf1fbf44e")
        #expect(try AnnexCertificatePin.digest(data("capabilities")) == "ef486b9c51eb4743c8e3c61f9b5335f5deae2e36d049a0e5dcc7f610942a360e")
    }

    @Test func everyCanonicalEnvelopeRetainsFailedEvidenceBeforeClassification() throws {
        let cases = envelopes(try fixture())
        #expect(cases.count == 87)
        var transitions = 0, failedStartContracts = 0
        for item in cases {
            let body = try #require(item["body"])
            let receipt = try body.decode(AnnexCommandReceipt.self)
            #expect(receipt.version == 1)
            if body["transition"] != nil {
                let transition = try #require(try receipt.providerTransitionV2)
                #expect(receipt.status == .failed)
                #expect(transition.nextWake == "fresh_read_and_review_required")
                transitions += 1
            }
            if body["contract"] != nil {
                let start = try #require(try receipt.providerStartEvidenceV2)
                #expect(receipt.status != .completed && start.version == 2)
                #expect(start.result.configPersistedByStart == false)
                failedStartContracts += 1
            }
        }
        #expect(transitions == 15 && failedStartContracts == 6)
    }

    @Test func applyAndStartAreSeparatelyNegotiatedAndMalformedIsNotAbsent() throws {
        let raw = try capabilities(), caps = try raw.decode(AnnexCapabilities.self)
        #expect(caps.supportsProviderControl && caps.supportsProviderApplyV2 && caps.supportsProviderStartV2)
        let noStart = try replace(raw, key: "providerStartV2", with: nil).decode(AnnexCapabilities.self)
        #expect(noStart.supportsProviderApplyV2 && !noStart.supportsProviderStartV2)
        let malformed = try replace(raw, key: "providerControlV2", with: .string("unknown")).decode(AnnexCapabilities.self)
        #expect(malformed.providerControlV2Advertised && !malformed.supportsProviderApplyV2)
        #expect(malformed.supportsProviderControl, "Malformed V2 must not alter legacy capability decoding, or authorize a downgrade")
        let oldRaw = try at(fixture(), "oldHost/capabilities/response/body")
        let old = try oldRaw.decode(AnnexCapabilities.self)
        #expect(!old.providerControlV2Advertised && !old.supportsProviderApplyV2 && old.supportsProviderControl)
    }

    @Test func missingUnknownOrMalformedPlatformCannotGrantManagedStart() throws {
        let raw = try capabilities(), apply = try #require(raw["providerControlV2"]), start = try #require(raw["providerStartV2"])
        let unmanaged = try at(fixture(), "windowsRefusals/unmanaged/preview/body/result").decode(AnnexProviderPreviewV2.self)
        let platforms: [AnnexJSON?] = [nil, .null, .string("darwin"), .object(["supported": .bool(true)])]
        for platform in platforms {
            let a = try replace(apply, key: "managedPlatform", with: platform)
            let s = try replace(start, key: "managedPlatform", with: platform)
            let caps = try replace(replace(raw, key: "providerControlV2", with: a), key: "providerStartV2", with: s).decode(AnnexCapabilities.self)
            #expect(caps.providerControlV2Advertised && !caps.supportsProviderStartV2)
            #expect(caps.supportsProviderApplyV2)
            #expect(caps.providerControlV2?.managedPlatform?.permitsManaged != true)
            #expect(unmanaged.permitsApply(capability: try #require(caps.providerControlV2)))
        }
        let unknown = AnnexJSON.object(["current": .string("unknown"), "supported": .bool(true), "supportedPlatforms": .array([.string("darwin"), .string("linux")]), "refusalCode": .string("managed_platform_unsupported")])
        #expect(try !unknown.decode(AnnexManagedProviderPlatform.self).permitsManaged)
    }

    @Test func providerOnlyOmissionExplicitDefaultAndNullEffortStayDistinct() throws {
        #expect(try AnnexProviderSelectionV2().fields == ["contractVersion": .integer(2)])
        #expect(try AnnexProviderSelectionV2(model: .providerDefault, effort: .clear).fields == [
            "contractVersion": .integer(2), "model": .object(["kind": .string("provider_default")]), "effort": .null,
        ])
        let selected = AnnexProviderSelectionV2(model: .selected("fixture-current-model[1m]"), effort: .selected("high"))
        #expect(try selected.fields["model"]?["id"] == .string("fixture-current-model[1m]"))
        #expect(try selected.fields["effort"] == .string("high"))
        #expect(throws: (any Error).self) { try AnnexProviderSelectionV2(model: .selected("default")).fields }
        #expect(throws: (any Error).self) { try AnnexJSON.object(["contractVersion": .integer(2), "model": .null]).decode(AnnexProviderSelectionV2.self) }
        #expect(throws: (any Error).self) { try AnnexJSON.object(["contractVersion": .integer(2), "futureChoice": .bool(true)]).decode(AnnexProviderSelectionV2.self) }
    }

    @Test func fullNextWakeEchoRetainsEveryNullAndRejectsMissingOrUnknownFields() throws {
        let raw = try at(fixture(), "inheritedPreview/body/result/contract/current")
        let value = try raw.decode(AnnexProviderNextWakeV2.self)
        #expect(try value.json == raw)
        #expect(try value.json["providerOverride"] == .null)
        #expect(throws: (any Error).self) { try replace(raw, key: "providerOverride", with: nil).decode(AnnexProviderNextWakeV2.self) }
        #expect(throws: (any Error).self) { try replace(raw, key: "futureIdentity", with: .string("unknown")).decode(AnnexProviderNextWakeV2.self) }
        let model = try #require(raw["model"])
        #expect(throws: (any Error).self) { try replace(model, key: "value", with: nil).decode(AnnexProviderNextWakeV2.Value.self) }
    }

    @Test func allCanonicalPreviewsBindAgentProviderAndExactRequestedIntent() throws {
        let caps = try capabilities().decode(AnnexCapabilities.self), capability = try #require(caps.providerControlV2)
        var previews = 0
        for item in envelopes(try fixture()) {
            guard item["request"]?["type"] == .string("agent.providerPreview"), item["request"]?["contractVersion"] == .integer(2), item["body"]?["status"] == .string("completed") else { continue }
            let request = try #require(item["request"]), result = try #require(item["body"]?["result"])
            let preview = try result.decode(AnnexProviderPreviewV2.self), intent = try selection(request)
            #expect(preview.matches(agent: try #require(request["agentId"]?.string), provider: try #require(request["provider"]?.string), selection: intent))
            #expect(!preview.matches(agent: "wrong-target", provider: preview.preview.outcome.provider, selection: intent))
            #expect(!preview.matches(agent: preview.preview.outcome.agentId, provider: "wrong-provider", selection: intent))
            if result["canSave"] == .bool(false) { #expect(!preview.permitsApply(capability: capability)) }
            previews += 1
        }
        #expect(previews == 31)
    }

    @Test func platformRefusalsDoNotEraseIndependentlySupportedUnmanagedEditing() throws {
        let fixture = try fixture(), caps = try at(fixture, "windowsRefusals/capabilities/body").decode(AnnexCapabilities.self)
        #expect(caps.supportsProviderControl && caps.supportsProviderApplyV2 && !caps.supportsProviderStartV2)
        let capability = try #require(caps.providerControlV2)
        let managed = try at(fixture, "preview/body/result").decode(AnnexProviderPreviewV2.self)
        #expect(!managed.permitsApply(capability: capability))
        let unmanaged = try at(fixture, "windowsRefusals/unmanaged/preview/body/result").decode(AnnexProviderPreviewV2.self)
        #expect(unmanaged.permitsApply(capability: capability))
        let saved = try at(fixture, "windowsRefusals/unmanaged/apply/body/result").decode(AnnexProviderApplyReceiptV2.self)
        #expect(saved.matches(unmanaged) && saved.nextWake?.readyToken == nil)
        for key in ["preview", "apply", "start"] {
            let body = try at(fixture, "windowsRefusals/\(key)/body"), receipt = try body.decode(AnnexCommandReceipt.self)
            #expect(receipt.status == .rejected && receipt.error?.code == "managed_platform_unsupported")
            #expect(receipt.result == nil && receipt.transition == nil && receipt.contract == nil)
            #expect(try receipt.providerPlatformV2?.permitsManaged == false)
        }
    }

    @Test func everyCanonicalApplyAcknowledgesOnlyItsExactSavedIntentAndNeverStarts() throws {
        let fixture = try fixture()
        var applies = 0
        for item in envelopes(fixture) {
            guard item["request"]?["type"] == .string("agent.providerChange"), item["request"]?["contractVersion"] == .integer(2), item["body"]?["status"] == .string("completed") else { continue }
            let request = try #require(item["request"])
            let value = try #require(item["body"]?["result"]).decode(AnnexProviderApplyReceiptV2.self)
            #expect(value.contract.version == 2 && value.contract.result.persisted && !value.contract.result.started)
            #expect(value.status == value.contract.result.status)
            #expect(value.contract.selection == (try selection(request)))
            #expect(value.outcome.agentId == request["agentId"]?.string)
            #expect(value.outcome.provider == request["provider"]?.string && value.contract.saved.provider == value.outcome.savedProvider)
            applies += 1
        }
        #expect(applies == 15)
        for (previewPath, applyPath) in [("preview", "applied"), ("selectedPreview", "selectedApply"), ("defaultPreview", "defaultApply"), ("claudeAlias/preview", "claudeAlias/apply")] {
            let preview = try at(fixture, "\(previewPath)/body/result").decode(AnnexProviderPreviewV2.self)
            let saved = try at(fixture, "\(applyPath)/body/result").decode(AnnexProviderApplyReceiptV2.self)
            #expect(saved.matches(preview))
        }
        for name in ["persistedSaveBlocked", "persistedSaveUnverified", "postcommitSavedReadFailure", "postcommitObserverFailure"] {
            let saved = try at(fixture, "\(name)/body/result").decode(AnnexProviderApplyReceiptV2.self)
            #expect(saved.contract.result.persisted && saved.nextWake?.readyToken == nil)
        }
    }

    @Test func conflictsRemainBlockingEvenWhenNarrowSavedAndProposedValuesAreEqual() throws {
        let fixture = try fixture(), conflicts = try at(fixture, "acknowledgedIntentConflicts")
        guard case .object(let cases) = conflicts else { Issue.record("Missing actual conflict cases"); return }
        #expect(cases.count == 11)
        var equalSelections = 0
        for item in cases.values {
            let receipt = try at(item, "apply/body").decode(AnnexCommandReceipt.self)
            let conflict = try #require(try receipt.providerTransitionV2)
            #expect(conflict.isAcknowledgedConflict && receipt.status == .failed && receipt.result == nil)
            if conflict.saved == conflict.proposed { equalSelections += 1 }
        }
        #expect(equalSelections > 0)
        let raw = try at(fixture, "acknowledgedProviderConflict/body/transition")
        let unknown = try replace(raw, key: "conflicts", with: .array([.string("future_unknown_dimension")])).decode(AnnexProviderTransitionV2.self)
        #expect(unknown.isAcknowledgedConflict && unknown.conflicts == ["future_unknown_dimension"])
        let inherited = try at(fixture, "acknowledgedInheritedUnknown/body").decode(AnnexCommandReceipt.self)
        #expect(try inherited.providerTransitionV2?.saved == nil)
        #expect(try inherited.providerTransitionV2?.persisted == true)
    }

    @Test func heldReplayIsHistoricalAndCreationIsNotHandshakeOrCurrentRuntime() throws {
        let fixture = try fixture()
        #expect(try at(fixture, "windowsRefusals/historicalApplyReplay") == at(fixture, "applied"))
        #expect(try at(fixture, "lostResponseReplay") == at(fixture, "started"))
        for key in ["started", "lostResponseReplay", "immediateExit", "failedAfterCreation", "refusedBeforeCreation"] {
            let item = try at(fixture, key), body = try #require(item["body"])
            let receipt = try body.decode(AnnexCommandReceipt.self)
            let raw = try #require(body["contract"] ?? body["result"]?["contract"])
            let value = try raw.decode(AnnexProviderStartReceiptV2.self), request = try #require(item["request"])
            let expected = try #require(request["expectedNextWake"]).decode(AnnexProviderNextWakeV2.self)
            #expect(value.matches(agent: try #require(request["agentId"]?.string), command: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string), expected: expected))
            #expect(!value.matches(agent: value.target.agentId, command: "other-command", epoch: value.target.hostEpoch, expected: expected))
            #expect(value.running.model == nil && value.running.effort == nil)
            #expect(value.running.appSessionId == nil && value.running.nativeProviderSessionId == nil)
            if key == "refusedBeforeCreation" { #expect(value.start.state == .notObserved) }
            else { #expect(value.start.wasObserved && value.start.evidence == "pty_created") }
            if key == "failedAfterCreation" { #expect(receipt.status == .failed && value.result.status == "failed_after_creation") }
            if key == "immediateExit" { #expect(value.running.state == "not_running" && value.start.wasObserved) }
        }
        let raw = try at(fixture, "started/body/result/contract/start")
        let ambiguous = try replace(raw, key: "evidence", with: .string("future_unknown")).decode(AnnexProviderStartReceiptV2.Creation.self)
        #expect(ambiguous.state == .unknown && !ambiguous.wasObserved)
    }
}
