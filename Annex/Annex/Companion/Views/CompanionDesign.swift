import SwiftUI

extension Color {
    init(_ rgb: CompanionRGB) { self.init(red: rgb.red, green: rgb.green, blue: rgb.blue) }
}

private struct CompanionPaletteKey: EnvironmentKey {
    static let defaultValue = CompanionPalette(theme: .clubhouse, dark: true)
}

private struct CompanionOpenAgentKey: EnvironmentKey {
    static let defaultValue: @MainActor (CompanionTarget) -> Void = { _ in }
}

extension EnvironmentValues {
    var companionPalette: CompanionPalette {
        get { self[CompanionPaletteKey.self] }
        set { self[CompanionPaletteKey.self] = newValue }
    }
    /// Opens another agent's conversation from anywhere, replacing the one on screen.
    var companionOpenAgent: @MainActor (CompanionTarget) -> Void {
        get { self[CompanionOpenAgentKey.self] }
        set { self[CompanionOpenAgentKey.self] = newValue }
    }
}

/// Applies a desktop theme for the current appearance: tint, text color and the palette for custom views.
struct CompanionThemed: ViewModifier {
    let theme: CompanionDesktopTheme
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let palette = CompanionPalette(theme: theme, dark: colorScheme == .dark)
        content
            .environment(\.companionPalette, palette)
            .tint(Color(palette.tint))
            .foregroundStyle(Color(palette.label))
    }
}

extension View {
    func companionTheme(_ theme: CompanionDesktopTheme) -> some View { modifier(CompanionThemed(theme: theme)) }

    /// The theme's background with its gradient washed in at the top, for screens whose bars float over content.
    func companionBackground() -> some View { modifier(CompanionBackground()) }

    /// Plain grouped lists on the theme's grounds.
    func companionListStyle() -> some View { modifier(CompanionListStyle()) }
}

private struct CompanionBackground: ViewModifier {
    @Environment(\.companionPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            ZStack(alignment: .top) {
                Color(palette.background)
                if !reduceTransparency {
                    ZStack {
                        RadialGradient(colors: [Color(palette.washStart), .clear], center: UnitPoint(x: 0.15, y: 0), startRadius: 0, endRadius: 360)
                        RadialGradient(colors: [Color(palette.washEnd), .clear], center: UnitPoint(x: 0.95, y: 0.08), startRadius: 0, endRadius: 320)
                    }
                    .frame(height: 460)
                    .opacity(palette.isDark ? 0.42 : 0.3)
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct CompanionListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped).scrollContentBackground(.hidden).companionBackground()
    }
}

/// A grouped-list row background in the theme's card color.
struct CompanionCardBackground: View {
    @Environment(\.companionPalette) private var palette
    var body: some View { Color(palette.card) }
}

extension CompanionAgentStatus {
    func color(in palette: CompanionPalette) -> Color { Color(dot.color(in: palette)) }
}

/// The agent’s circular desktop identity, with its status dot overlapping the lower trailing edge.
struct CompanionAgentAvatar: View {
    let agent: CompanionAgent
    var size: CGFloat = 32
    @Environment(\.companionPalette) private var palette
    var body: some View {
        let color = agent.status.color(in: palette)
        CompanionIdentityFace(name: agent.name, color: agent.color, emoji: agent.emoji, iconData: agent.iconData, size: size, isQuick: agent.isQuick)
            .overlay(alignment: .bottomTrailing) {
                let hollow = agent.status.dot.isHollow
                Circle()
                    .fill(hollow ? Color.clear : color)
                    .overlay { if hollow { Circle().strokeBorder(color, lineWidth: 1.5) } }
                    .frame(width: size * 0.34, height: size * 0.34)
                    .padding(2).background(Color(palette.card), in: Circle())
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }
}

/// A project's desktop identity, for its Home header.
struct CompanionProjectBadge: View {
    let project: CompanionProject
    var size: CGFloat = 22
    var body: some View {
        CompanionProjectIdentityFace(name: project.name, color: project.color, emoji: project.emoji, iconData: project.iconData, size: size)
            .accessibilityHidden(true)
    }
}

/// Quick bolt, emoji wash, cached image, or initials on the agent colour; always circular.
struct CompanionIdentityFace: View {
    let name: String
    var color: String?
    var emoji: String?
    var iconData: Data?
    var size: CGFloat
    var isQuick = false
    @Environment(\.companionPalette) private var palette

