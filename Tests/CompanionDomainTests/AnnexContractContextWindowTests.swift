import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite struct AnnexContractContextWindowTests {
    private func fixture() throws -> AnnexJSON { try ContractFixtures.json("agent-settings-context-window.json") }

    @Test func committedCasesKeepServerLabelsChoicesStatesAndNullableCounts() throws {
        guard case .object(let cases)? = try fixture()["cases"] else { Issue.record("Missing context cases"); return }
        #expect(cases.count == 8)
        for (name, raw) in cases {
            let context = try #require(CompanionContextWindow(json: raw), "Context case \(name)")
            #expect(context.label == raw["label"]?.string)
            #expect(context.description == raw["description"]?.string)
            #expect(context.defaultLabel == raw["defaultLabel"]?.string)
            #expect(context.defaultTokens == raw["defaultTokens"]?.int)
            #expect(context.maxTokens == raw["maxTokens"]?.int)
            #expect(context.choices.map(\.id) == raw["choices"].arrayValue.compactMap { $0["id"]?.string })
            #expect(context.choices.map(\.label) == raw["choices"].arrayValue.compactMap { $0["label"]?.string })
            #expect(context.applies == [.launch, .resume])
            if raw["configurable"] == .bool(false) {
                #expect(!context.canEdit(sleeping: true))
                #expect(context.availabilityReason == raw["reason"]?.string)
            }
        }
        let unavailable = try #require(CompanionContextWindow(json: cases["unavailableWithSavedChoice"]))
        #expect(unavailable.value == "long_context" && unavailable.isSavedNotApplied && unavailable.notice == nil)
        #expect(unavailable.canReset(sleeping: true, isDispatcher: false))
        #expect(!unavailable.canReset(sleeping: false, isDispatcher: false))
        #expect(unavailable.canReset(sleeping: false, isDispatcher: true))
        let dispatcher = try #require(CompanionContextWindow(json: cases["dispatcher"]))
        #expect(dispatcher.canEdit(sleeping: false))
        var tier = try #require(CompanionContextWindow(json: cases["tier"]))
        #expect(tier.change(to: "default") == .init(contextWindow: .set("default")), "The standard tier is a choice, distinct from no saved choice")
        tier.value = "default"
        #expect(tier.selectedLabel == "Standard (200K input)")
        #expect(tier.change(to: nil) == .init(contextWindow: .clear))
    }

    @Test func currentAndPendingRemainIndependentAndNoticeIsVerbatim() throws {
        let fixture = try fixture()
        let pending = try #require(CompanionContextWindow(json: fixture["currentAndPending"]?["pending"]))
        let current = try #require(CompanionChatContext(json: fixture["currentAndPending"]?["current"]))
        #expect(pending.value == "500000" && current.effectiveTokens == 300_000)
        let snapshot = try #require(CompanionChatControls(snapshot: try ContractFixtures.body("chat-snapshot.json")["chatControls"]))
        #expect(snapshot.context == current)
        let notice = try #require(fixture["notAppliedNotice"])
        #expect(notice["data"]?["code"]?.string == "context_window_not_applied")
        var projector = CompanionChatProjector()
        projector.apply(notice)
        #expect(projector.items == [.notice(id: "event-sess_live-1", text: try #require(notice["data"]?["message"]?.string))])
        // This committed notice is hand-built; projection doesn't establish start/resume-to-phone delivery.
    }

    @Test func committedUpdatesEncodeOnlyChangedFieldsAndDecodeFreshResults() throws {
        let cases = try ContractFixtures.cases("commands/agent.update.json")
        let contextCases = cases.filter {
            $0["request"]?["contextWindow"] != nil || $0["response"]?["body"]?["result"]?["contextWindowReset"] != nil
        }
        #expect(contextCases.count == 9)
        for item in contextCases {
            let request = try #require(item["request"])
            let value = request["contextWindow"]
            let change = CompanionSettingsChange(name: request["name"]?.string, model: request["model"]?.string,
                contextWindow: value.map { $0.string.map(CompanionSettingsChange.Clearable.set) ?? .clear })
            let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string),
                                       kind: .update(.init(agentID: try #require(request["agentId"]?.string), change: change)))
            #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == request)
            let receipt = try #require(item["response"]?["body"]).decode(AnnexCommandReceipt.self)
            if let result = receipt.result {
                let settings = try CompanionAgentSettings(json: result)
                let context = try #require(settings.contextWindow)
                #expect(context.value == result["settings"]?["contextWindow"]?["value"]?.string)
                if let reset = settings.contextWindowReset {
                    #expect(context.value == nil && context.notice == reset.reason)
                    #expect(reset.message.contains(try #require(reset.reason)))
                }
                if result["isDispatcher"] == .bool(true) { #expect(context.canEdit(sleeping: false)) }
            } else if let error = receipt.error {
                #expect(CompanionAgentCommandError.message(code: error.code, message: error.message) != nil)
            }
        }
        let capabilities = try ContractFixtures.body("capabilities.json").decode(AnnexCapabilities.self)
        #expect(capabilities.supportsContextWindow)
    }
}
