import Foundation

/// Desktop AgentAvatar's content order. Selecting an emoji or quick face never decodes an icon.
enum CompanionAgentFace: Equatable, Sendable {
    case quick
    case emoji(String)
    case icon
    case initials(String)

    static let emojiWashOpacity = Double(0x20) / 255

    static func content(name: String, emoji: String? = nil, iconData: Data? = nil, isQuick: Bool = false) -> Self {
        if isQuick { return .quick }
        if let emoji, !emoji.isEmpty { return .emoji(emoji) }
        if iconData != nil { return .icon }
        return .initials(initials(name))
    }

    /// First character of each hyphen-separated part, uppercased and limited to two initials.
    /// Preserve whole emoji and composed characters rather than the desktop's UTF-16 indexing bug.
    static func initials(_ name: String) -> String {
        String(name.split(separator: "-").compactMap(\.first).map(String.init).joined().uppercased().prefix(2))
    }
}
