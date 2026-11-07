import Foundation
import Testing
@testable import CompanionDomain

/// Agent parity plan: desktop initials (preserving whole emoji), face precedence,
/// default colour, quick identity, and snapshot updates. Project identity stays unchanged.
struct CompanionAgentFaceTests {
    @Test(arguments: [
        ("Dispatcher", "D"), ("bold-gazelle", "BG"), ("one-two-three", "OT"),
        ("Phone Fixture", "P"), ("", ""), ("bold--gazelle", "BG"),
        ("-bold-", "B"), ("--", ""), ("☀️-fox", "☀️F"),
        ("🦊-fox", "🦊F"), ("👩🏽‍💻-fox", "👩🏽‍💻F"), ("lowercase", "L"), ("1-bold", "1B"),
        (" hello", " "), ("ß-fox", "SS")
    ])
    func desktopInitials(name: String, expected: String) {
        #expect(CompanionAgentFace.initials(name) == expected)
    }

    @Test(arguments: [nil, "", "unknown", "#123456"] as [String?])
    func unknownAgentColoursUseIndigo(value: String?) {
        #expect(CompanionIdentityColor.agentRGB(value) == CompanionRGB(hex: "#6366f1"))
    }

    @Test func agentColoursUseOnlyTheDesktopPalette() {
        for (id, hex) in CompanionIdentityColor.palette {
            #expect(CompanionIdentityColor.agentRGB(id) == CompanionRGB(hex: hex))
        }
        #expect(CompanionIdentityColor.rgb(nil) == nil, "Project nil colour keeps its theme tint")
        #expect(CompanionIdentityColor.rgb("#123456") == CompanionRGB(hex: "#123456"))
        #expect(CompanionAgentFace.emojiWashOpacity == Double(0x20) / 255)
    }

    @Test func quickThenCustomProfileImageThenEmojiThenInitials() {
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "🌿", hasIcon: true, isQuick: true) == .quick)
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "🌿", hasIcon: true) == .icon)
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "", hasIcon: true) == .icon)
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "🌿") == .emoji("🌿"))
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "") == .initials("BG"))
        #expect(CompanionAgentFace.content(name: "bold-gazelle") == .initials("BG"))
    }

    @Test func senderUsesCanonicalProfileImageAndTracksReplacementAndRemoval() throws {
        var agent = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: "a"), name: "bold-gazelle", subtitle: "", status: .sleeping)
        agent.emoji = "🌿"
        agent.icon = .init(host: "h", kind: .agent, id: "a", version: "first")
        let sender = CompanionRoutedMessagePart.Sender(agentID: "a", name: "Old name")
        let original = try #require(CompanionSenderResolver(agents: [agent]).avatarIdentity(for: sender))
        #expect(original.face == .icon)
        #expect(original.face == CompanionAgentFace.content(name: agent.name, emoji: agent.emoji, hasIcon: agent.icon != nil))

        agent.icon = .init(host: "h", kind: .agent, id: "a", version: "replacement")
        let replacement = try #require(CompanionSenderResolver(agents: [agent]).avatarIdentity(for: sender))
        #expect(replacement.face == .icon)
        #expect(replacement.icon?.version == "replacement")
        #expect(replacement != original, "A new image version must invalidate the sender identity")

        agent.icon = nil
        #expect(CompanionSenderResolver(agents: [agent]).avatarIdentity(for: sender)?.face == .emoji("🌿"))
        agent.emoji = nil
        #expect(CompanionSenderResolver(agents: [agent]).avatarIdentity(for: sender)?.face == .initials("BG"))
    }

    @Test func quickSenderKeepsItsKindAndGoneSenderUsesDurableInitials() throws {
        var agent = CompanionAgent(id: .init(hostID: "h", projectID: "p", agentID: "q"), name: "flash-bolt", subtitle: "", status: .working)
        agent.isQuick = true
        let resolver = CompanionSenderResolver(agents: [agent])
        let identity = try #require(resolver.avatarIdentity(for: .init(agentID: "q", name: "Old")))
        #expect(identity.isQuick)
        #expect(identity.face == .quick)
        let gone = try #require(resolver.avatarIdentity(for: .init(agentID: "gone", name: "bold-gazelle")))
        #expect(!gone.isQuick && gone.face == .initials("BG"))
        #expect(CompanionIdentityColor.agentRGB(gone.color) == CompanionRGB(hex: "#6366f1"))
    }
}
