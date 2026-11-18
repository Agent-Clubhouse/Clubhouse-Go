import XCTest
import SwiftUI
import Vision
import ClubhouseTransport
@testable import ClubhouseGo

/// Real Root/TabView/NavigationStack owners, synthetic catalogs and in-memory service only.
@MainActor final class CompanionHomeVisibilityTests: XCTestCase {
    func testHiddenHomeDoesNoWorkDuring100RenderedDispatchUpdatesAndReturnsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        XCTAssertGreaterThan(fixture.counts[.layout, default: 0], 0, "Home really mounted first")
        XCTAssertEqual(fixture.counts[.layout], fixture.counts[.content], "One layout per visible content construction")
        fixture.select(.dispatcher)
        try await fixture.wait { !fixture.homeVisible && fixture.store.selection == fixture.dispatcher && fixture.chatBodies > 0 }
        let hidden = fixture.expensiveCounts
        for batch in 0..<10 {
            let rendered = fixture.chatBodies
            for chunk in 0..<10 {
                fixture.store.apply(.textDelta(fixture.dispatcher, messageID: "perf-stream", text: " x", sequence: batch * 10 + chunk + 1))
            }
            try await fixture.wait { fixture.chatBodies > rendered }
            XCTAssertEqual(fixture.expensiveCounts, hidden, "Rendered batch \(batch) must not build offscreen Home")
        }
        XCTAssertEqual(fixture.store.conversation(for: fixture.dispatcher).items.compactMap { item -> String? in
            if case .message(let message) = item, message.id == "perf-stream" { return message.text }; return nil
        }.first, "start" + String(repeating: " x", count: 100))
        XCTAssertEqual(fixture.store.conversation(for: fixture.dispatcher).lastSequence, 100)
        fixture.hosts[0].projects[0].agents[1].name = "Fresh title"
        fixture.hosts[0].projects[0].agents[1].status = .approval
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.turn()
        XCTAssertEqual(fixture.expensiveCounts, hidden, "A hidden host snapshot does not build Home either")
        fixture.select(.home)
        try await fixture.wait { fixture.group()?.agents.contains { $0.name == "Fresh title" } == true }
        XCTAssertEqual(fixture.group()?.liveStatus, .approval)
        let freshText = try await fixture.waitForRenderedText("Fresh title")
        XCTAssertTrue(freshText.contains("Fresh title"), "The returned Home must actually render the fresh title")
        XCTAssertTrue(fixture.projection?.projects.contains { $0.entry.isLinked } == true)
        XCTAssertEqual(fixture.counts[.layout], fixture.counts[.content])
        fixture.capture("Home fresh after 100 rendered Dispatch updates")
    }

    func testPushedHomeRouteFreezesAllRowsDuring100RenderedChunksAndPopKeepsTheSession() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.hosts[0].canUpdateApp = true
        fixture.hosts[0].appUpdate = .init(state: .ready, currentVersion: "1.0.0", availableVersion: "1.1.0")
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.mount()
        let scope = try XCTUnwrap(fixture.scope)
        scope.wrappedValue = .host("synthetic-host-0")
        fixture.preferences.toggleFold("quiet:synthetic-host-0-project-8")
        try await fixture.wait { fixture.projection?.projects.allSatisfy { $0.entry.members.allSatisfy { $0.host.id == "synthetic-host-0" } } == true }
        let order = try XCTUnwrap(fixture.group()).agents.map(\.id)
        let target = fixture.hosts[0].projects[0].agents[1].id
        fixture.streamTarget = target
        await fixture.store.load(target)
        fixture.push(.agent(target))
        try await fixture.wait { fixture.isFrozen && fixture.chatBodies > 0 && fixture.counts[.row, default: 0] > 0 && fixture.counts[.rowMenu, default: 0] > 0 }
        // Native context menus are lazy until opened; projectMenu stays in every frozen
        // counter equality below, and LargeCatalog exercises the mounted menu itself.
        XCTAssertGreaterThan(fixture.counts[.quietRows, default: 0], 0)
        XCTAssertGreaterThan(fixture.counts[.appUpdate, default: 0], 0)
        XCTAssertGreaterThan(fixture.counts[.chips, default: 0], 0)
        try await fixture.turn()
        // Baseline after native push/lazy realisation settles, not during its animation.
        // No chunk is delivered until readiness; every subsequent zero-work check remains strict.
        let sequenceBeforeReadiness = fixture.store.conversation(for: target).lastSequence
        try await fixture.waitForPushedRealisation()
        XCTAssertEqual(fixture.store.conversation(for: target).lastSequence, sequenceBeforeReadiness, "Readiness must not deliver any stream chunks")
        fixture.assertPushCost()
        let before = fixture.expensiveCounts
        let ownerBefore = fixture.counts[.owner, default: 0]
        for batch in 0..<10 {
            let rendered = fixture.chatBodies
            for chunk in 0..<10 {
                fixture.store.apply(.textDelta(target, messageID: "perf-stream", text: " route", sequence: batch * 10 + chunk + 1))
            }
            try await fixture.wait { fixture.chatBodies > rendered }
            XCTAssertEqual(fixture.expensiveCounts, before, "Every row/menu counter must stay fixed for rendered pushed batch \(batch)")
        }
        XCTAssertEqual(fixture.store.conversation(for: target).lastSequence, 100)
        XCTAssertEqual(fixture.store.conversation(for: target).items.compactMap { item -> String? in
            if case .message(let message) = item, message.id == "perf-stream" { return message.text }; return nil
        }.first, "start" + String(repeating: " route", count: 100))
        fixture.attachStreamingCounters("100 pushed chunks", before: before, ownerBefore: ownerBefore)
        // Status/connection changes while pushed must not redraw the backdrop, or wait one extra frame on pop.
        fixture.hosts[1].connection = .reconnecting
        fixture.hosts[0].projects[0].agents[2].status = .approval
        fixture.hosts[0].projects[0].agents[2].lastActivity = Date(timeIntervalSince1970: 1_900_000_005)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.turn()
        XCTAssertEqual(fixture.expensiveCounts, before)
        XCTAssertEqual(fixture.navigation?.wrappedValue.paths[.home]?.count, 1)
        fixture.frames.removeAll()
        fixture.pop()
        try await fixture.wait { !fixture.isFrozen && fixture.counts[.content, default: 0] > before[.content, default: 0] }
        XCTAssertEqual(fixture.scope?.wrappedValue, .host("synthetic-host-0"))
        XCTAssertTrue(fixture.projection?.projects.allSatisfy { $0.entry.members.allSatisfy { $0.host.id == "synthetic-host-0" } } == true)
        XCTAssertTrue(fixture.preferences.expandedFolds.contains("quiet:synthetic-host-0-project-8"))
        XCTAssertEqual(fixture.group()?.agents.map(\.id), order, "Back is the SAME Recent session")
        XCTAssertEqual(fixture.group()?.liveStatus, .approval, "Status refreshes without sorting")
        XCTAssertFalse(try fixture.renderedText().isEmpty)
        // Select All to include the changed machine, then repeat a push/pop with a visible offline banner.
        let linkedBefore = fixture.counts[.linkedRows, default: 0]
        scope.wrappedValue = .all
        try await fixture.wait { fixture.frames.last?.1.contains("Reconnecting") == true && fixture.counts[.linkedRows, default: 0] > linkedBefore }
        fixture.push(.agent(target))
        try await fixture.wait { fixture.isFrozen }
        let linkedSequenceBeforeReadiness = fixture.store.conversation(for: target).lastSequence
        try await fixture.waitForPushedRealisation()
        XCTAssertEqual(fixture.store.conversation(for: target).lastSequence, linkedSequenceBeforeReadiness, "Linked readiness must not deliver any stream chunks")
        fixture.assertPushCost()
        XCTAssertGreaterThan(fixture.counts[.linkedRows, default: 0], 0)
        let linked = fixture.expensiveCounts
        let linkedOwnerBefore = fixture.counts[.owner, default: 0]
        let rendered = fixture.chatBodies
        fixture.store.apply(.textDelta(target, messageID: "perf-stream", text: " linked", sequence: 101))
        try await fixture.wait { fixture.chatBodies > rendered }
        XCTAssertEqual(fixture.expensiveCounts, linked, "The All-scope linked-row body is frozen too")
        fixture.attachStreamingCounters("Linked pushed chunk", before: linked, ownerBefore: linkedOwnerBefore)
        fixture.hosts[1].connection = .offline
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.turn()
        fixture.frames.removeAll()
        fixture.pop()
        try await fixture.wait { !fixture.frames.isEmpty && !fixture.isFrozen }
        let first = try XCTUnwrap(fixture.frames.first)
        XCTAssertFalse(first.0)
        XCTAssertTrue(first.1.contains("Synthetic Desktop 1 is offline"), "The FIRST pop construction uses current banner inputs")
        let offlineText = try await fixture.waitForRenderedText("offline")
        XCTAssertTrue(offlineText.contains("offline"))
        fixture.capture("Home first returned frame has current connection state")
    }

    func testPushedHomeKeepsLayoutStableAcross100RenderedChunksWithinSnapshotBudgetAndReturnsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.hosts[0].canUpdateApp = true
        fixture.hosts[0].appUpdate = .init(state: .ready, currentVersion: "1.0.0", availableVersion: "1.1.0")
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.mount()
        let scope = try XCTUnwrap(fixture.scope)
        scope.wrappedValue = .host("synthetic-host-0")
        fixture.preferences.toggleFold("quiet:synthetic-host-0-project-8")
        try await fixture.wait { fixture.projection?.projects.allSatisfy { $0.entry.members.allSatisfy { $0.host.id == "synthetic-host-0" } } == true }
        let order = try XCTUnwrap(fixture.group()).agents.map(\.id)
        let target = fixture.hosts[0].projects[0].agents[1].id
        fixture.streamTarget = target
        await fixture.store.load(target)
        fixture.push(.agent(target))
        try await fixture.wait { fixture.isFrozen && fixture.chatBodies > 0 && fixture.counts[.row, default: 0] > 0 && fixture.counts[.rowMenu, default: 0] > 0 }
        // Native context menus are lazy until opened; #557 retains their all-counter
        // equality. LargeCatalog separately exercises the actual mounted project menu.
        XCTAssertGreaterThan(fixture.counts[.quietRows, default: 0], 0)
        XCTAssertGreaterThan(fixture.counts[.appUpdate, default: 0], 0)
        XCTAssertGreaterThan(fixture.counts[.chips, default: 0], 0)
        try await fixture.turn()
        fixture.assertPushCost()
        // Deliberately narrower than #557's intact all-row/per-event regression.
        // This contract covers construction/layout work during streaming, not child bodies.
        let before = fixture.expensiveCounts
        let constructionKinds: Set<CompanionHomeBuildProbe.Kind> = [.content, .layout, .header, .quiet, .snapshot]
        let construction = before.filter { constructionKinds.contains($0.key) }
        for batch in 0..<10 {
            let rendered = fixture.chatBodies
            for chunk in 0..<10 {
                fixture.store.apply(.textDelta(target, messageID: "perf-stream", text: " route", sequence: batch * 10 + chunk + 1))
            }
            try await fixture.wait { fixture.chatBodies > rendered }
            XCTAssertEqual(fixture.expensiveCounts.filter { constructionKinds.contains($0.key) }, construction, "Layout/content construction stays fixed for rendered pushed batch \(batch)")
        }
        XCTAssertEqual(fixture.store.conversation(for: target).lastSequence, 100)
        XCTAssertEqual(fixture.store.conversation(for: target).items.compactMap { item -> String? in
            if case .message(let message) = item, message.id == "perf-stream" { return message.text }; return nil
        }.first, "start" + String(repeating: " route", count: 100))
        // The stricter no-host-event-rebuild contract remains intact in #557.
        // This test requires fresh status and connection presentation on pop.
        fixture.hosts[1].connection = .reconnecting
        fixture.hosts[0].projects[0].agents[2].status = .approval
        fixture.hosts[0].projects[0].agents[2].lastActivity = Date(timeIntervalSince1970: 1_900_000_005)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.turn()
        // #557 retains the strict host-event all-counter comparison unchanged.
        XCTAssertEqual(fixture.navigation?.wrappedValue.paths[.home]?.count, 1)
        fixture.frames.removeAll()
        fixture.pop()
        try await fixture.wait { !fixture.isFrozen && fixture.counts[.content, default: 0] > before[.content, default: 0] }
        XCTAssertEqual(fixture.scope?.wrappedValue, .host("synthetic-host-0"))
        XCTAssertTrue(fixture.projection?.projects.allSatisfy { $0.entry.members.allSatisfy { $0.host.id == "synthetic-host-0" } } == true)
        XCTAssertTrue(fixture.preferences.expandedFolds.contains("quiet:synthetic-host-0-project-8"))
        XCTAssertEqual(fixture.group()?.agents.map(\.id), order, "Back is the SAME Recent session")
        XCTAssertEqual(fixture.group()?.liveStatus, .approval, "Status refreshes without sorting")
        XCTAssertFalse(try fixture.renderedText().isEmpty)
        // Select All to include the changed machine, then repeat a push/pop with a visible offline banner.
        let linkedBefore = fixture.counts[.linkedRows, default: 0]
        scope.wrappedValue = .all
        try await fixture.wait { fixture.frames.last?.1.contains("Reconnecting") == true && fixture.counts[.linkedRows, default: 0] > linkedBefore }
        fixture.push(.agent(target))
        try await fixture.wait { fixture.isFrozen }
        fixture.assertPushCost()
        XCTAssertGreaterThan(fixture.counts[.linkedRows, default: 0], 0)
        let linkedLayout = fixture.counts[.layout, default: 0]
        let rendered = fixture.chatBodies
        fixture.store.apply(.textDelta(target, messageID: "perf-stream", text: " linked", sequence: 101))
        try await fixture.wait { fixture.chatBodies > rendered }
        XCTAssertEqual(fixture.counts[.layout, default: 0], linkedLayout, "The linked snapshot reuses its computed layout")
        XCTAssertEqual(fixture.store.conversation(for: target).lastSequence, 101)
        fixture.hosts[1].connection = .offline
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.turn()
        fixture.frames.removeAll()
        fixture.pop()
        try await fixture.wait { !fixture.frames.isEmpty && !fixture.isFrozen }
        let first = try XCTUnwrap(fixture.frames.first)
        XCTAssertFalse(first.0)
        XCTAssertTrue(first.1.contains("Synthetic Desktop 1 is offline"), "The FIRST pop construction uses current banner inputs")
        let offlineText = try await fixture.waitForRenderedText("offline")
        XCTAssertTrue(offlineText.contains("offline"))
        fixture.capture("Home first returned frame has current connection state")
    }

    func testFrozenMenuActivationRechecksChangedLivePermissionsAndAvailability() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.hosts[0].canEditSettings = true
        fixture.hosts[0].terminal = .init(projectShell: true, agentShell: true, agentAttach: false)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.mount()
        let target = fixture.hosts[0].projects[0].agents[1].id // A real visible row, for settings and Terminal.
        let sleeper = fixture.hosts[0].projects[0].agents[0].id // Open quiet rows are part of the captured display.
        fixture.preferences.toggleFold("quiet:" + (try XCTUnwrap(fixture.group())).entry.orderKey)
        try await fixture.turn()
        fixture.push(.agent(fixture.hosts[2].projects[0].agents[1].id))
        try await fixture.wait { fixture.isFrozen && fixture.frozenSettings != nil && fixture.frozenWake != nil && fixture.frozenTerminal != nil }
        fixture.assertPushCost()
        let settings = try XCTUnwrap(fixture.frozenSettings)
        let wake = try XCTUnwrap(fixture.frozenWake)
        let terminal = try XCTUnwrap(fixture.frozenTerminal)
        XCTAssertTrue(settings.canOpen(target))
        let choice = try XCTUnwrap(wake.choices(sleeper).first)
        XCTAssertTrue(terminal.availability(.agentShell(target)).isAvailable)
        fixture.hosts[0].canEditSettings = false
        fixture.hosts[0].terminal = nil
        fixture.hosts[0].projects[0].agents[0].status = .working
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.turn()
        XCTAssertTrue(settings.canOpen(target), "Frozen DISPLAY remains the snapshot; it cannot authorize a tap")
        XCTAssertTrue(terminal.availability(.agentShell(target)).isAvailable)
        let reads = fixture.service.historyReads
        settings.open(target)
        wake.wake(sleeper, choice)
        terminal.open(.agentShell(target))
        try await fixture.turn()
        XCTAssertEqual(fixture.counts[.activation, default: 0], 0, "None of the three callbacks passes its live activation guard")
        XCTAssertNil(fixture.window.rootViewController?.presentedViewController, "Live guards block settings and Terminal presentation")
        XCTAssertEqual(fixture.service.historyReads, reads, "A rejected Wake callback must not even start a history read")
        // Fake service mutations XCTFail; none of the stale callbacks may issue a command.
        fixture.rowActions.removeAll()
        fixture.pop()
        try await fixture.wait { !fixture.isFrozen && fixture.rowActions[target] != nil }
        let fresh = try XCTUnwrap(fixture.rowActions[target])
        XCTAssertFalse(try XCTUnwrap(fresh.settings).canOpen(target), "Thawed row receives fresh permission closures on its first render")
        XCTAssertFalse(try XCTUnwrap(fresh.terminal).availability(.agentShell(target)).isShown)
        XCTAssertFalse(fixture.isFrozen)
        fixture.capture("Thawed Home uses fresh menu capabilities")
    }

    func testSortScopeAndPinIdleChangesResetOrMoveOnlyTheirIntendedSections() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let target = fixture.hosts[0].projects[0].agents[2].id
        fixture.hosts[0].projects[0].agents[2].lastActivity = Date(timeIntervalSince1970: 1_900_000_000)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.agents.contains { $0.id == target } == true }
        XCTAssertNotEqual(fixture.group()?.agents.first?.id, target, "Recent is initially held")
        fixture.preferences.projectSort = .alphabetical
        try await fixture.wait { fixture.renderedSort == .alphabetical && fixture.group()?.agents.first?.name == "Synthetic agent 1" }
        fixture.preferences.projectSort = .recent
        try await fixture.wait { fixture.group()?.agents.first?.id == target }
        let scope = try XCTUnwrap(fixture.scope)
        scope.wrappedValue = .host("synthetic-host-1")
        try await fixture.wait { fixture.group()?.entry.members.allSatisfy { $0.host.id == "synthetic-host-1" } == true }
        scope.wrappedValue = .all
        try await fixture.wait { fixture.group()?.agents.first?.id == target }
        // Shared Pin/Inactive are structural changes, not recency reshuffles.
        fixture.hosts[0].projectState?["project-9"] = .init(pinned: true)
        fixture.store.apply(.hosts(fixture.hosts))
        let pinned = CompanionProjectTarget(hostID: "synthetic-host-0", projectID: "project-9")
        try await fixture.wait { fixture.projection?.projects.first?.id == pinned }
        XCTAssertTrue(fixture.projection?.projects.first?.isPinned == true)
        for i in fixture.hosts[0].projects[9].agents.indices { fixture.hosts[0].projects[9].agents[i].status = .sleeping }
        fixture.hosts[0].projectState?["project-9"] = .init(inactive: true, idle: true)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.projection?.idle.contains { $0.id == pinned } == true }
        XCTAssertFalse(fixture.projection?.projects.contains { $0.id == pinned } == true)
        XCTAssertEqual(fixture.group()?.agents.first?.id, target, "Unaffected held peers stay ordered across section changes")
    }

    func testInactiveKeepsRecentHoldAndBackgroundStartsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let original = try XCTUnwrap(fixture.group()).agents.map(\.id)
        let phase = try XCTUnwrap(fixture.phase)
        phase.wrappedValue = .inactive
        try await fixture.wait { fixture.observedPhase == .inactive }
        let target = fixture.hosts[0].projects[0].agents[2].id
        fixture.hosts[0].projects[0].agents[2].status = .approval
        fixture.hosts[0].projects[0].agents[2].lastActivity = Date(timeIntervalSince1970: 1_900_000_010)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.liveStatus == .approval }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original, "Control Center/Face ID inactive must not end Recent")
        phase.wrappedValue = .active
        try await fixture.wait { fixture.observedPhase == .active }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original)
        phase.wrappedValue = .background
        try await fixture.wait { fixture.observedPhase == .background }
        phase.wrappedValue = .active
        try await fixture.wait { fixture.observedPhase == .active && fixture.group()?.agents.first?.id == target }
        XCTAssertEqual(fixture.group()?.agents.first?.status, .approval)
    }

    func testRecentOrderStaysWhileVisibleThenRefreshesOnReturn() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let original = try XCTUnwrap(fixture.group()).agents.map(\.id)
        let changed = fixture.hosts[0].projects[0].agents[2].id
        fixture.hosts[0].projects[0].agents[2].status = .approval
        fixture.hosts[0].projects[0].agents[2].lastActivity = Date(timeIntervalSince1970: 1_900_000_001)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.agents.first(where: { $0.id == changed })?.status == .approval }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original)
        XCTAssertEqual(fixture.group()?.liveStatus, .approval)
        let newcomer = CompanionAgent(id: .init(hostID: "synthetic-host-0", projectID: "project-0", agentID: "new-peer"),
            name: "New synthetic peer", subtitle: "Generated task", status: .working, lastActivity: Date(timeIntervalSince1970: 1_900_000_002))
        fixture.hosts[0].projects[0].agents.append(newcomer)
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.agents.contains { $0.id == newcomer.id } == true }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original + [newcomer.id])
        fixture.hosts[0].projects[0].agents.removeAll { $0.id == changed }
        fixture.store.apply(.hosts(fixture.hosts))
        try await fixture.wait { fixture.group()?.agents.contains { $0.id == changed } == false }
        XCTAssertEqual(fixture.group()?.agents.map(\.id), original.filter { $0 != changed } + [newcomer.id])
        fixture.select(.dispatcher)
        try await fixture.wait { fixture.store.selection == fixture.dispatcher }
        fixture.select(.home)
        try await fixture.wait { fixture.group()?.agents.first?.id == newcomer.id }
        XCTAssertEqual(fixture.counts[.layout], fixture.counts[.content])
    }

    func testVisibleHomeDecisionProjectionStaysFreshWithoutFollowingTranscriptChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.dynamicTypeSize = .accessibility1 // Full decision lines must be pixel-visible, not truncated.
        let target = fixture.hosts[0].projects[0].agents[1].id
        fixture.hosts[0].projects[0].agents[1].status = .approval
        fixture.store.apply(.hosts(fixture.hosts))
        var approval = CompanionApproval(id: "home-projection", toolName: "Edit", summary: "Generated pending decision",
            options: [.init(id: "deny", label: "Deny", kind: .rejectOnce)])
        fixture.service.histories[target] = .init(items: [.approval(approval)], lastSequence: 0, sessionID: "pending-session")
        await fixture.store.load(target)
        func assertSeedRetained() {
            XCTAssertTrue(fixture.store.conversation(for: target).isLoaded)
            XCTAssertEqual(fixture.store.conversation(for: target).items, [.approval(approval)])
            XCTAssertEqual(fixture.store.homeDecisionItems[target], [.approval(approval)])
        }
        assertSeedRetained()
        try await fixture.mount()
        let initialText = try await fixture.waitForRenderedText("Edit", excluding: "Needs permission to use")
        XCTAssertTrue(initialText.replacingOccurrences(of: "•", with: "·").contains("Needs permission · Edit"), "Home must show the actual pending approval")
        assertSeedRetained()
        try await fixture.waitForVisibleWorkToSettle()
        let kinds: Set<CompanionHomeBuildProbe.Kind> = [.owner, .contentInputs, .content, .layout, .header]
        let before = fixture.counts.filter { kinds.contains($0.key) }
        XCTAssertGreaterThan(before[.owner, default: 0], 0)
        XCTAssertGreaterThan(before[.layout, default: 0], 0)
        XCTAssertGreaterThan(before[.header, default: 0], 0)
        let headerCount = try XCTUnwrap(fixture.projection).projects.count
        var afterFirstMutation = before
        for batch in 0..<10 {
            for chunk in 0..<10 {
                fixture.store.apply(.textDelta(fixture.dispatcher, messageID: "perf-stream", text: " visible", sequence: batch * 10 + chunk + 1))
            }
            try await fixture.waitForVisibleWorkToSettle()
            XCTAssertTrue(fixture.homeVisible)
            XCTAssertEqual(fixture.navigation?.wrappedValue.tab, .home)
            let current = fixture.counts.filter { kinds.contains($0.key) }
            if batch == 0 {
                // #572: main also retains one initial unheld-Recent observation. The approved
                // contract allows ONE first-mutation pass, never steady per-chunk rebuilding.
                for kind in kinds {
                    let delta = current[kind, default: 0] - before[kind, default: 0]
                    XCTAssertGreaterThanOrEqual(delta, 0)
                    XCTAssertLessThanOrEqual(delta, kind == .header ? headerCount : 1,
                        "#572 permits at most one existing first-mutation pass; pending attention must not add another")
                }
                afterFirstMutation = current
            } else {
                XCTAssertEqual(current, afterFirstMutation,
                    "After the explicitly bounded #572 first mutation, pending attention must not rebuild Home for batch \(batch)")
            }
        }
        XCTAssertEqual(fixture.store.conversation(for: fixture.dispatcher).lastSequence, 100)
        XCTAssertEqual(fixture.store.conversation(for: fixture.dispatcher).items.compactMap { item -> String? in
            if case .message(let value) = item, value.id == "perf-stream" { return value.text }; return nil
        }.first, "start" + String(repeating: " visible", count: 100))

        approval.toolName = "Shell"
        fixture.store.apply(.upsert(target, .approval(approval), sequence: nil))
        let changedText = try await fixture.waitForRenderedText("Shell", excluding: "Needs permission to use")
        XCTAssertTrue(changedText.replacingOccurrences(of: "•", with: "·").contains("Needs permission · Shell"), "Decision metadata must refresh without a host report")
        approval.resolution = .denied
        fixture.store.apply(.upsert(target, .approval(approval), sequence: nil))
        let question = CompanionQuestion(id: "home-question", prompts: [.init(id: "prompt", text: "Generated question",
            options: [], allowsMultiple: false, allowsFreeText: true)])
        fixture.store.apply(.upsert(target, .question(question), sequence: nil))
        XCTAssertEqual(fixture.store.homeAttentionItems().first { $0.agent.id == target }?.kind, .question(question))
        let retainedRowText = try await fixture.waitForRenderedText("Synthetic agent 1", excluding: "Shell")
        XCTAssertTrue(retainedRowText.contains("Synthetic agent 1"), "Resolving an approval must keep the pending question's row")
        XCTAssertFalse(retainedRowText.contains("Shell"), "The resolved approval must not remain rendered")
        // Home's status label follows the desktop report, not the question event alone.
        fixture.hosts[0].projects[0].agents[1].status = .waiting
        fixture.hosts[0].projects[0].agents[1].detail = .init(state: "needs_input", message: "Generated question")
        fixture.store.apply(.hosts(fixture.hosts))
        let questionText = try await fixture.waitForRenderedText("Has a question")
        XCTAssertTrue(questionText.contains("Has a question"))
        XCTAssertTrue(questionText.contains("Generated question"))
        XCTAssertFalse(questionText.contains("Shell"), "The resolved approval must not reappear after the waiting report")
        fixture.hosts[0].projects[0].agents[1].status = .working
        fixture.store.apply(.hosts(fixture.hosts))
        let emptyText = try await fixture.waitForRenderedText("Nothing needs you right now")
        XCTAssertTrue(emptyText.contains("Nothing needs you right now"))
        fixture.capture("Visible Home decisions remain fresh after isolated stream updates")
    }

    @MainActor private final class Fixture {
        let service: HomeVisibilityService
        let store: CompanionStore
        let defaults: UserDefaults
        let suite: String
        let preferences: CompanionPreferences
        let window: UIWindow
        let previous: UIWindow?
        let dispatcher = CompanionTarget(hostID: "synthetic-host-0", projectID: CompanionDispatcher.defaultProjectID, agentID: "synthetic-dispatcher")
        var hosts = CompanionLargeCatalogFixture.hosts(hostCount: 4, projectsPerHost: 24, agentsPerProject: 12)
        var navigation: Binding<CompanionNavigation>?
        var scope: Binding<CompanionDesktopSelection>?
        var renderedSort: CompanionProjectSort?
        var projection: CompanionHomeLayout?
        var counts: [CompanionHomeBuildProbe.Kind: Int] = [:]
        var chatBodies = 0
        var streamTarget: CompanionTarget?
        var isFrozen = false
        var frames: [(Bool, String)] = []
        var frozenSettings: CompanionAgentSettingsAction?
        var frozenWake: CompanionAgentWakeAction?
        var frozenTerminal: CompanionTerminalAction?
        var rowActions: [CompanionTarget: CompanionHomeFrozenActions] = [:]
        var homeVisible = false
        var phase: Binding<ScenePhase>?
        var observedPhase: ScenePhase?
        var dynamicTypeSize: DynamicTypeSize? = nil
        var snapshotAgentCounts: [Int] = []
        var lastPush: (snapshots: Int, content: Int)?
        var expensiveCounts: [CompanionHomeBuildProbe.Kind: Int] { counts.filter { $0.key != .owner } }

        init() throws {
            let service = HomeVisibilityService()
            let suite = "home-visibility-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            self.service = service
            self.suite = suite
            self.defaults = defaults
            store = CompanionStore(service: service)
            preferences = CompanionPreferences(defaults: defaults, systemDeviceName: "Synthetic performance fixture")
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            var dispatcherAgent = CompanionAgent(id: dispatcher, name: "Synthetic Dispatcher", subtitle: "Generated stream", status: .working, capabilities: [.chat, .cancel])
            dispatcherAgent.isDispatcher = true
            hosts[0].dispatcher = .init(enabled: true, flagOn: true, agent: dispatcherAgent)
            store.apply(.hosts(hosts))
        }

        func mount() async throws {
            await store.load(dispatcher)
            CompanionHomeBuildProbe.renderedSort = { [weak self] in self?.renderedSort = $0 }
            CompanionHomeBuildProbe.phase = { [weak self] in self?.observedPhase = $0 }
            CompanionHomeBuildProbe.snapshotAgents = { [weak self] in self?.snapshotAgentCounts.append($0) }
            CompanionHomeBuildProbe.visibility = { [weak self] in self?.homeVisible = $0 }
            CompanionHomeBuildProbe.record = { [weak self] in self?.counts[$0, default: 0] += 1 }
            CompanionHomeBuildProbe.projection = { [weak self] in self?.projection = $0 }
            CompanionHomeBuildProbe.navigation = { [weak self] in self?.navigation = $0 }
            CompanionHomeBuildProbe.rowActions = { [weak self] target, settings, wake, terminal in
                self?.rowActions[target] = .init(settings: settings, wake: wake, terminal: terminal)
            }
            CompanionHomeBuildProbe.frozen = { [weak self] in self?.isFrozen = $0 }
            CompanionHomeBuildProbe.frame = { [weak self] in self?.frames.append(($0, $1)) }
            CompanionHomeBuildProbe.frozenActions = { [weak self] settings, wake, terminal in
                self?.frozenSettings = settings; self?.frozenWake = wake; self?.frozenTerminal = terminal
            }
            CompanionHomeBuildProbe.state = { [weak self] in self?.scope = $0 }
            CompanionConversationBuildProbe.record = { [weak self] kind, target in
                guard case .body = kind, target == (self?.streamTarget ?? self?.dispatcher) else { return }
                self?.chatBodies += 1
            }
            let root = CompanionRootView(store: store, preferences: preferences, onPair: {}, onSettings: {})
            if let dynamicTypeSize {
                window.rootViewController = UIHostingController(rootView: HomeVisibilitySceneHost(root: root) { [weak self] in self?.phase = $0 }
                    .companionTheme(.clubhouse).environment(\.dynamicTypeSize, dynamicTypeSize))
            } else {
                window.rootViewController = UIHostingController(rootView: HomeVisibilitySceneHost(root: root) { [weak self] in self?.phase = $0 }
                    .companionTheme(.clubhouse))
            }
            window.makeKeyAndVisible()
            try await wait { self.navigation != nil && self.scope != nil && self.phase != nil && self.counts[.header, default: 0] > 0 && self.counts[.quiet, default: 0] > 0 }
            try await turn()
        }

        func group() -> CompanionProjectGroup? { projection?.projects.first { $0.entry.linkID == "synthetic-link-0" } }

        func push(_ route: CompanionRoute) {
            lastPush = (counts[.snapshot, default: 0], counts[.content, default: 0])
            guard let navigation else { XCTFail("Root navigation must be mounted"); return }
            var next = navigation.wrappedValue
            next.setPath([route], for: .home, hosts: store.hosts)
            navigation.wrappedValue = next
        }

        /// A bounded setup condition, never an action retry or a stream-counter allowance.
        /// Native navigation completion plus TWO equal row/menu samples >=250ms apart.
        func waitForPushedRealisation(file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var sampled: [CompanionHomeBuildProbe.Kind: Int]?
            var sampledAt: TimeInterval = 0
            var evidence: [String] = []
            defer {
                let attachment = XCTAttachment(string: evidence.joined(separator: "\n"))
                attachment.name = "Home push transition and List realisation readiness"
                attachment.lifetime = .keepAlways
                XCTContext.runActivity(named: attachment.name ?? "Home render evidence") { $0.add(attachment) }
            }
            func isTransitioning(_ controller: UIViewController) -> Bool {
                controller.transitionCoordinator != nil || controller.isBeingPresented || controller.isBeingDismissed
                    || controller.children.contains(where: isTransitioning)
                    || controller.presentedViewController.map(isTransitioning) == true
            }
            while ProcessInfo.processInfo.systemUptime < deadline {
                try await turn()
                let now = ProcessInfo.processInfo.systemUptime
                let transitioning = window.rootViewController.map(isTransitioning) ?? true
                if !isFrozen || transitioning {
                    sampled = nil
                } else if sampled == nil || now - sampledAt >= 0.25 {
                    let current: [CompanionHomeBuildProbe.Kind: Int] = [.row: counts[.row, default: 0], .rowMenu: counts[.rowMenu, default: 0]]
                    evidence.append("time=\(now) transitionComplete=\(!transitioning) row=\(current[.row, default: 0]) rowMenu=\(current[.rowMenu, default: 0]) interval=\(sampled == nil ? 0 : now - sampledAt)")
                    if let sampled, current == sampled { return }
                    sampled = current; sampledAt = now
                }
                try await Task.sleep(for: .milliseconds(20)) // Condition polling only.
            }
            XCTFail("Native push and List realisation did not settle within 5s", file: file, line: line)
            throw NSError(domain: "HomeListReadiness", code: 1)
        }

        /// Value-only evidence, sampled outside rendering; never observes Store in a body callback.
        func attachStreamingCounters(_ phase: String, before: [CompanionHomeBuildProbe.Kind: Int], ownerBefore: Int) {
            let after = expensiveCounts
            let rows = Set(before.keys).union(after.keys).map { kind in
                "\(kind): \(before[kind, default: 0]) -> \(after[kind, default: 0])"
            }.sorted()
            let text = (["owner: \(ownerBefore) -> \(counts[.owner, default: 0])"] + rows).joined(separator: "\n")
            let attachment = XCTAttachment(string: text)
            attachment.name = "Home counters: " + phase
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: attachment.name ?? "Home render evidence") { $0.add(attachment) }
        }

        func assertPushCost(file: StaticString = #filePath, line: UInt = #line) {
            guard let lastPush else { XCTFail("A real push must precede its budget check", file: file, line: line); return }
            XCTAssertEqual(counts[.snapshot, default: 0] - lastPush.snapshots, 1, "Exactly one display snapshot per push", file: file, line: line)
            let constructions = counts[.content, default: 0] - lastPush.content
            XCTAssertGreaterThan(constructions, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(constructions, 2, "At most live transition + frozen construction", file: file, line: line)
            if let amount = snapshotAgentCounts.last {
                XCTAssertLessThan(amount, hosts.flatMap(\.allAgents).count, "Predicate work is scoped to displayed rows/open folds, not the full catalog", file: file, line: line)
            } else { XCTFail("Snapshot predicate count must be recorded", file: file, line: line) }
        }

        func pop() {
            guard let navigation else { XCTFail("Root navigation must be mounted"); return }
            var next = navigation.wrappedValue
            next.setPath([], for: .home, hosts: store.hosts)
            navigation.wrappedValue = next
        }

        func select(_ tab: CompanionTab) {
            guard let navigation else { XCTFail("Root navigation must be mounted"); return }
            var next = navigation.wrappedValue
            _ = next.selectFromTabBar(tab)
            navigation.wrappedValue = next
        }

        func turn() async throws {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.layoutIfNeeded()
        }

        /// Bounded rendering readiness, never a stream retry or a work allowance.
        func waitForVisibleWorkToSettle() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var sample = counts, sampledAt = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime < deadline {
                try await turn()
                let now = ProcessInfo.processInfo.systemUptime
                if counts != sample { sample = counts; sampledAt = now }
                else if now - sampledAt >= 0.15 { return }
                try await Task.sleep(for: .milliseconds(20)) // Condition polling only.
            }
            XCTFail("Visible Home did not settle between measured batches")
            throw NSError(domain: "HomeVisibleReadiness", code: 1)
        }

        func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline {
                try await turn()
                try await Task.sleep(for: .milliseconds(20)) // Condition polling, never an action retry.
            }
            XCTAssertTrue(condition(), "Mounted rendering condition did not arrive", file: file, line: line)
        }

        func list(in view: UIView) -> UICollectionView? {
            (view as? UICollectionView) ?? view.subviews.lazy.compactMap { self.list(in: $0) }.first
        }

        func waitForRenderedText(_ expected: String, excluding excluded: String? = nil) async throws -> String {
            let deadline = Date().addingTimeInterval(5)
            var text = ""
            var lastImage: UIImage?
            repeat {
                (text, lastImage) = try renderedFrame()
                if text.contains(expected), excluded.map({ !text.contains($0) }) ?? true { break }
                try await turn()
                try await Task.sleep(for: .milliseconds(20)) // Pixel readiness only; never repeats an action.
            } while Date() < deadline
            let attachment = XCTAttachment(string: "Expected: \(expected)\nExcluded: \(excluded ?? "none")\nRecognized: \(text)")
            attachment.name = "Home bounded OCR readiness"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Home bounded OCR readiness") { activity in
                activity.add(attachment)
                if let lastImage {
                    let pixels = XCTAttachment(image: lastImage)
                    pixels.name = "Exact pixels used for Home OCR readiness"
                    pixels.lifetime = .keepAlways
                    activity.add(pixels)
                }
            }
            return text
        }

        func renderedText() throws -> String { try renderedFrame().0 }

        private func renderedFrame() throws -> (String, UIImage) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
            return (text, image)
        }

        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: name) { $0.add(attachment) }
        }

        func close() {
            CompanionHomeBuildProbe.renderedSort = nil
            CompanionHomeBuildProbe.phase = nil; CompanionHomeBuildProbe.snapshotAgents = nil; phase = nil
            CompanionHomeBuildProbe.visibility = nil
            CompanionHomeBuildProbe.record = nil; CompanionHomeBuildProbe.projection = nil
            CompanionHomeBuildProbe.rowActions = nil; rowActions.removeAll()
            CompanionHomeBuildProbe.frozen = nil; CompanionHomeBuildProbe.frame = nil; CompanionHomeBuildProbe.frozenActions = nil
            frozenSettings = nil; frozenWake = nil; frozenTerminal = nil
            CompanionHomeBuildProbe.navigation = nil; CompanionHomeBuildProbe.state = nil
            CompanionConversationBuildProbe.record = nil
            navigation = nil; scope = nil; projection = nil
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
    }
}

/// Test-owned lifecycle input; the real Root, Store and Home remain mounted across phase transitions.
@MainActor private struct HomeVisibilitySceneHost: View {
    let root: CompanionRootView
    let onPhase: (Binding<ScenePhase>) -> Void
    @State private var phase: ScenePhase = .active

    init(root: CompanionRootView, onPhase: @escaping (Binding<ScenePhase>) -> Void) {
        self.root = root; self.onPhase = onPhase
    }

    var body: some View {
        root.environment(\.scenePhase, phase).onAppear { onPhase($phase) }
    }
}

@MainActor private final class HomeVisibilityService: CompanionService {
    var historyReads = 0
    var histories: [CompanionTarget: CompanionHistory] = [:]
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory {
        historyReads += 1
        if let history = histories[target] { return history }
        return .init(items: [.message(.init(id: "perf-stream", role: .assistant, text: "start", timestamp: Date(timeIntervalSince1970: 1_800_000_000), isStreaming: true))],
              lastSequence: 0, sessionID: "synthetic-session")
    }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { XCTFail("No sends in performance tests"); return .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws { XCTFail("No cancel in performance tests") }
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws { XCTFail("No decisions in performance tests") }
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { XCTFail("No spawn in performance tests"); return .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
}
