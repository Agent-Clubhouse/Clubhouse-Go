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

/// Initials in a tinted rounded square, with the status dot on its corner.
struct CompanionAgentAvatar: View {
    let agent: CompanionAgent
    var size: CGFloat = 32
    @Environment(\.companionPalette) private var palette
    var body: some View {
        let color = agent.status.color(in: palette)
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(Color(palette.tint))
            .frame(width: size, height: size)
            .background(Color(palette.tintSoft), in: RoundedRectangle(cornerRadius: size * 0.31, style: .continuous))
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
    private var initials: String { String(agent.name.filter(\.isLetter).prefix(2)).uppercased() }
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
