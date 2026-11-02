import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

// Hand-built data for the settled design, separate from desktop contract fixtures pending integration.
private func contextFields(kind: String = "context_window", value: AnnexJSON = .null) -> [String: AnnexJSON] {
    ["value": value, "editable": .string("sleeping"), "configurable": .bool(true), "kind": .string(kind),
     "label": .string("Server context label"), "description": .string("Provider context explanation."),
     "defaultLabel": .string("Provider default"), "costNote": .string("Provider cost note."), "notice": .null, "state": .null, "reason": .null,
     "choices": .array([.object(["id": .string("large"), "label": .string("Large (server label)"), "tokens": .integer(1_000_000)])]),
     "defaultTokens": .integer(200_000), "maxTokens": .integer(1_000_000), "applies": .array([.string("launch"), .string("resume")])]
}

private func settingsBody(context: AnnexJSON?, model: String = "model-a", provider: String = "provider-a", dispatcher: Bool = false) -> AnnexJSON {
    var settings: [String: AnnexJSON] = [
        "name": .object(["value": .string(dispatcher ? "Dispatcher" : "Agent")]),
        "model": .object(["value": .string(model), "editable": .string(dispatcher ? "always" : "sleeping")]),
        "orchestrator": .object(["value": .string(provider)])
    ]
    settings["contextWindow"] = context
    return .object(["settings": .object(settings), "sleeping": .bool(!dispatcher), "isDispatcher": .bool(dispatcher)])
}

@Suite struct CompanionContextWindowTests {
    @Test func kindsKeepProviderSemanticsAndServerLabels() throws {
        let kinds: [(String, CompanionContextWindow.Kind, String)] = [
            ("context_window", .contextWindow, "Context window"),
            ("working_window", .workingWindow, "Working context"),
            ("tier", .tier, "Context tier")
        ]
        for (wire, kind, label) in kinds {
            let settings = try CompanionAgentSettings(json: settingsBody(context: .object(contextFields(kind: wire, value: .string("large")))))
            let context = try #require(settings.contextWindow)
            #expect(context.kind == kind && context.kind?.fallbackLabel == label)
            #expect(context.choices == [.init(id: "large", label: "Large (server label)", tokens: 1_000_000)])
            #expect(context.selectedLabel == "Large (server label)")
            #expect(context.defaultTokens == 200_000 && context.maxTokens == 1_000_000)
            #expect(context.applies == [.launch, .resume] && context.configurable)
            #expect(context.displayLabel == "Server context label" && context.description == "Provider context explanation.")
            #expect(context.displayDefaultLabel == "Provider default" && context.costNote == "Provider cost note.")
            #expect(context.canEdit(sleeping: true) && !context.canEdit(sleeping: false))
            #expect(CompanionContextWindow.nextStartNote == "Applies the next time the agent starts.")
        }
    }

    @Test func defaultUnsupportedAndResetNeverInventChoices() throws {
        let initial = try #require(CompanionContextWindow(json: .object(contextFields())))
        #expect(initial.value == nil && initial.selectedLabel == initial.displayDefaultLabel)
        #expect(initial.change(to: nil) == nil)
        #expect(initial.change(to: "large") == .init(contextWindow: .set("large")))
        #expect(initial.change(to: "invented") == nil)
        let saved = try #require(CompanionContextWindow(json: .object(contextFields(value: .string("removed")))))
        #expect(saved.isSavedNotApplied && saved.selectedLabel == "removed (saved; not applied)")
        #expect(saved.choices.count == 1 && !saved.choices.contains { $0.id == "removed" })
        #expect(saved.change(to: "removed") == nil)
        #expect(saved.change(to: nil) == .init(contextWindow: .clear))
    }

