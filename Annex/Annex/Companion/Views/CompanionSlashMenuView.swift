import SwiftUI

/// The composer's `/` menu, above the field like the desktop's: each command's name and its description or argument
/// hint. Tapping one picks it; with a hardware keyboard the arrows move the highlight and Return or Tab pick it. The name
/// keeps its width and the description truncates.
struct CompanionSlashMenuView: View {
    let commands: [CompanionSlashCommand]
    let highlighted: Int
    let pick: (CompanionSlashCommand) -> Void
    @Environment(\.companionPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { pick(command) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/\(command.name)").font(.body.monospaced()).foregroundStyle(Color(palette.label)).layoutPriority(1)
                        if let detail = command.description ?? command.inputHint {
                            Text(detail).font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == highlighted ? Color(palette.label).opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("/\(command.name)")
                .accessibilityValue(command.description ?? command.inputHint ?? "")
                .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                .accessibilityIdentifier("companion-slash-\(command.name)")
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
        .accessibilityIdentifier("companion-slash-menu")
    }
}