    var body: some View {
        let identity = CompanionIdentityColor.agentRGB(color)
        Group {
            switch CompanionAgentFace.content(name: name, emoji: emoji, iconData: iconData, isQuick: isQuick) {
            case .quick:
                Image(systemName: "bolt")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Color(palette.secondaryLabel))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(palette.fill))
            case .emoji(let emoji):
                Text(emoji).font(.system(size: size * 0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(identity).opacity(CompanionAgentFace.emojiWashOpacity))
            case .icon:
                if let image = iconData.flatMap(CompanionIconCache.image(for:)) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    initials(CompanionAgentFace.initials(name), color: identity)
                }
            case .initials(let text):
                initials(text, color: identity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func initials(_ text: String, color: CompanionRGB) -> some View {
        Text(text).font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(Color(color.contrast(with: .white) >= color.contrast(with: .black) ? .white : .black))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(color))
    }
}

/// Project rendering is independent of agent parity: retain its square, initials and theme fallback.
private struct CompanionProjectIdentityFace: View {
    let name: String
    var color: String?
    var emoji: String?
    var iconData: Data?
    var size: CGFloat
    @Environment(\.companionPalette) private var palette
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
        let identity = CompanionIdentityColor.rgb(color)
        Group {
            if let image = iconData.flatMap(CompanionIconCache.image(for:)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let emoji, !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(identity.map { Color($0).opacity(0.22) } ?? Color(palette.tintSoft))
            } else if let identity {
                Text(initials).font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(identity.contrast(with: .white) >= identity.contrast(with: .black) ? .white : .black))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(identity))
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(palette.tint))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(palette.tintSoft))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
    private var initials: String { String(name.filter(\.isLetter).prefix(2)).uppercased() }
}

/// Decoded icon images, so list rows don't decode the same bytes on every render.
@MainActor enum CompanionIconCache {
    private static let cache = NSCache<NSData, UIImage>()
    static func image(for data: Data) -> UIImage? {
        if let image = cache.object(forKey: data as NSData) { return image }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: data as NSData)
        return image
    }
}

/// Free Agent Mode skips every permission prompt. Shown in red wherever the agent is, as on the desktop.
struct CompanionFreeAgentBadge: View {
    @Environment(\.companionPalette) private var palette
    var body: some View {
        Label("Free Agent", systemImage: "exclamationmark.shield.fill")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color(palette.error))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color(palette.error).opacity(0.14), in: Capsule())
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Free Agent Mode: all permissions bypassed")
            .accessibilityIdentifier("free-agent-badge")
    }
}

/// Status always carries a word as well as a color, so it reads with Increase Contrast and for color-blind people.
struct CompanionStatusText: View {
    let status: CompanionAgentStatus
    @Environment(\.companionPalette) private var palette
    var body: some View { Text(status.label).foregroundStyle(Color(status.dot.textColor(in: palette))) }
}

/// The 30pt-style list row used by Home, Needs you, Agents and Search.
struct CompanionAgentListRow: View {
    let agent: CompanionAgent
    var hostTag: String?
    var detail: String?
    @Environment(\.companionPalette) private var palette
    var body: some View {
        HStack(spacing: 12) {
            CompanionAgentAvatar(agent: agent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.body).lineLimit(1)
                    if agent.freeAgentMode { CompanionFreeAgentBadge() }
                    if let hostTag { CompanionHostTag(name: hostTag) }
                }
                HStack(spacing: 4) {
                    CompanionStatusText(status: agent.status)
                    if let detail = detail ?? (agent.subtitle.isEmpty ? nil : agent.subtitle) {
                        Text("· \(detail)").foregroundStyle(Color(palette.secondaryLabel)).lineLimit(1)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .modifier(CompanionAgentMenu(target: agent.id))
    }
}

struct CompanionHostTag: View {
    let name: String
    @Environment(\.companionPalette) private var palette
    var body: some View {
        Text(name).font(.caption2.weight(.semibold)).foregroundStyle(Color(palette.secondaryLabel))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color(palette.fill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// A floating glass capsule for transient notices: reconnecting, another agent needs you, undo.
struct CompanionGlassBanner<Trailing: View>: View {
    let systemImage: String?
    let text: Text
    @ViewBuilder var trailing: Trailing
    @Environment(\.companionPalette) private var palette
    var body: some View {
        HStack(spacing: 10) {
            if let systemImage { Image(systemName: systemImage).foregroundStyle(Color(palette.secondaryLabel)) }
            text.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
    }
}

/// A horizontally scrolling row of filter chips. Chips are content, not glass.
struct CompanionChips<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.companionPalette) private var palette
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    let (value, label) = option
                    Button { selection = value } label: {
                        Text(label).font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(minHeight: 34)
                            .foregroundStyle(selection == value ? Color(palette.onTint) : Color(palette.label))
                            .background(selection == value ? Color(palette.tint) : Color(palette.fill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// A round tinted button, such as Send. The glyph uses `onTint` so it reads on light accents in dark mode,
/// and the disabled state has its own fill rather than a dimmed tint.
struct CompanionTintedCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TintedCircle(configuration: configuration) }

    private struct TintedCircle: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.companionPalette) private var palette
        var body: some View {
            configuration.label
                .foregroundStyle(Color(isEnabled ? palette.onTint : palette.secondaryLabel))
                .background(Color(isEnabled ? palette.tint : palette.fill), in: Circle())
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Circle())
        }
    }
}

extension ButtonStyle where Self == CompanionTintedCircleButtonStyle {
    static var companionTintedCircle: CompanionTintedCircleButtonStyle { .init() }
}

/// Text on system prominent buttons defaults to white, which is unreadable on the lighter tint used in dark mode.
private struct CompanionProminentLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.companionPalette) private var palette
    func body(content: Content) -> some View {
        content.foregroundStyle(Color(isEnabled ? palette.onTint : palette.secondaryLabel))
    }
}

extension View {
    /// Use after `.borderedProminent` or `.glassProminent` on buttons filled with the theme tint.
    func companionProminentLabel() -> some View { modifier(CompanionProminentLabel()) }
}

extension View {
    /// A CLI's live model list can run long; past a dozen it opens as its own scrolling list rather than a menu.
    @ViewBuilder func companionModelPickerStyle(count: Int) -> some View {
        if count > CompanionAgentOptions.menuModelLimit { pickerStyle(.navigationLink) } else { self }
    }
}
