import Foundation
import Testing
@testable import CompanionDomain

@MainActor @Suite struct CompanionPlanLimitsTests {
    @Test func agentScopeReadsOnlyItsDesktopAndNeverGuessesAMissingProvider() async throws {
        let hosts = CompanionPreviewService.hosts(now: .now, helperPresets: true, autoQuota: true) + CompanionPreviewService.planLimitsHosts()
        let target = CompanionPreviewService.target
        var agent = try #require(hosts[0].projects.flatMap(\.agents).first { $0.id == target })
        let scope = CompanionAgentPlanLimitsScope(target: target, agent: agent)
        #expect(scope.providerID == "claude-code")
        #expect(scope.readableHosts(in: hosts).map(\.id) == [target.hostID])
        let screen = CompanionPlanLimitsScreen()
        var reads: [String] = []
        await screen.refresh(hosts: scope.readableHosts(in: hosts)) { id in
            reads.append(id)
            return CompanionPreviewService.planLimitsPage
        }
        #expect(reads == [target.hostID], "Other readable desktops must not be contacted by an agent sheet")
        #expect(screen.readings.keys.sorted() == [target.hostID])
        agent.orchestrator = nil
        #expect(CompanionAgentPlanLimitsScope(target: target, agent: agent).readableHosts(in: hosts).isEmpty)
        agent.orchestrator = ""
        #expect(CompanionAgentPlanLimitsScope(target: target, agent: agent).providerID == nil)
        #expect(CompanionAgentPlanLimitsScope(target: target, agent: nil).readableHosts(in: hosts).isEmpty)
    }

    @Test func agentScopeKeepsOfflineUnsupportedAndMissingDesktopStates() throws {
        var hosts = CompanionPreviewService.hosts(now: .now, helperPresets: true, autoQuota: true)
        let target = CompanionPreviewService.target
        let agent = try #require(hosts[0].projects.flatMap(\.agents).first { $0.id == target })
        let scope = CompanionAgentPlanLimitsScope(target: target, agent: agent)
        hosts[0].connection = .offline
        #expect(scope.readableHosts(in: hosts).isEmpty)
        #expect(scope.group(in: hosts)?.unavailableText == "Studio Mac is offline")
        hosts[0].connection = .connected
        hosts[0].helperRouting = nil
        #expect(scope.readableHosts(in: hosts).isEmpty)
        #expect(scope.group(in: hosts)?.unavailableText == "This desktop doesn’t report plan limits.")
        #expect(scope.group(in: []) == nil)
        #expect(scope.readableHosts(in: []).isEmpty)
    }

    @Test func groupsKeepMachineIdentityAndUnavailableStates() throws {
        let hosts = CompanionPreviewService.hosts(now: .now, helperPresets: true, autoQuota: true) + CompanionPreviewService.planLimitsHosts()
        let groups = CompanionPlanLimitsGroup.groups(hosts)
        #expect(groups.count == 4)
        #expect(groups.map(\.id) == hosts.map(\.id))
        #expect(groups.filter(\.canRead).count == 2)
        #expect(groups[1].unavailableText == "Travel MacBook is offline")
        #expect(groups[3].unavailableText == "This desktop doesn’t report plan limits.")
        var reconnecting = hosts[0]; reconnecting.connection = .reconnecting
        #expect(CompanionPlanLimitsGroup(host: reconnecting).unavailableText == "Looking for Studio Mac…")
        #expect(CompanionPlanLimitsGroup.groups([]).isEmpty)
        let page = CompanionPreviewService.planLimitsPage
        #expect(groups[0].providerIDs(in: page).contains("claude-code"))
        #expect(groups[2].providerIDs(in: page).contains("claude-code"))
        #expect(page.providers["codex-cli"]?.quota?.weekly?.usedPercent == nil)
        #expect(page.providers["codex-cli"]?.quota?.unknownReason == "read_failed")
    }

    @Test func committedDesktopContractKeepsPartialWindowsAndAppScope() throws {
        let routing = try ContractFixtures.json("helper-routing.json")
        #expect(routing["bare"]?["request"]?["path"]?.string == "/api/v1/mobile/helper-routing")
        let cases = try ContractFixtures.json("helper-routing-quota.json")["cases"]
        let partial = try #require(CompanionHelperQuota(json: cases?["oneWindowUnreadable"]))
        #expect(partial.weekly?.usedPercent == 41)
        #expect(partial.fiveHour?.usedPercent == nil)
        #expect(partial.unreadableWindows == ["fiveHour"])
        let stale = try #require(CompanionHelperQuota(json: cases?["unknownStale"]))
        #expect(stale.state == "unknown" && stale.unknownReason == "stale")
        #expect(stale.asOf != nil && stale.weekly == nil)
    }

    @Test func refreshIsIndependentAndFailuresDoNotRedateReadings() async throws {
        let screen = CompanionPlanLimitsScreen()
        let hosts = CompanionPreviewService.planLimitsHosts()
        var second = hosts[0]; second.id = "slow"
        var finish: CheckedContinuation<CompanionHelperRouting, Never>?
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            await screen.refresh(hosts: [hosts[0], second, hosts[1]]) { id in
                if id == "slow" {
                    return await withCheckedContinuation { finish = $0; started.continuation.yield(()) }
                }
                return CompanionPreviewService.planLimitsPage
            }
        }
        for await _ in started.stream { break }
        // Give the independent fast child a turn while the other desktop is suspended.
        for _ in 0..<100 where screen.readings[hosts[0].id]?.settings == nil { await Task.yield() }
        #expect(screen.readings[hosts[0].id]?.settings != nil)
        #expect(screen.readings[hosts[1].id] == nil, "Unsupported desktops must not be read")
        finish?.resume(returning: CompanionPreviewService.planLimitsPage)
        await task.value
        let previous = try #require(screen.readings[hosts[0].id])
        let receivedAt = previous.receivedAt
        await screen.load(hostID: hosts[0].id) { _ in throw CompanionServiceError.unavailable("One desktop failed") }
        #expect(previous.error == "One desktop failed")
        #expect(previous.receivedAt == receivedAt)
        #expect(screen.readings["slow"]?.error == nil)
    }

    @Test func pollingStopsOnCancellationAndMissingRefreshDelay() async {
        let screen = CompanionPlanLimitsScreen()
        var reads = 0
        await screen.poll(hostID: "no-ttl") { _ in
            reads += 1
            var page = CompanionPreviewService.planLimitsPage
            for id in page.providers.keys { page.providers[id]?.quota?.refreshAfterSeconds = nil }
            return page
        }
        #expect(reads == 1)
        let task = Task {
            await screen.poll(hostID: "cancelled") { _ in
                reads += 1
                return CompanionPreviewService.planLimitsPage
            }
        }
        for _ in 0..<100 where reads < 2 { await Task.yield() }
        task.cancel()
        await task.value
        #expect(reads == 2)
    }
}