    @Test func unavailableAndSleepingMetadataControlEditing() throws {
        var fields = contextFields()
        fields["configurable"] = .bool(false)
        fields["reason"] = .string("Sign in to Copilot on the desktop to load its model catalog.")
        fields["choices"] = .array([])
        let unavailable = try #require(CompanionContextWindow(json: .object(fields)))
        #expect(!unavailable.canEdit(sleeping: true) && !unavailable.isLocked(sleeping: false))
        #expect(unavailable.reason == fields["reason"]?.string && unavailable.choices.isEmpty)
        for editable in ["always", "sleeping", "never"] {
            fields = contextFields()
            fields["editable"] = .string(editable)
            let context = try #require(CompanionContextWindow(json: .object(fields)))
            #expect(context.canEdit(sleeping: false) == (editable == "always"))
            #expect(context.canEdit(sleeping: true) == (editable != "never"))
        }
        fields["editable"] = .string("always")
        fields["applies"] = .array([.string("future"), .string("launch")])
        #expect(CompanionContextWindow(json: .object(fields))?.applies == [.launch])
        var settings = try CompanionAgentSettings(json: settingsBody(context: .object(contextFields())))
        settings.sleeping = false
        #expect(settings.hasLockedSettings)
    }

    @Test func absentUnknownOrMalformedReadsAsAbsent() throws {
        for raw in [nil, AnnexJSON.null, .bool(true), .array([]), .string("large")] {
            #expect(try CompanionAgentSettings(json: settingsBody(context: raw)).contextWindow == nil)
        }
        let malformed: [(String, AnnexJSON?)] = [
            ("value", nil), ("value", .integer(100)), ("value", .string("")),
            ("editable", .string("sometimes")),
            ("configurable", .string("true")), ("applies", .null), ("choices", .null),
            ("choices", .array([.string("large")])),
            ("choices", .array([.object(["id": .string("large"), "label": .bool(false)])])),
            ("choices", .array(Array(repeating: .object(["id": .string("a"), "label": .string("A")]), count: 2))),
            ("defaultTokens", .integer(-1)), ("maxTokens", .number(1.5)), ("reason", .bool(false))
        ]
        for (key, value) in malformed {
            var fields = contextFields(); fields[key] = value
            #expect(try CompanionAgentSettings(json: settingsBody(context: .object(fields))).contextWindow == nil, "Malformed \(key)")
        }
        var unknownCounts = contextFields()
        unknownCounts["defaultTokens"] = .null; unknownCounts["maxTokens"] = .null
        #expect(CompanionContextWindow(json: .object(unknownCounts))?.displayDefaultLabel == "Provider default")
    }

