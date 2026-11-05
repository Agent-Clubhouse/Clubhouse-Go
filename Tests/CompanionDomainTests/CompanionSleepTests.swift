import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite @MainActor struct CompanionSleepTests {
    private static func catalog(_ status: String) -> AnnexJSON {
        .array([.object(["id": .string("agent"), "name": .string("Agent"), "status": .string(status), "executionMode": .string("pty")])])
    }

    @Test func stopUsesExistingCommandAndWaitsForCatalogSleep() async throws {
        let harness = try await LiveServiceHarness.start { transport in
            await transport.addCommands(["agent.stop"])
            await transport.setAgents(Self.catalog("running"))
            await transport.enqueue(.completed(.object(["stopRequested": .bool(true)])))
        }
        defer { harness.stop() }
        #expect(harness.store.canSleep(harness.target), "Terminal agents do not require a chat session to sleep")
        await harness.store.sleepAgent(harness.target)
        #expect(harness.store.sleepRequests.contains(harness.target))
        let commands = await harness.transport.executed
        #expect(commands.count == 1 && commands.first?.type == "agent.stop")
        let payload = try JSONDecoder().decode(AnnexJSON.self, from: #require(commands.first).encoded())
        #expect(payload["agentId"]?.string == "agent" && payload["sessionId"] == nil && payload["resume"] == nil)
        await harness.transport.setAgents(Self.catalog("stopping"))
        await harness.store.refreshSleepState(harness.target)
        #expect(harness.store.sleepRequests.contains(harness.target))
        await harness.transport.setAgents(Self.catalog("sleeping"))
        await harness.store.refreshSleepState(harness.target)
        try await harness.waitUntil { !harness.store.sleepRequests.contains(harness.target) }
        #expect(harness.store.agent(for: harness.target)?.isSleepingOnDesktop == true)
        #expect(await harness.transport.executed.count == 1, "Refresh never repeats stop or starts usage")
    }

    @Test func olderDesktopDoesNotOfferOrSendStop() async throws {
        let harness = try await LiveServiceHarness.start { transport in
            await transport.setAgents(Self.catalog("running"))
        }
        defer { harness.stop() }
        #expect(!harness.store.canSleep(harness.target))
        do { try await harness.service.sleepAgent(harness.target, clientCommandID: "unsupported"); Issue.record("Unsupported stop must refuse") }
        catch {}
        #expect(await harness.transport.executed.isEmpty)
    }
}
