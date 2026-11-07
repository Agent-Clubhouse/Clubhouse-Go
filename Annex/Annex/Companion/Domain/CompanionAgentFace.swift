import Foundation

/// Saved profile images win over emoji, including when desktop crop-save leaves both set.
/// Snapshot agent icons are profile images, never provider glyphs. Quick faces never decode one.
enum CompanionAgentFace: Equatable, Sendable {
    case quick
    case emoji(String)
    case icon
    case initials(String)

    static let emojiWashOpacity = Double(0x20) / 255

    static func content(name: String, emoji: String? = nil, hasIcon: Bool = false, isQuick: Bool = false) -> Self {
        if isQuick { return .quick }
        if hasIcon { return .icon }
        if let emoji, !emoji.isEmpty { return .emoji(emoji) }
        return .initials(initials(name))
    }

    /// First character of each hyphen-separated part, uppercased and limited to two initials.
    /// Preserve whole emoji and composed characters rather than the desktop's UTF-16 indexing bug.
    static func initials(_ name: String) -> String {
        String(name.split(separator: "-").compactMap(\.first).map(String.init).joined().uppercased().prefix(2))
    }
}
