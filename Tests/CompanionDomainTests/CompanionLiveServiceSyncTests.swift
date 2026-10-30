import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Connection state, catalog events and reads through `CompanionLiveService` against a scripted desktop.
@Suite @MainActor struct CompanionLiveServiceSyncTests {
    private typealias Harness = LiveServiceHarness

    @MainActor private final class Calls { var hosts: [String] = []; var routes: [AnnexCapabilities.Routes] = [] }

    // MARK: Connection

    @Test func aConnectRefusedOnRegisterOrReconnectMarksTheHostFailed() async throws {
        let harness = try await Harness.start(waitForConnection: false) { await $0.failNextConnect(.unauthorized) }
        defer { harness.stop() }
        try await harness.waitUntil { harness.host?.connection == .failed("Pair this desktop again to restore access.") }

        await harness.service.reconnect(hostID: Harness.hostID)
        try await harness.waitUntil { harness.host?.connection == .connected }
        await harness.transport.failNextConnect(.forbidden)
        await harness.service.reconnect(hostID: Harness.hostID)
        try await harness.waitUntil { harness.host?.connection == .failed("This desktop has not granted mobile control. Pair again using the secure invitation.") }
        #expect(await harness.transport.connectCount == 3)
    }

    @Test func reconnectingAndFailedTransportStatesAreShownAndReportedUnreachable() async throws {
        let calls = Calls()
        let harness = try await Harness.start(configure: { transport in
            await transport.setCapability("routes", .object(["hosts": .array([.string("10.0.0.2")]), "port": .integer(8443)]))
        }, prepare: { service in
            service.onUnreachable = { calls.hosts.append($0) }
            service.onRoutes = { _, routes in calls.routes.append(routes) }
        })
        defer { harness.stop() }
        #expect(calls.routes.first == .init(hosts: ["10.0.0.2"], port: 8443))

        await harness.transport.emit(.connection(.reconnecting(attempt: 1, delaySeconds: 0.5)))
        try await harness.waitUntil { harness.host?.connection == .reconnecting }
        await harness.transport.emit(.connection(.failed(.disconnected)))
        try await harness.waitUntil { harness.host?.connection == .failed("The desktop is offline. Reconnect to continue.") }
        #expect(calls.hosts == [Harness.hostID, Harness.hostID])

        // An ordinary disconnect is not a reason to look for the desktop elsewhere.
        await harness.transport.emit(.connection(.suspended))
        try await harness.waitUntil { harness.host?.connection == .offline }
        #expect(calls.hosts.count == 2)
    }

