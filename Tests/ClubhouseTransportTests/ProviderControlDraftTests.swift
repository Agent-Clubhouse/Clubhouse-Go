import Foundation
import Testing
@testable import ClubhouseTransport

/// Local draft fixtures only. Canonical annex-mobile fixtures stay pinned to desktop main.
/// Source: Clubhouse c571cefac2161c06ad445a266208494015c6ac4f, agent-provider-control.ts.
@Suite struct ProviderControlDraftTests {
    private let outcome: [String: AnnexJSON] = [
        "agentId": .string("agent"), "savedProvider": .string("claude-code"), "activeProvider": .null,
        "provider": .string("codex-cli"), "state": .string("sleeping"), "expectedState": .string("opaque-state"),
        "available": .bool(true), "availabilityMeaning": .string("local_cli_only"), "instructions": .string("equivalent"),
        "instructionScope": .string("native_primary_only"), "targetRuntime": .string("chat"), "blocked": .null,
        "canSave": .bool(true), "historyRetained": .bool(true), "contextTransferred": .bool(false),
        "nextStart": .string("new_session"), "settingsReset": .array(["model", "effort", "contextWindow", "routing", "resumePointer"].map(AnnexJSON.string)),
    ]
    private func decode<T: Decodable>(_ type: T.Type, _ values: [String: AnnexJSON]) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(AnnexJSON.object(values)))
    }
    private func command(_ kind: AnnexCommand.Kind) throws -> AnnexJSON {
        try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "cmd", epoch: "epoch", kind: kind).encoded())
    }

    @Test func legacyStartAndStopOmitAllNewFields() throws {
        #expect(try command(.stop(agentID: "agent")) == .object([
            "version": .integer(1), "commandId": .string("cmd"), "epoch": .string("epoch"), "type": .string("agent.stop"), "agentId": .string("agent"),
        ]))
        #expect(try command(.start(agentID: "agent", resume: true)) == .object([
            "version": .integer(1), "commandId": .string("cmd"), "epoch": .string("epoch"), "type": .string("agent.start"), "agentId": .string("agent"), "resume": .bool(true),
        ]))
    }

    @Test func previewSaveAndStartAreSeparateEnvelopes() throws {
        let preview = try command(.providerPreview(agentID: "agent", provider: "codex-cli"))
        #expect(preview["type"]?.string == "agent.providerPreview" && preview["provider"]?.string == "codex-cli")
        #expect(preview["expectedState"] == nil && preview["resume"] == nil && preview["message"] == nil)
        let save = try command(.providerChange(agentID: "agent", provider: "codex-cli", expectedState: "opaque-state"))
        #expect(save["type"]?.string == "agent.providerChange" && save["expectedState"]?.string == "opaque-state")
        #expect(save["resume"] == nil && save["message"] == nil)
        let start = try command(.start(agentID: "agent", resume: false, expectedProvider: "codex-cli"))
        #expect(start["expectedProvider"]?.string == "codex-cli" && start["resume"] == .bool(false))
        #expect(start["expectedSessionId"] == nil && start["expectedState"] == nil)
        #expect(try command(.stop(agentID: "agent", waitForStopped: true))["waitForStopped"] == .bool(true))
    }

    @Test func strictResumeNeedsBothProviderAndNativePointer() throws {
        #expect(throws: AnnexTransportError.malformedResponse) { try command(.start(agentID: "agent", resume: true, expectedProvider: "codex-cli")) }
        #expect(throws: AnnexTransportError.malformedResponse) { try command(.start(agentID: "agent", resume: true, expectedSessionID: "native")) }
        #expect(throws: AnnexTransportError.malformedResponse) { try command(.start(agentID: "agent", resume: false, expectedProvider: "codex-cli", expectedSessionID: "native")) }
        let resume = try command(.start(agentID: "agent", resume: true, expectedProvider: "codex-cli", expectedSessionID: "native"))
        #expect(resume["expectedSessionId"]?.string == "native" && resume["sessionId"] == nil)
    }

    @Test func preconditionIsOpaqueAndChangedResultDoesNotRequireIt() throws {
        let preview = try decode(AnnexProviderPreview.self, outcome)
        #expect(preview.expectedState == "opaque-state" && preview.outcome.permitsSave)
        var changed = outcome
        changed.removeValue(forKey: "expectedState")
        changed["savedProvider"] = .string("codex-cli"); changed["status"] = .string("changed")
        let result = try decode(AnnexProviderChangeResult.self, changed)
        guard case .changed(let saved) = result else { Issue.record("Expected changed without a preview token"); return }
        #expect(saved.savedProvider == "codex-cli" && saved.nextStart == .newSession)
        #expect(throws: (any Error).self) { try decode(AnnexProviderPreview.self, changed) }
        var same = outcome
        same["status"] = .string("already_selected"); same["provider"] = .string("claude-code")
        same["settingsReset"] = .array([]); same["nextStart"] = .string("resume_requires_validation")
        guard case .alreadySelected(let selected) = try decode(AnnexProviderChangeResult.self, same) else { Issue.record("Expected preview token for already selected"); return }
        #expect(selected.expectedState == "opaque-state" && selected.outcome.nextStart == .resumeRequiresValidation)
        // This hint contains no native pointer or resume eligibility. No Resume control is implemented.
    }

    @Test(arguments: ["agent_running", "session_capture_failed", "future_desktop_reason"])
    func anyBlockedCodePreventsSave(_ code: String) throws {
        var blocked = outcome; blocked["blocked"] = .string(code)
        let preview = try decode(AnnexProviderPreview.self, blocked)
        #expect(preview.outcome.blocked == code && !preview.outcome.permitsSave)
    }

    @Test func unknownScopeOrContradictoryReadinessDoesNotGrantSave() throws {
        for (key, value) in ["available": AnnexJSON.bool(false), "state": .string("stopping"), "activeProvider": .string("claude-code"),
                             "instructions": .string("unverified"), "availabilityMeaning": .string("future_scope"), "instructionScope": .string("future_scope"),
                             "historyRetained": .bool(false), "contextTransferred": .bool(true)] {
            var invalid = outcome; invalid[key] = value
            #expect(try !decode(AnnexProviderPreview.self, invalid).outcome.permitsSave)
        }
        var invalid = outcome; invalid["status"] = .string("changed")
        #expect(throws: (any Error).self) { try decode(AnnexProviderChangeResult.self, invalid) }
    }

    @Test func stopRequestedAloneDoesNotConfirmExitOrCapture() throws {
        var result: [String: AnnexJSON] = ["agentId": .string("agent"), "stopRequested": .bool(true)]
        #expect(try !decode(AnnexStoppedAcknowledgment.self, result).confirmsSleep)
        result["stopped"] = .bool(true); result["state"] = .string("stopping")
        #expect(try !decode(AnnexStoppedAcknowledgment.self, result).confirmsSleep)
        result["state"] = .string("sleeping")
        #expect(try decode(AnnexStoppedAcknowledgment.self, result).confirmsSleep)
    }

    @Test func capabilityRequiresExactVersionPromisesAndCommands() throws {
        let feature: [String: AnnexJSON] = ["version": .integer(1), "preview": .string("agent.providerPreview"), "change": .string("agent.providerChange"),
                                             "stoppedAcknowledgment": .bool(true), "strictStart": .bool(true)]
        var caps: [String: AnnexJSON] = ["version": .integer(1), "epoch": .string("epoch"), "controlAuth": .string("mtls-pinned-client"),
            "commands": .array(["agent.providerPreview", "agent.providerChange", "agent.stop", "agent.start"].map(AnnexJSON.string)),
            "idempotency": .object(["scope": .string("peer-and-epoch"), "maxEntries": .integer(2048), "ttlMs": .integer(3600000)])]
        #expect(try !decode(AnnexCapabilities.self, caps).supportsProviderControl)
        caps["providerControl"] = .object(feature)
        #expect(try decode(AnnexCapabilities.self, caps).supportsProviderControl)
        for (key, value) in ["version": AnnexJSON.integer(2), "strictStart": .bool(false), "stoppedAcknowledgment": .bool(false), "change": .string("future.change")] {
            var unsupported = feature; unsupported[key] = value; caps["providerControl"] = .object(unsupported)
            #expect(try !decode(AnnexCapabilities.self, caps).supportsProviderControl)
        }
        caps["providerControl"] = .object([:])
        #expect(try !decode(AnnexCapabilities.self, caps).supportsProviderControl)
        caps["providerControl"] = .object(feature); caps["commands"] = .array([.string("agent.stop")])
        #expect(try !decode(AnnexCapabilities.self, caps).supportsProviderControl)
    }
}
