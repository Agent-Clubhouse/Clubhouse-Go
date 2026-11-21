import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Synthetic command spies also run unchanged against main as the fail-before.
@Suite @MainActor struct CompanionProviderBoundaryTests {
    private func harness(supported: Bool) async throws -> LiveServiceHarness {
        try await LiveServiceHarness.start { transport in
            await transport.setAgents(.array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string("sleeping"), "orchestrator": .string("claude-code")])]))
            await transport.addCommands(["agent.stop", "agent.update", "agent.providerPreview", "agent.providerChange"])
            await transport.setFeature("agentSettings", .object(["version": .integer(1)]))
            if supported { await transport.setFeature("providerControl", .object(["version": .integer(1), "preview": .string("agent.providerPreview"), "change": .string("agent.providerChange"), "stoppedAcknowledgment": .bool(true), "strictStart": .bool(true)])) }
        }
    }
    private var legacySettings: AnnexJSON {
        .object(["state": .string("sleeping"), "sleeping": .bool(true), "settings": .object([
            "name": .object(["value": .string("Agent"), "editable": .string("sleeping")]),
            "orchestrator": .object(["value": .string("claude-code"), "resolved": .string("claude-code"), "editable": .string("sleeping")]),
        ])])
    }

    /// Command-spy fail-before: old Go sends agent.update here, bypassing guided
    /// equivalence/stopped-capture checks. No completed synthetic reply can grant it.
    @Test(arguments: [false, true])
    func genericCrossProviderUpdateNeverDispatchesEvenWithGuidedSupport(supported: Bool) async throws {
        let harness = try await harness(supported: supported); defer { harness.stop() }
        await harness.transport.setRead("agentSettings", legacySettings)
        await harness.transport.enqueue(.completed(legacySettings))
        do {
            _ = try await harness.service.updateSettings(.init(orchestrator: "codex-cli"), target: harness.target, clientCommandID: "unsafe-update")
            Issue.record("A generic update must not switch providers")
        } catch {
            #expect(error.localizedDescription == CompanionProviderReason.message("provider_change_requires_preview"))
        }
        #expect(await harness.transport.executed.isEmpty)
    }

    @Test func sameProviderNoOpIsStrippedWhileUnrelatedSettingKeepsItsAuthority() async throws {
        let harness = try await harness(supported: false); defer { harness.stop() }
        await harness.transport.setRead("agentSettings", legacySettings)
        _ = try await harness.service.updateSettings(.init(orchestrator: "claude-code"), target: harness.target, clientCommandID: "no-op")
        #expect(await harness.transport.executed.isEmpty)
        await harness.transport.enqueue(.completed(legacySettings))
        _ = try await harness.service.updateSettings(.init(orchestrator: "claude-code", model: "default"), target: harness.target, clientCommandID: "model-only")
        let command = try #require(await harness.transport.executed.last)
        let payload = try JSONDecoder().decode(AnnexJSON.self, from: command.encoded())
        #expect(payload["type"] == .string("agent.update") && payload["orchestrator"] == nil && payload["model"] == .string("default"))
        #expect(await harness.transport.executed.count == 1)
        #expect(CompanionAgentCommandError.message(code: "provider_change_requires_preview", message: "opaque")
                == CompanionProviderReason.message("provider_change_requires_preview"))
    }
}