    @Test func patchOmitsUntouchedFieldsAndResetIsNull() throws {
        for (change, value) in [(CompanionSettingsChange(contextWindow: .set("large")), AnnexJSON.string("large")),
                                (.init(contextWindow: .clear), .null)] {
            #expect(!change.isEmpty)
            let update = AnnexAgentUpdate(agentID: "agent", change: change)
            #expect(!update.isEmpty)
            let sent = try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "c", epoch: "e", kind: .update(update)).encoded())
            #expect(sent == .object(["version": .integer(1), "commandId": .string("c"), "epoch": .string("e"),
                                    "type": .string("agent.update"), "agentId": .string("agent"), "contextWindow": value]))
        }
        #expect(CompanionSettingsChange().isEmpty)
        #expect(AnnexAgentUpdate(agentID: "agent").isEmpty)
        let sent = try JSONDecoder().decode(AnnexJSON.self, from: AnnexCommand(commandID: "c", epoch: "e", kind: .update(.init(agentID: "agent", change: .init(model: "model-b")))).encoded())
        #expect(sent["contextWindow"] == nil)
        #expect(CompanionAgentCommandError.message(code: "invalid_context_window", message: "contextWindow must be a string")?.contains("reset to Default") == true)
    }

    @Test func returnedProviderAndModelContextWinsIncludingAbsence() throws {
        let previous = try CompanionAgentSettings(json: settingsBody(context: .object(contextFields(value: .string("large")))))
        var nextFields = contextFields(kind: "tier")
        nextFields["choices"] = .array([.object(["id": .string("long_context"), "label": .string("Long context")])])
        let next = try CompanionAgentSettings(json: settingsBody(context: .object(nextFields), model: "model-b", provider: "provider-b"))
            .keepingOptions(of: previous)
        #expect(next.contextWindow?.value == nil && next.contextWindow?.kind == .tier)
        #expect(next.contextWindow?.choices.map(\.id) == ["long_context"])
        let absent = try CompanionAgentSettings(json: settingsBody(context: nil, model: "model-b")).keepingOptions(of: previous)
        #expect(absent.contextWindow == nil, "A context setting is not a retained option list")
        let claude = try CompanionAgentSettings(json: settingsBody(context: .object(contextFields(kind: "working_window")), model: "opus[1m]"))
        #expect(claude.model.value == "opus[1m]", "Claude's suffix remains in the model menu")
    }

    @Test func dispatcherCanEditWhileRunningWhenServerAllowsIt() throws {
        var fields = contextFields(); fields["editable"] = .string("always")
        let settings = try CompanionAgentSettings(json: settingsBody(context: .object(fields), dispatcher: true))
        #expect(!settings.sleeping && settings.contextWindow?.canEdit(sleeping: settings.sleeping) == true)
        #expect(!settings.hasLockedSettings)
    }

    @Test func statesAndUnknownKindsUseServerCopyAndNeverGuessTokens() throws {
        for (wire, state) in [("unsupported", CompanionContextWindow.State.unsupported), ("pick_model", .pickModel), ("unavailable", .unavailable)] {
            var fields = contextFields(value: .string("saved-choice"))
            fields["state"] = .string(wire); fields["reason"] = .string("Desktop explains \(wire).")
            fields["notice"] = .string("Pending setting notice.")
            fields["defaultTokens"] = .null; fields["maxTokens"] = .null
            let context = try #require(CompanionContextWindow(json: .object(fields)))
            #expect(context.state == state && !context.canEdit(sleeping: true))
            #expect(context.availabilityReason == "Desktop explains \(wire).")
            #expect(context.notice == "Pending setting notice.")
            #expect(context.isSavedNotApplied && context.selectedLabel == "saved-choice (saved; not applied)")
            #expect(context.defaultTokens == nil && context.maxTokens == nil)
            fields["reason"] = .null
            #expect(CompanionContextWindow(json: .object(fields))?.availabilityReason == state.fallbackReason)
        }
        var fields = contextFields(kind: "future_kind")
        fields["label"] = .null
        let context = try #require(CompanionContextWindow(json: .object(fields)))
        #expect(context.kind == nil && context.displayLabel == "Context")
        fields["kind"] = .null
        #expect(CompanionContextWindow(json: .object(fields))?.kind == nil)
        fields["choices"] = .array([.object(["id": .string("offered"), "label": .null, "tokens": .null])])
        #expect(CompanionContextWindow(json: .object(fields))?.choices == [.init(id: "offered", label: "offered")])
    }

    @Test func topLevelResetExplainsThePreviousChoiceAndReason() throws {
        guard case .object(var body) = settingsBody(context: .object(contextFields())) else { return }
        body["contextWindowReset"] = .object(["previous": .string("large"), "reason": .string("The new model doesn't offer this choice.")])
        let reset = try #require(try CompanionAgentSettings(json: .object(body)).contextWindowReset)
        #expect(reset.message == "Context setting reset to Default. Previous choice: large. The new model doesn't offer this choice.")
        #expect(CompanionContextWindowReset(json: .null) == nil)
        #expect(CompanionContextWindowReset(json: .object(["reason": .bool(true)])) == nil)
    }

    @Test func unavailableKeepsSavedChoiceWithoutClaimingItWasCleared() throws {
        var fields = contextFields(value: .string("long_context"))
        fields["state"] = .string("unavailable")
        fields["configurable"] = .bool(false)
        fields["choices"] = .array([])
        fields["notice"] = .null
        fields["reason"] = .string("The model catalog hasn't been confirmed.")
        let settings = try CompanionAgentSettings(json: settingsBody(context: .object(fields)))
        let context = try #require(settings.contextWindow)
        #expect(context.value == "long_context" && context.isSavedNotApplied)
        #expect(context.selectedLabel == "long_context (saved; not applied)")
        #expect(context.notice == nil && settings.contextWindowReset == nil)
    }

    @Test func terminalClearShowsSettingsNoticeWithoutRequiringChat() throws {
        var fields = contextFields()
        let notice = "The saved context choice was cleared because this model no longer supports it."
        fields["notice"] = .string(notice)
        guard case .object(var body) = settingsBody(context: .object(fields)),
              case .object(var settings)? = body["settings"] else { return }
        settings["runtime"] = .object(["value": .string("terminal")])
        body["settings"] = .object(settings)
        let decoded = try CompanionAgentSettings(json: .object(body))
        #expect(decoded.runtime.value == "terminal" && decoded.contextWindow?.value == nil)
        #expect(decoded.contextWindow?.notice == notice)
    }
}

