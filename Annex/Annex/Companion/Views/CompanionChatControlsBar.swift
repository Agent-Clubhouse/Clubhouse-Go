import SwiftUI

/// The desktop composer's level, model and effort pills (`Composer.tsx`), as menus above the phone's composer.
/// Changes show once the session's own event arrives, from the phone or the desktop alike.
struct CompanionChatControlsBar: View {
    @Bindable var store: CompanionStore
    let agent: CompanionAgent
    let controls: CompanionChatControls
    @State private var pendingLevel: CompanionPermissionLevel?
    @Environment(\.companionPalette) private var palette

    private var target: CompanionTarget { agent.id }
    private var enabled: Bool { store.canChangeChatControls(target) }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                levelMenu
                if let label = controls.modelLabel { modelMenu(label) }
                if controls.showsEffortChip { effortMenu }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .confirmationDialog(pendingLevel.map { "Switch to \($0.label)?" } ?? "", isPresented: Binding(get: { pendingLevel != nil }, set: { if !$0 { pendingLevel = nil } }),
                            titleVisibility: .visible, presenting: pendingLevel) { level in
            Button("Switch to \(level.label)") { Task { await store.setLevel(level, target: target) } }
        } message: { level in
            Text(level == .fullAccess
                 ? "\(agent.name) will edit files and run commands without asking you first."
                 : "\(agent.name) will decide for itself what needs your approval.")
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
                        else { Task { await store.setLevel(level, target: target) } }
                    } label: {
                        Label(level.label, systemImage: level == current ? "checkmark" : level.symbol)
                        Text(controls.levelNames[level].map { "\(level.detail) · \($0)" } ?? level.detail)
                    }
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

    private func modelMenu(_ label: String) -> some View {
        Menu {
            Section("Model") {
                ForEach(controls.models) { model in
                    Button {
                        guard model.id != controls.model else { return }
                        Task { await store.setModel(model.id, effort: controls.keptEffort, target: target) }
                    } label: {
                        if model.id == controls.model { Label(model.label, systemImage: "checkmark") } else { Text(model.label) }
                        if let detail = [model.description, model.costHint].compactMap({ $0 }).joined(separator: " · ").nonEmpty { Text(detail) }
                    }
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
                            if !controls.isOnDefaultEffort { Task { await store.setModel(model, effort: .providerDefault, target: target) } }
                        } label: {
                            if controls.isOnDefaultEffort { Label("Default", systemImage: "checkmark") } else { Text("Default") }
                            Text("The model's own default")
                        }
                    }
                    ForEach(controls.offeredEfforts, id: \.self) { effort in
                        let word = CompanionChatControls.effortWord(effort)
                        Button {
                            // Choosing the level the default resolved to pins it, so it isn't a no-op.
                            if effort != controls.chosenEffort { Task { await store.setModel(model, effort: .set(effort), target: target) } }
                        } label: {
                            if effort == controls.chosenEffort { Label(word, systemImage: "checkmark") } else { Text(word) }
                            if controls.effortIsDefault && effort == controls.effort { Text("Default") }
                        }
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
        .glassEffect(.regular.interactive(), in: .capsule)
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
