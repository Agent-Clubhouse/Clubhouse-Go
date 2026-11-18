import SwiftUI

/// The desktop composer's level, model and effort pills (`Composer.tsx`), as menus above the phone's composer.
/// Changes show once the session's own event arrives, from the phone or the desktop alike.
/// Equatable on its inputs, so streamed transcript updates don't rebuild the menus (each rebuild is costly mid-stream).
struct CompanionChatControlsBar: View, Equatable {
    // Regular glass adds 14pt to the label. Size the native label itself so its
    // accessibility target is 44pt; an outer frame alone does not enlarge it.
    private static let compactLabelSize: CGFloat = 44 - 14

    let agentName: String
    let controls: CompanionChatControls
    let enabled: Bool
    let setLevel: @MainActor (CompanionPermissionLevel) -> Void
    let setModel: @MainActor (String, CompanionEffortChoice?) -> Void
    var compact = false
    var availableHeight: CGFloat = .infinity
    var keyboardVisible = false
    let requestLevel: @MainActor (CompanionPermissionLevel) -> Void
    var modelDifference: CompanionModelDifference?
    var savedModelError: String?
    var retrySavedModel: @MainActor () -> Void = {}
    @Environment(\.companionPalette) private var palette

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agentName == rhs.agentName && lhs.controls == rhs.controls && lhs.enabled == rhs.enabled && lhs.compact == rhs.compact
            && lhs.usesSingleLinePermissionRows == rhs.usesSingleLinePermissionRows
            && lhs.modelDifference == rhs.modelDifference && lhs.savedModelError == rhs.savedModelError
    }

    private var usesSingleLinePermissionRows: Bool {
        // Measured native submenu chrome is 100.5pt and each two-line row is 58pt
        // at Large. Reserve another 20pt for the next standard text size and menu insets.
        // The existing keyboard-safe container measurement distinguishes short editing
        // windows from roomy phones/tablets and from the same phone with its keyboard down.
        compact && keyboardVisible && availableHeight < 100.5 + CGFloat(controls.levels.count) * 58 + 20
    }

    var body: some View {
        Group {
            if compact {
                Menu {
                    levelMenu
                    if let label = controls.modelLabel { modelMenu(label) }
                    if controls.showsEffortChip { effortMenu }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20))
                        .frame(width: Self.compactLabelSize, height: Self.compactLabelSize)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .foregroundStyle(Color(controls.currentLevel >= .auto ? palette.warning : palette.secondaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .accessibilityLabel(["Chat controls", "Permissions: \(controls.currentLevel.label)", controls.modelLabel.map { "Model: \($0)" }]
                    .compactMap { $0 }.joined(separator: ", "))
                .accessibilityInputLabels(["Chat controls", "Options"])
                .accessibilityValue(controls.effortLabel)
                .accessibilityHint("Permissions, model and reasoning effort")
                .accessibilityIdentifier("companion-level-menu")
            } else {
                HStack(spacing: 8) {
                    levelMenu
                    if let label = controls.modelLabel { modelMenu(label) }
                    if controls.showsEffortChip { effortMenu }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var levelMenu: some View {
        let current = controls.currentLevel
        return Menu {
            Section("Permissions") {
                ForEach(controls.levels, id: \.self) { level in
                    Button {
                        guard level != current else { return }
                        if level.needsConfirmation(from: current) { requestLevel(level) }
                        else { setLevel(level) }
                    } label: {
                        Label(level.label, systemImage: level == current ? "checkmark" : level.symbol)
                        // Single-line native rows keep all five levels above the editing keyboard.
                        // The full meaning remains in the AX label and the escalation confirmation.
                        if !usesSingleLinePermissionRows { Text(permissionSummary(level)) }
                    }
                    // Menus don't read subtitles aloud; the label carries them.
                    .accessibilityLabel("\(level.label), \(subtitle(level))")
                    .accessibilityAddTraits(level == current ? .isSelected : [])
                    .accessibilityIdentifier("companion-level-\(level.rawValue)")
                }
            }
        } label: {
            if compact { Label(current.label, systemImage: "shield") }
            else {
                chip(current.label, systemImage: "shield", menu: controls.canChangeLevel)
            }
        }
        .disabled(!enabled || !controls.canChangeLevel)
        .accessibilityLabel("Permissions: \(current.label)")
        .accessibilityHint(controls.canChangeLevel ? "Changes the permission level" : "This agent can't change permission level mid-session")
        .accessibilityIdentifier(compact ? "companion-permissions-menu" : "companion-level-menu")
    }

    private func modelDetail(_ model: CompanionChatModel) -> String? {
        [model.description, model.costHint].compactMap { $0 }.joined(separator: " · ").nonEmpty
    }

    /// What the level does, then the driver's own name for it.
    private func subtitle(_ level: CompanionPermissionLevel) -> String {
        controls.levelNames[level].map { "\(level.detail) · \($0)" } ?? level.detail
    }

    /// Keep native menu rows to one subtitle line; VoiceOver retains the complete description and driver name.
    private func permissionSummary(_ level: CompanionPermissionLevel) -> String {
        switch level {
        case .plan: "Read only"
        case .ask: "Edits and commands"
        case .autoEdit: "Ask for commands"
        case .auto: "Chooses when to ask"
        case .fullAccess: "No prompts"
        }
    }

    private func modelMenu(_ label: String) -> some View {
        Menu {
            Section(modelSectionTitle) {
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
                if savedModelError != nil {
                    Button("Try again", action: retrySavedModel)
                }
            }
            note
        } label: {
            if compact { Label(label, systemImage: "cpu") }
            else { chip(label, systemImage: "cpu", menu: controls.showsModelMenu) }
        }
        .disabled(!enabled || !controls.showsModelMenu)
        .accessibilityLabel("Model: \(label)")
        .accessibilityIdentifier("companion-model-menu")
    }

    private var modelSectionTitle: String {
        if let modelDifference {
            return "Model\nSession: \(modelDifference.sessionLabel)\nSaved: \(modelDifference.savedLabel) (next start)"
        }
        if let savedModelError { return "Model\nSaved model unavailable. \(savedModelError)" }
        return "Model"
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
            if compact { Label(controls.effortLabel, systemImage: "gauge.with.dots.needle.50percent") }
            else { chip(controls.effortLabel, systemImage: "gauge.with.dots.needle.50percent", menu: controls.showsEffortMenu) }
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
        Text(level.label)
            .font(.caption)
            .foregroundStyle(level >= .auto ? Color(palette.warning) : Color(palette.secondaryLabel))
            .lineLimit(nil)
            .accessibilityLabel("Permissions: \(level.label)")
            .accessibilityIdentifier("companion-header-level")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