@Suite struct CompanionChatContextTests {
    // Hand-built projection coverage only; this does not prove start/resume-to-phone wire delivery.
    @Test func notAppliedUsesTheExistingNoticeMessageWithoutParsingIt() {
        var projector = CompanionChatProjector()
        let message = "Saved choice wasn't passed. Keep this provider's wording: [1m] / long_context."
        let notice: AnnexJSON = .object([
            "agentId": .string("agent"), "sessionId": .string("session"), "seq": .integer(2),
            "ts": .integer(1_793_566_800_000), "type": .string("notice"),
            "data": .object(["level": .string("warn"), "code": .string("context_window_not_applied"), "message": .string(message)])
        ])
        let previousStatus = projector.status
        projector.apply(notice)
        projector.apply(notice) // Replayed sequence doesn't duplicate the once-per-start/resume notice.
        #expect(projector.items == [.notice(id: "event-session-2", text: message)])
        #expect(projector.status == previousStatus)
    }

    @Test func readOnlyReportKeepsCapacityCompactionAndReservedDistinct() throws {
        let context: AnnexJSON = .object(["effectiveTokens": .integer(200_000), "compactAtTokens": .integer(160_000),
                                          "reservedTokens": .integer(20_000), "note": .string("Reported by this session.")])
        let controls = try #require(CompanionChatControls(snapshot: .object(["context": context])))
        #expect(controls.context?.effectiveTokens == 200_000 && controls.context?.compactAtTokens == 160_000 && controls.context?.reservedTokens == 20_000)
        #expect(controls.context?.note == "Reported by this session.")
        #expect(controls.context?.summary.contains("Effective context:") == true)
        #expect(controls.context?.summary.contains("Auto-compaction at:") == true)
        #expect(controls.context?.summary.contains("Reserved:") == true)
        var changed = controls
        changed.apply(type: "model_changed", data: .object(["modelId": .string("new")]))
        #expect(changed.context == nil, "Don't display the previous model's context")
        changed = controls
        changed.apply(type: "session_started", data: .object([:]))
        #expect(changed.context == nil)
    }

    @Test func unknownAndMalformedReportsAreHidden() {
        for raw in [nil, AnnexJSON.null, .string("200k"), .object([:]),
                    .object(["effectiveTokens": .integer(-1), "compactAtTokens": .null, "reservedTokens": .null, "note": .null]),
                    .object(["effectiveTokens": .string("200000"), "compactAtTokens": .null, "reservedTokens": .null, "note": .null]),
                    .object(["effectiveTokens": .null, "compactAtTokens": .null, "reservedTokens": .null, "note": .null])] {
            #expect(CompanionChatContext(json: raw) == nil)
        }
        let partial = CompanionChatContext(json: .object(["effectiveTokens": .null, "compactAtTokens": .integer(100_000), "reservedTokens": .integer(0), "note": .null]))
        #expect(partial?.effectiveTokens == nil && partial?.compactAtTokens == 100_000 && partial?.reservedTokens == 0)
    }

    @Test func existingSessionInfoAndUsageEventsUpdateReportedFacts() throws {
        var controls = CompanionChatControls()
        controls.apply(type: "session_info", data: .object(["contextLimits": .object([
            "effectiveTokens": .integer(200_000), "compactAtTokens": .integer(160_000), "reservedTokens": .integer(20_000), "note": .null
        ])]))
        #expect(controls.context?.compactAtTokens == 160_000)
        controls.apply(type: "usage", data: .object(["context": .object(["size": .integer(180_000), "used": .integer(10)])]))
        #expect(controls.context?.effectiveTokens == 180_000 && controls.context?.reservedTokens == 20_000)
        controls.apply(type: "session_info", data: .object(["contextLimits": .null]))
        #expect(controls.context == nil)
        controls.apply(type: "usage", data: .object(["context": .object(["size": .integer(128_000)])]))
        #expect(controls.context == .init(effectiveTokens: 128_000))
        controls.apply(type: "usage", data: .object(["context": .object(["size": .null])]))
        #expect(controls.context?.effectiveTokens == nil)
    }
}

