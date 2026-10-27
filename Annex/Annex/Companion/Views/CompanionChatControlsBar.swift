import SwiftUI

/// The desktop composer's level, model and effort pills (`Composer.tsx`), as menus above the phone's composer.
/// Changes show once the session's own event arrives, from the phone or the desktop alike.
/// Equatable on its inputs, so streamed transcript updates don't rebuild the menus (each rebuild is costly mid-stream).
struct CompanionChatControlsBar: View, Equatable {
    let agentName: String
    let controls: CompanionChatControls
    let enabled: Bool
    let setLevel: @MainActor (CompanionPermissionLevel) -> Void
    let setModel: @MainActor (String, CompanionEffortChoice?) -> Void
    @State private var pendingLevel: CompanionPermissionLevel?
    @Environment(\.companionPalette) private var palette

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentName == rhs.agentName && lhs.controls == rhs.controls && lhs.enabled == rhs.enabled
    }

    var body: some View {
        // One row; long names truncate rather than scroll, so the composer has no nested scroll view.
        HStack(spacing: 8) {
            levelMenu
            if let label = controls.modelLabel { modelMenu(label) }
            if controls.showsEffortChip { effortMenu }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(pendingLevel.map { "Switch to \($0.label)?" } ?? "", isPresented: Binding(get: { pendingLevel != nil }, set: { if !$0 { pendingLevel = nil } }),
                            titleVisibility: .visible, presenting: pendingLevel) { level in
            Button("Switch to \(level.label)") { setLevel(level) }
        } message: { level in
            Text(level == .fullAccess
                 ? "\(agentName) will edit files and run commands without asking you first."
                 : "\(agentName) will decide for itself what needs your approval.")
        }
    }

    private var levelMenu: some View {
        let current = controls.currentLevel
        return Menu {
            Section("Permissions") {
                ForEach(controls.levels, id: \.self) { level in
                    Button {
                        guard level != current else { return }
                        if level.needsConfirmation(from: current) { pendingLevel = level }
                        else { setLevel(level) }
                    } label: {
                        Label(level.label, systemImage: level == current ? "checkmark" : level.symbol)
                        Text(subtitle(level))
                    }
                    // Menus don't read subtitles aloud; the label carries them.
                    .accessibilityLabel("\(level.label), \(subtitle(level))")
                    .accessibilityAddTraits(level == current ? .isSelected : [])
                    .accessibilityIdentifier("companion-level-\(level.rawValue)")
                }
            }
        } label: {
            chip(current.label, systemImage: "shield", menu: controls.canChangeLevel)
        }
        .disabled(!enabled || !controls.canChangeLevel)
        .accessibilityLabel("Permissions: \(current.label)")
        .accessibilityHint(controls.canChangeLevel ? "Changes the permission level" : "This agent can't change permission level mid-session")
        .accessibilityIdentifier("companion-level-menu")
    }

    private func modelDetail(_ model: CompanionChatModel) -> String? {
        [model.description, model.costHint].compactMap { $0 }.joined(separator: " · ").nonEmpty
    }

    /// What the level does, then the driver's own name for it.
    private func subtitle(_ level: CompanionPermissionLevel) -> String {
        controls.levelNames[level].map { "\(level.detail) · \($0)" } ?? level.detail
    }

    private func modelMenu(_ label: String) -> some View {
        Menu {
            Section("Model") {
                ForEach(controls.models) { model in
                    Button {
                        guard model.id != controls.model else { return }
                        setModel(model.id, controls.keptEffort)
                    } label: {
                        if model.id == controls.model { Label(model.label, systemImage: "checkmark") } else { Text(model.label) }
                        if let detail = modelDetail(model) { Text(detail) }
                    }
                    .accessibilityLabel([model.label, modelDetail(model)].compactMap { $0 }.joined(separator: ", "))
                    .accessibilityAddTraits(model.id == controls.model ? .isSelected : [])
                }
            }
            note
        } label: {
            chip(label, systemImage: "cpu", menu: controls.showsModelMenu)
        }
        .disabled(!enabled || !controls.showsModelMenu)
        .accessibilityLabel("Model: \(label)")
        .accessibilityIdentifier("companion-model-menu")
    }

    private var effortMenu: some View {
        Menu {
            if let model = controls.model {
                Section("Effort") {
                    if controls.effortDefault {
                        Button {
                            if !controls.isOnDefaultEffort { setModel(model, .providerDefault) }
                        } label: {
                            if controls.isOnDefaultEffort { Label("Default", systemImage: "checkmark") } else { Text("Default") }
                            Text("The model's own default")
                        }
                        .accessibilityLabel("Default, the model's own default")
                        .accessibilityAddTraits(controls.isOnDefaultEffort ? .isSelected : [])
                    }
                    ForEach(controls.offeredEfforts, id: \.self) { effort in
                        let word = CompanionChatControls.effortWord(effort)
                        Button {
                            // Choosing the level the default resolved to pins it, so it isn't a no-op.
                            if effort != controls.chosenEffort { setModel(model, .set(effort)) }
                        } label: {
                            if effort == controls.chosenEffort { Label(word, systemImage: "checkmark") } else { Text(word) }
                            if controls.effortIsDefault && effort == controls.effort { Text("Default") }
                        }
                        .accessibilityAddTraits(effort == controls.chosenEffort ? .isSelected : [])
                    }
                }
            }
            note
        } label: {
            chip(controls.effortLabel, systemImage: "gauge.with.dots.needle.50percent", menu: controls.showsEffortMenu)
        }
        .disabled(!enabled || !controls.showsEffortMenu)
        .accessibilityLabel("Reasoning effort: \(controls.effortLabel)")
        .accessibilityIdentifier("companion-effort-menu")
    }

    /// When a change applies, under the menu's choices.
    @ViewBuilder private var note: some View {
        if let note = controls.switchNote { Section { Text(note) } }
    }

    private func chip(_ text: String, systemImage: String, menu: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).imageScale(.small).foregroundStyle(Color(palette.secondaryLabel))
            Text(text).lineLimit(1)
            if menu { Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(Color(palette.secondaryLabel)) }
        }
        .font(.footnote)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
    }
}

/// The current permission level, for the chat header.
struct CompanionLevelBadge: View {
    let level: CompanionPermissionLevel
    @Environment(\.companionPalette) private var palette
    var body: some View {
        Label(level.label, systemImage: level >= .auto ? "exclamationmark.shield" : "shield")
            .font(.caption)
            .foregroundStyle(level >= .auto ? Color(palette.warning) : Color(palette.secondaryLabel))
            .lineLimit(1)
            .accessibilityLabel("Permissions: \(level.label)")
            .accessibilityIdentifier("companion-header-level")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