    @Test(arguments: [AnnexTransportError?]([nil, .queueOverflow]))
    func anEndedEventStreamFailsTheHostUntilReconnected(error: AnnexTransportError?) async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        await harness.transport.finishEvents(throwing: error)
        let expected = error == nil ? "The desktop is offline. Reconnect to continue." : CompanionLiveService.readableError(AnnexTransportError.queueOverflow)
        try await harness.waitUntil { harness.host?.connection == .failed(expected) }
        await harness.service.reconnect(hostID: Harness.hostID)
        try await harness.waitUntil { harness.host?.connection == .connected }
        #expect(await harness.transport.subscriptionCount == 2)
    }

    @Test func aFailedCatalogReadMarksTheHostFailed() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        await harness.transport.failProjects(.rejected(status: 500, code: nil))
        await harness.transport.emit(.resyncRequired(.serverRestart))
        try await harness.waitUntil { harness.host?.connection == .failed("Desktop request failed (500).") }
        await harness.transport.failProjects(nil)
        try await harness.refreshCatalog()
    }

    @Test func resumeReconnectsHostsNotAlreadyMovedToABetterRoute() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        await harness.service.suspend()
        try await harness.waitUntil { harness.host?.connection == .offline }

        // The resume hook already reconnected this host on another route: it is left alone.
        harness.service.prepareResume = { [Harness.hostID] }
        await harness.service.resume()
        #expect(await harness.transport.subscriptionCount == 1)
        #expect(harness.host?.connection == .offline)

        harness.service.prepareResume = nil
        await harness.service.suspend()
        await harness.service.resume()
        try await harness.waitUntil { harness.host?.connection == .connected }
        #expect(await harness.transport.subscriptionCount == 2)
    }

    // MARK: Catalog events

    @Test func themeChangesApplyFromTheSnapshotAndLater() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        #expect(harness.host?.theme == nil)
        let colors: AnnexJSON = .object(["base": .string("#101010"), "text": .string("#fafafa"), "accent": .string("#7c3aed"),
                                         "terminalColors": .object(["background": .string("#000000")])])
        await harness.transport.emit(.message(.init(type: "theme:changed", payload: colors)))
        try await harness.waitUntil { harness.host?.theme != nil }
        #expect(harness.host?.theme == CompanionLiveService.theme(from: colors, terminal: colors["terminalColors"]))

        // A payload that isn't a color set leaves the theme as it was.
        await harness.transport.emit(.message(.init(type: "theme:changed", payload: .string("dark"))))
        await harness.transport.emit(.message(.init(type: "theme:changed", payload: nil)))
        await harness.transport.emit(.connection(.connecting))
        try await harness.waitUntil { harness.host?.connection == .connecting }
        #expect(harness.host?.theme == CompanionLiveService.theme(from: colors, terminal: colors["terminalColors"]))
    }

    @Test func iconsFromTheSnapshotSurviveCatalogRefreshes() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        await harness.transport.emit(harness.snapshotEvent([
            "projectIcons": .object(["project": .string("data:image/png;base64,AAAA")]),
            "agentIcons": .object(["agent": .string("data:image/png;base64,AQID")]),
        ]))
        try await harness.waitUntil { harness.host?.projects.first?.iconData != nil }
        #expect(harness.host?.projects.first?.iconData == Data([0, 0, 0]))
        #expect(harness.host?.projects.first?.agents.first?.iconData == Data([1, 2, 3]))

        // The REST catalog has no icons; the snapshot's are kept.
        try await harness.refreshCatalog()
        #expect(harness.host?.projects.first?.iconData == Data([0, 0, 0]))
        #expect(harness.host?.projects.first?.agents.first?.iconData == Data([1, 2, 3]))
    }

    @Test func providersComeFromTheSnapshotsOrchestrators() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        await harness.transport.emit(harness.snapshotEvent(["orchestrators": .object([
            "zed": .object(["displayName": .string("Zed CLI")]),
            "alpha": .object(["shortName": .string("Alpha")]),
            "codex": .object([:]),
        ])]))
        try await harness.waitUntil { harness.host?.providers.isEmpty == false }
        #expect(harness.host?.providers.map(\.id) == ["alpha", "codex", "zed"])
        #expect(harness.host?.providers.map(\.name) == ["Alpha", "codex", "Zed CLI"])
    }

    @Test func aQuickAgentSpawnedOnTheDesktopIsListed() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        // Only quick agents are remembered between snapshots; a durable spawn waits for the catalog.
        await harness.transport.emit(.message(.init(type: "agent:spawned", payload: .object([
            "id": .string("durable-2"), "kind": .string("durable"), "projectId": .string("project")]))))
        await harness.transport.emit(.message(.init(type: "agent:spawned", payload: .object([
            "id": .string("q5"), "kind": .string("quick"), "projectId": .string("project"), "name": .string("swift-heron"),
            "status": .string("running"), "prompt": .string("Write the docs")]))))
        try await harness.waitUntil { harness.host?.projects.first?.agents.contains { $0.id.agentID == "q5" } == true }
        let agents = try #require(harness.host?.projects.first?.agents)
        #expect(!agents.contains { $0.id.agentID == "durable-2" })
        let quick = try #require(agents.first { $0.id.agentID == "q5" })
        #expect(quick.isQuick && quick.status == .working && quick.subtitle == "Write the docs")

        // Spawned again (the desktop re-announces it): one entry, the latest.
        await harness.transport.emit(.message(.init(type: "agent:spawned", payload: .object([
            "id": .string("q5"), "kind": .string("quick"), "projectId": .string("project"), "name": .string("swift-heron"),
            "status": .string("completed"), "prompt": .string("Write the docs")]))))
        try await harness.waitUntil { harness.host?.projects.first?.agents.first { $0.id.agentID == "q5" }?.hasExited == true }
        #expect(harness.host?.projects.first?.agents.filter { $0.id.agentID == "q5" }.count == 1)
    }

    @Test func pendingRequestsOlderThanTheLastEventStillShow() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        let later = Harness.chatEvent("s1", sequence: 5, type: "agent_message", data: ["messageId": .string("later"), "text": .string("Later")])
        let permission = Harness.chatEvent("s1", sequence: 3, type: "permission_request", data: [
            "requestId": .string("perm-1"), "toolName": .string("Bash"), "rawInput": .object(["command": .string("ls")]),
            "options": .array([.object(["optionId": .string("allow"), "label": .string("Allow"), "kind": .string("allow_once")])])])
        let controls: AnnexJSON = .object(["model": .string("opus")])
        let snapshot = Harness.chatSnapshot(events: [later], fields: ["state": .string("waiting_permission"),
                                                                     "pendingPermissions": .array([permission]), "chatControls": controls])
        try await harness.loadSession(snapshot)
        // The same session again: the desktop's controls replace the phone's fold.
        let history = try await harness.service.history(for: harness.target)
        let approval = history.items.compactMap { item -> CompanionApproval? in if case .approval(let a) = item { a } else { nil } }.first
        #expect(approval?.id == "perm-1")
        #expect(approval?.detail == "$ ls")
        #expect(harness.host?.projects.first?.agents.first?.status == .approval)
    }

    // MARK: Archive

    @Test func pastSessionsAreListedNewestFirst() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        await harness.transport.setRead("chatSessions", .object(["sessions": .array([
            .object(["sessionId": .string("old"), "title": .string("Old"), "lastActiveAt": .integer(1_700_000_000_000)]),
            .object(["title": .string("No id")]),
            .object(["sessionId": .string("undated")]),
            .object(["sessionId": .string("new"), "title": .string("New"), "lastActiveAt": .integer(1_800_000_000_000), "provider": .string("codex")]),
        ])]))
        let sessions = try await harness.service.sessions(for: harness.target)
        #expect(sessions.map(\.id) == ["new", "old", "undated"])
        #expect(sessions.first?.provider == "codex" && sessions.last?.title == "Conversation")
        #expect(sessions.first?.lastActiveAt == Date(timeIntervalSince1970: 1_800_000_000))

        await harness.transport.setRead("chatHistory", .object(["sessionId": .string("old"), "events": .array([
            Harness.chatEvent("old", sequence: 1, type: "agent_message", data: ["messageId": .string("m"), "text": .string("Archived")])])]))
        let page = try await harness.service.archive(for: harness.target, sessionID: "old").load(before: nil)
        #expect(page.items.map(\.id) == ["message:m"])
        #expect(await harness.transport.readRoutes.last?.sessionID == "old")

        // Failures reach the archive as phone wording, never as a raw transport error.
        let failures: [(AnnexTransportError, String)] = [
            (.disconnected, "The desktop is offline. Reconnect to continue."),
            (.rejected(status: 404, code: "agent_not_found"), "This agent is no longer on the desktop."),
            (.rejected(status: 500, code: "chat_sessions_failed"), "The desktop couldn't read this agent's past conversations. Try again later."),
        ]
        for (failure, text) in failures {
            await harness.transport.failRead("chatSessions", failure)
            #expect(await serviceErrorKind { _ = try await harness.service.sessions(for: harness.target) } == .unavailable)
            #expect(await serviceErrorText { _ = try await harness.service.sessions(for: harness.target) } == text)
        }
        let unpaired = CompanionTarget(hostID: "other", projectID: "project", agentID: "agent")
        #expect(throws: CompanionServiceError.self) { _ = try harness.service.archive(for: unpaired, sessionID: "old") }
    }

    // MARK: Rich content

    private static let mediaRef = String(repeating: "ab", count: 32) + ".png"

    private func richContentHarness() async throws -> Harness {
        try await Harness.start { await $0.setCapability("richContent", .object(["enabled": .bool(true)])) }
    }

    @Test func previewsAreRefusedWhileRichContentIsOff() async throws {
        let harness = try await Harness.start()
        defer { harness.stop() }
        #expect(await serviceErrorText { _ = try await harness.service.content(.file("README.md"), target: harness.target) }
                == "Rich chat content is off on Fixture. Turn it on in the desktop's Experimental settings to preview images and files.")
        #expect(await !harness.transport.readRoutes.contains { $0.name == "chatContent" })
    }

    @Test func imagesAndFilesArePreviewedFromTheirRoutes() async throws {
        let harness = try await richContentHarness()
        defer { harness.stop() }
        #expect(harness.host?.richContentAvailable == true)
        await harness.transport.setRead("chatContent", .object(["kind": .string("image"), "name": .string("shot.png"), "mimeType": .string("image/png"),
                                                                 "base64": .string(Data([9, 8, 7]).base64EncodedString())]))
        let image = try await harness.service.content(.image(Self.mediaRef), target: harness.target)
        #expect(image.kind == "image" && image.bytes == Data([9, 8, 7]) && image.mimeType == "image/png")

        await harness.transport.setRead("chatContent", .object(["kind": .string("text"), "name": .string("README.md"), "text": .string("# Hi"),
                                                                 "truncated": .bool(true)]))
        let file = try await harness.service.content(.file("README.md"), target: harness.target)
        #expect(file.text == "# Hi" && file.truncated && file.bytes == nil && !file.tooLarge)
        let routes = await harness.transport.readRoutes.filter { $0.name == "chatContent" }
        #expect(routes.map(\.mediaRef) == [Self.mediaRef, nil])
        #expect(routes.map(\.filePath) == [nil, "README.md"])
    }

    @Test func referencesThatCantBeFetchedNeverReachTheDesktop() async throws {
        let harness = try await richContentHarness()
        defer { harness.stop() }
        for reference in [CompanionContentReference.image("../../etc/passwd"), .image("abc.png"), .localImage("local-1")] {
            #expect(await serviceErrorKind { _ = try await harness.service.content(reference, target: harness.target) } == .unavailable)
            // Read like the desktop's own 404 content_unavailable, never as an address problem.
            #expect(await serviceErrorText { _ = try await harness.service.content(reference, target: harness.target) }
                    == "This image is no longer available on Fixture.")
        }
        #expect(await !harness.transport.readRoutes.contains { $0.name == "chatContent" })
    }

    @Test func unreadableOrOversizedPreviewsSayWhy() async throws {
        let harness = try await richContentHarness()
        defer { harness.stop() }
        let unreadable = "Fixture sent a preview this phone can't read. Updating the desktop may help."
        func preview(_ value: AnnexJSON) async -> String? {
            await harness.transport.setRead("chatContent", value)
            return await serviceErrorText { _ = try await harness.service.content(.file("a.bin"), target: harness.target) }
        }
        #expect(await preview(.object(["kind": .string("hologram"), "name": .string("a.bin")])) == unreadable)
        #expect(await preview(.object(["kind": .string("other")])) == unreadable)
        #expect(await preview(.object(["kind": .string("other"), "name": .string("a.bin"), "base64": .string("not base64!")])) == unreadable)
        #expect(await preview(.object(["kind": .string("other"), "name": .string("a.bin"),
                                       "base64": .string(String(repeating: "A", count: 12 * 1024 * 1024 + 4))]))
                == "This file is too large to preview on your phone. Open it on Fixture.")
        // Within the encoded limit but over 8 MB once decoded.
        let decodedTooLarge = Data(count: 8 * 1024 * 1024 + 3).base64EncodedString()
        #expect(await preview(.object(["kind": .string("other"), "name": .string("a.bin"), "base64": .string(decodedTooLarge)])) == unreadable)
        // The desktop's own "too large" flag is a preview, not an error.
        await harness.transport.setRead("chatContent", .object(["kind": .string("video"), "name": .string("a.mov"), "tooLarge": .bool(true)]))
        let flagged = try await harness.service.content(.file("a.mov"), target: harness.target)
        #expect(flagged.tooLarge && flagged.bytes == nil)
    }

    @Test func refusedPreviewsNameTheLikelyReason() async throws {
        let harness = try await richContentHarness()
        defer { harness.stop() }
        func refused(_ error: AnnexTransportError, _ reference: CompanionContentReference) async -> String? {
            await harness.transport.failRead("chatContent", error)
            return await serviceErrorText { _ = try await harness.service.content(reference, target: harness.target) }
        }
        #expect(await refused(.rejected(status: 404, code: "agent_not_found"), .file("a.txt")) == "This agent is no longer on Fixture.")
        #expect(await refused(.rejected(status: 404, code: "not_found"), .image(Self.mediaRef)) == "This image is no longer available on Fixture.")
        #expect(await refused(.rejected(status: 404, code: nil), .file("a.txt"))
                == "Fixture couldn't share this file. It may have moved, or be outside the agent's folders.")
        #expect(await refused(.responseTooLarge, .file("a.txt")) == "This file is too large to preview on your phone. Open it on Fixture.")
        #expect(await refused(.rateLimited(code: nil, retryAfterSeconds: 3), .file("a.txt")) == "The desktop is busy. Try again in a moment.")
    }
}