@MainActor @Suite struct CompanionContextWindowServiceTests {
    private func start() async throws -> LiveServiceHarness {
        try await LiveServiceHarness.start { transport in
            await transport.addCommands(["agent.update"])
            await transport.setFeature("agentSettings", .object(["version": .integer(1)]))
            await transport.setFeature("contextWindow", .object(["version": .integer(1)]))
        }
    }

    @Test func savedContextAndModelChangesFollowDesktopWithoutStartingAgent() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let before = settingsBody(context: .object(contextFields(value: .string("large"))))
        await harness.transport.setRead("agentSettings", before)
        let previous = try await harness.store.settings(for: harness.target)
        await harness.transport.enqueue(.completed(settingsBody(context: .object(contextFields()))))
        let reset = try await harness.store.updateSettings(.init(contextWindow: .clear), target: harness.target)
        #expect(reset.contextWindow?.value == nil)
        var fields = contextFields(); fields["choices"] = .array([]); fields["configurable"] = .bool(false)
        fields["reason"] = .string("Unavailable for this model.")
        await harness.transport.enqueue(.completed(settingsBody(context: .object(fields), model: "model-b")))
        let changed = try await harness.store.updateSettings(.init(model: "model-b"), target: harness.target)
        #expect(changed.keepingOptions(of: previous).contextWindow?.choices.isEmpty == true)
        #expect(changed.contextWindow?.configurable == false)
        let commands = await harness.transport.executed
        #expect(commands.count == 2)
        #expect(commands.map(\.type) == ["agent.update", "agent.update"])
        guard case .update(let resetCommand) = commands[0].kind, case .update(let modelCommand) = commands[1].kind else {
            Issue.record("Expected only settings updates"); return
        }
        #expect(resetCommand.contextWindow == .clear)
        #expect(modelCommand.model == "model-b" && modelCommand.contextWindow == nil)
    }

    @Test func dispatcherUsesTheSameUpdateAndInvalidContextErrorMapping() async throws {
        let harness = try await start()
        defer { harness.stop() }
        let target = CompanionTarget(hostID: LiveServiceHarness.hostID, projectID: "__dispatcher__", agentID: "durable_dispatcher")
        var fields = contextFields(value: .string("large")); fields["editable"] = .string("always")
        await harness.transport.enqueue(.completed(settingsBody(context: .object(fields), dispatcher: true)))
        let saved = try await harness.service.updateSettings(.init(contextWindow: .set("large")), target: target, clientCommandID: "dispatcher-context")
        #expect(saved.contextWindow?.value == "large" && saved.contextWindow?.canEdit(sleeping: false) == true)
        guard case .update(let command)? = await harness.transport.executed.first?.kind else {
            Issue.record("Missing Dispatcher update"); return
        }
        #expect(command.agentID == "durable_dispatcher" && command.contextWindow == .set("large"))
        await harness.transport.enqueue(.rejected(code: "invalid_context_window", message: "contextWindow must be a valid choice"))
        let error = await serviceErrorText {
            _ = try await harness.service.updateSettings(.init(contextWindow: .set("removed")), target: target, clientCommandID: "invalid-context")
        }
        #expect(error == CompanionAgentCommandError.message(code: "invalid_context_window", message: nil))
        await harness.transport.enqueue(.rejected(code: "agent_running", message: "agent_running"))
        #expect(await serviceErrorText {
            _ = try await harness.service.updateSettings(.init(contextWindow: .clear), target: harness.target, clientCommandID: "awake")
        } == CompanionAgentSettings.lockedHint)
        #expect(await harness.transport.executed.allSatisfy { $0.type == "agent.update" })
    }

    @Test func contextWritesRequireAnAdvertisedV1Capability() async throws {
        let harness = try await start()
        defer { harness.stop() }
        #expect(harness.host?.canSetContextWindow == true)
        for feature in [AnnexJSON.null, .object(["version": .string("1")]), .object(["version": .integer(0)]), .object(["version": .integer(2)])] {
            await harness.transport.setFeature("contextWindow", feature)
            try await harness.refreshCatalog()
            #expect(harness.host?.canSetContextWindow == false)
            for change in [CompanionSettingsChange(contextWindow: .clear), .init(contextWindow: .set("large"))] {
                #expect(await serviceErrorKind {
                    _ = try await harness.service.updateSettings(change, target: harness.target, clientCommandID: "gated")
                } == .unavailable)
            }
        }
        #expect(await harness.transport.executed.isEmpty)
    }
}
