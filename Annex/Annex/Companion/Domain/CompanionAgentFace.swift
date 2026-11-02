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

    /// `name.split('-').map(w => w[0]).join('').toUpperCase().slice(0, 2)`.
    /// JavaScript indexes UTF-16 units, not letters or grapheme clusters. An isolated surrogate
    /// (e.g. the first half of a fox emoji) displays as a replacement character on both platforms.
    static func initials(_ name: String) -> String {
        let firstUnits = name.utf16.split(separator: 0x2D).compactMap(\.first)
        let upper = String(decoding: firstUnits, as: UTF16.self).uppercased()
        return String(decoding: upper.utf16.prefix(2), as: UTF16.self)
    }
}
