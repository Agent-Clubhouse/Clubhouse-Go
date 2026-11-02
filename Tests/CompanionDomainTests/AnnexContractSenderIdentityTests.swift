import Foundation
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

/// Desktop-generated sender cases through snapshot decoding, chat projection and identity resolution.
/// The fixture's image bytes are a transport stub. Substitute a valid raster in memory
/// so image precedence still exercises the store, without changing the desktop fixture.
@MainActor struct AnnexContractSenderIdentityTests {
    @Test func initialsAndPaletteMatchTheDesktopFixture() throws {
        let fixture = try ContractFixtures.json("sender-identity.json")
        let initials = fixture["initials"].arrayValue
        let colors = fixture["colors"].arrayValue
        #expect(!initials.isEmpty && !colors.isEmpty)
        for row in initials {
            let name = try #require(row["name"]?.string)
            #expect(CompanionAgentFace.initials(name) == row["initials"]?.string, "\(name)")
        }
        for row in colors {
            #expect(CompanionIdentityColor.agentRGB(row["id"]?.string).hex == row["hex"]?.string)
        }
    }

    @Test func initialsContrastAndFoxRowRenderingMatchTheDesktopFixture() throws {
        let fixture = try ContractFixtures.json("sender-identity.json")
        let colors = fixture["colors"].arrayValue
        #expect(colors.count == 8)
        for row in colors {
            let color = CompanionIdentityColor.agentRGB(try #require(row["id"]?.string))
            let text = color.contrast(with: .white) >= color.contrast(with: .black) ? CompanionRGB.white : .black
            #expect(text.hex == row["initialsText"]?.string, "Initials on \(row["id"]?.string ?? "") match the desktop's contrast choice")
        }
        let expected = try #require(fixture["expected"].arrayValue.first { $0["messageId"]?.string == "emoji_over_image" })
        let part = try #require(expected["parts"].arrayValue.first)
        let id = try #require(part["agentId"]?.string)
        let raw = try #require(fixture["catalog"]?["agents"]?["proj_app"].arrayValue.first { $0["id"]?.string == id })
        var agent = CompanionAgent(id: .init(hostID: "fixture", projectID: "proj_app", agentID: id),
                                   name: try #require(raw["name"]?.string), subtitle: "", status: .idle)
        #expect(fixture["catalog"]?["agentIcons"]?[id]?.string != nil)
        let bytes = try #require(CompanionIdentityColor.data(fromDataURL: Self.validIconURL))
        let icon = CompanionIconReference.inline(host: "fixture", kind: .agent, id: id, data: bytes)
        CompanionLiveService.applyIdentity(raw, icon: icon, to: &agent)
        #expect(agent.emoji == "🦊" && agent.icon == icon, "The fox wins even with an image present")
        let frame = try #require(fixture["frames"].arrayValue.first { $0["payload"]?["event"]?["data"]?["messageId"]?.string == expected["messageId"]?.string })
        var projector = CompanionChatProjector()
        projector.apply(try #require(frame["payload"]?["event"]))
        guard case .message(let message)? = projector.items.first,
              case .others(let renderedParts) = message.display else { Issue.record("Missing fox sender row"); return }
        #expect(renderedParts.count == 1)
        try assertPart(#require(renderedParts.first), expected: part, message: message, resolver: .init(agents: [agent]))
    }

    @Test func senderFacesMatchTheDesktopFixture() async throws {
        let fixture = try ContractFixtures.json("sender-identity.json")
        let harness = try await LiveServiceHarness.start(configure: { transport in
            await transport.setFeature("dispatcher", .object([
                "version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true), "projectId": .string("__dispatcher__")
            ]))
        })
        defer { harness.stop() }
        guard case .object(var catalog)? = fixture["catalog"],
              case .object(let durable)? = catalog["agents"], case .object(let quick)? = catalog["quickAgents"] else {
            Issue.record("Missing sender fixture catalog"); return
        }
        // The identity fixture omits project presentation; build project rows for every catalog key.
        let projectIDs = Set(durable.keys).union(quick.keys)
        catalog["projects"] = .array(projectIDs.sorted().map { .object(["id": .string($0), "name": .string($0)]) })
        var count = 1 // The Dispatcher is outside the per-project maps.
        for case .array(let rows) in durable.values { count += rows.count }
        for case .array(let rows) in quick.values { count += rows.count }
        if case .object(let icons)? = catalog["agentIcons"] {
            catalog["agentIcons"] = .object(icons.mapValues { _ in .string(Self.validIconURL) })
        }
        await harness.transport.emit(harness.snapshotEvent(catalog))
        try await harness.waitUntil { harness.host?.allAgents.count == count }
        let agents = try #require(harness.host?.allAgents)
        #expect(agents.contains(where: \.isQuick) && agents.contains(where: \.isDispatcher))
        let resolver = CompanionSenderResolver(agents: agents)

        var projector = CompanionChatProjector()
        var eventsByMessageID: [String: AnnexJSON] = [:]
        let frames = fixture["frames"].arrayValue
        #expect(!frames.isEmpty)
        for frame in frames {
            let envelope = try frame.decode(AnnexEnvelope.self)
            let event = try #require(envelope.payload?["event"])
            let id = try #require(event["data"]?["messageId"]?.string)
            eventsByMessageID[id] = event
            projector.apply(event)
        }
        let messages = projector.items.compactMap { item -> CompanionMessage? in
            if case .message(let message) = item { message } else { nil }
        }
        let expected = fixture["expected"].arrayValue
        #expect(expected.count == frames.count && !expected.isEmpty)
        // `expected` describes each event's identity contribution, not final transcript rows.
        // The queued-message contract puts a join under queuedWith and appends its parts in order:
        // queue_first + queue_joined become one queue_first row, with both sender/avatar specs.
        var expectedRows: [String: [AnnexJSON]] = [:]
        for row in expected {
            let eventID = try #require(row["messageId"]?.string)
            let event = try #require(eventsByMessageID[eventID])
            let rowID: String
            if let queuedWith = row["queuedWith"]?.string {
                #expect(event["data"]?["delivery"]?.string == "queued", "\(eventID)")
                #expect(event["data"]?["queuedWith"]?.string == queuedWith, "\(eventID)")
                rowID = queuedWith
            } else {
                rowID = eventID
            }
            expectedRows[rowID, default: []].append(row)
        }
        #expect(messages.count == expectedRows.count)
        for (id, contributions) in expectedRows {
            let message = try #require(messages.first { $0.id == id })
            switch message.display {
            case .you(let text):
                let row = try #require(contributions.first)
                #expect(contributions.count == 1 && row["from"]?.string == "you" && text == row["text"]?.string, "\(id)")
            case .others(let parts):
                let expectedParts = contributions.flatMap { $0["parts"].arrayValue }
                #expect(contributions.allSatisfy { $0["from"]?.string == "others" }, "\(id)")
                #expect(parts.count == expectedParts.count, "\(id)")
                for (part, expectedPart) in zip(parts, expectedParts) {
                    try assertPart(part, expected: expectedPart, message: message, resolver: resolver)
                }
            }
        }
    }

    private static let validIconURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    private func assertPart(_ part: CompanionRoutedMessagePart, expected: AnnexJSON, message: CompanionMessage,
                            resolver: CompanionSenderResolver) throws {
        let current = resolver.resolve(part.sender)
        #expect(current?.id == expected["agentId"]?.string, "\(message.id)")
        let name = current?.name ?? part.sender?.name
            ?? (part.fromClubhouse ? "Clubhouse" : message.source == "group_project" ? "Group project" : "Another agent")
        #expect(name == expected["name"]?.string && part.text == expected["text"]?.string, "\(message.id)")
        let avatar = resolver.avatarIdentity(for: part.sender)
        guard let type = expected["avatar"]?["type"]?.string else {
            #expect(avatar == nil, "\(message.id)"); return
        }
        let identity = try #require(avatar)
        let spec = try #require(expected["avatar"])
        switch type {
        case "quick":
            #expect(identity.face == .quick, "\(message.id)")
        case "image":
            #expect(identity.face == .icon, "\(message.id)")
            #expect(identity.icon?.version == CompanionIdentityColor.data(fromDataURL: Self.validIconURL).map(CompanionIconReference.digest), "\(message.id)")
        case "emoji":
            #expect(identity.face == .emoji(try #require(spec["emoji"]?.string)), "\(message.id)")
            #expect(CompanionIdentityColor.agentRGB(identity.color).hex + "20" == spec["background"]?.string, "\(message.id)")
        case "initials":
            #expect(identity.face == .initials(try #require(spec["initials"]?.string)), "\(message.id)")
            #expect(CompanionIdentityColor.agentRGB(identity.color).hex == spec["background"]?.string, "\(message.id)")
        default:
            Issue.record("Unknown avatar type: \(type)")
        }
    }
}
