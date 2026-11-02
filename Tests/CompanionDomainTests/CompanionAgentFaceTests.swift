import Foundation
import Testing
@testable import CompanionDomain

/// Agent parity plan: desktop initials (including UTF-16 edge cases), face precedence,
/// default colour, quick identity, and snapshot updates. Project identity stays unchanged.
struct CompanionAgentFaceTests {
    @Test(arguments: [
        ("Dispatcher", "D"), ("bold-gazelle", "BG"), ("one-two-three", "OT"),
        ("Phone Fixture", "P"), ("", ""), ("bold--gazelle", "BG"),
        ("-bold-", "B"), ("--", ""), ("☀️-fox", "☀F"),
        ("🦊-fox", "�F"), ("lowercase", "L"), ("1-bold", "1B"),
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

    @Test func quickThenEmojiThenImageThenInitials() {
        let icon = Data([1, 2])
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "🌿", iconData: icon, isQuick: true) == .quick)
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "🌿", iconData: icon) == .emoji("🌿"))
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "", iconData: icon) == .icon)
        #expect(CompanionAgentFace.content(name: "bold-gazelle", emoji: "") == .initials("BG"))
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
