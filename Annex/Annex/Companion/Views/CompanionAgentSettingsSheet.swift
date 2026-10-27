import SwiftUI

/// Opens a durable agent's settings from anywhere: the chat header, or an agent row's long-press menu.
struct CompanionAgentSettingsAction {
    var canOpen: @MainActor (CompanionTarget) -> Bool
    var open: @MainActor (CompanionTarget) -> Void
}

private struct CompanionAgentSettingsActionKey: EnvironmentKey {
    static let defaultValue: CompanionAgentSettingsAction? = nil
}

extension EnvironmentValues {
    var companionAgentSettings: CompanionAgentSettingsAction? {
        get { self[CompanionAgentSettingsActionKey.self] }
        set { self[CompanionAgentSettingsActionKey.self] = newValue }
    }
}

/// Wakes a sleeping durable agent from an agent row's long-press menu.
struct CompanionAgentWakeAction {
    /// The ways to wake it, or none when it isn't asleep.
    var choices: @MainActor (CompanionTarget) -> [CompanionWakeChoice]
    var wake: @MainActor (CompanionTarget, CompanionWakeChoice) -> Void
}

private struct CompanionAgentWakeActionKey: EnvironmentKey {
    static let defaultValue: CompanionAgentWakeAction? = nil
}

extension EnvironmentValues {
    var companionAgentWake: CompanionAgentWakeAction? {
        get { self[CompanionAgentWakeActionKey.self] }
        set { self[CompanionAgentWakeActionKey.self] = newValue }
    }
}

/// The long-press menu on an agent row: Wake & Resume and Start New Session for a sleeping agent,
/// and Agent settings when its desktop offers them.
struct CompanionAgentMenu: ViewModifier {
    let target: CompanionTarget
    @Environment(\.companionAgentSettings) private var settings
    @Environment(\.companionAgentWake) private var wake
    func body(content: Content) -> some View {
        let choices = wake?.choices(target) ?? []
        let canOpenSettings = settings?.canOpen(target) == true
        if canOpenSettings || !choices.isEmpty {
            content.contextMenu {
                if let wake {
                    ForEach(choices) { choice in
                        Button(choice.label, systemImage: choice.systemImage) { wake.wake(target, choice) }
                    }
                }
                if let settings, canOpenSettings {
                    Button("Agent settings", systemImage: "slider.horizontal.3") { settings.open(target) }
                }
            }
        } else {
            content
        }
    }
}

/// The wake buttons for a sleeping agent: Wake & Resume first when there's a session to resume, then Start New Session.
struct CompanionWakeButtons: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    var body: some View {
        let choices = store.wakeChoices(for: target)
        ForEach(Array(choices.enumerated()), id: \.element) { index, choice in
            let button = Button(choice.label, systemImage: choice.systemImage) { Task { await store.wake(target, choice) } }
                .disabled(!store.canWake(target))
                .accessibilityIdentifier(index == 0 ? "companion-wake" : "companion-wake-\(choice.rawValue)")
            if index == 0 { button.buttonStyle(.glassProminent).companionProminentLabel() } else { button.buttonStyle(.glass) }
        }
    }
}

/// The desktop's agent colours as a row of swatches.
struct CompanionColorSwatches: View {
    let colors: [CompanionColorOption]
    @Binding var selection: String
    var disabled = false
    @Environment(\.companionPalette) private var palette
    var body: some View {
        HStack(spacing: 10) {
            ForEach(colors) { color in
                let selected = color.id == selection
                Button { selection = color.id } label: {
                    Circle().fill(color.rgb.map { Color($0) } ?? Color(palette.fill))
                        .frame(width: 28, height: 28)
                        .overlay { if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                        .padding(3)
                        .overlay { if selected { Circle().strokeBorder(Color(palette.label), lineWidth: 2) } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.label)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("agent-color-\(color.id)")
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color")
    }
}

/// A durable agent's settings, as the desktop's Details → Settings card and the General page of Agent settings.
/// Every change saves at once. Settings read at spawn wait for the agent to sleep; auto-sleep changes any time.
struct CompanionAgentSettingsSheet: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    @Environment(\.dismiss) private var dismiss
    @Environment(\.companionPalette) private var palette
    @State private var settings: CompanionAgentSettings?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving = false
    @State private var nameDraft = ""
    @State private var emojiDraft = ""

    private var agent: CompanionAgent? { store.agent(for: target) }
    /// Re-read when the snapshot changes what the agent is doing, or its name, as the desktop broadcasts after an update.
    private var refreshKey: String {
        [agent?.status.rawValue ?? "", agent?.name ?? "", store.host(for: target)?.connection.label ?? ""].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let settings { form(settings) }
                else if let loadError {
                    ContentUnavailableView {
                        Label("Settings unavailable", systemImage: "slider.horizontal.3")
                    } description: { Text(loadError) } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Loading settings…").frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(agent?.name ?? "Agent settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: refreshKey) { await load() }
        }
    }

    @ViewBuilder private func form(_ settings: CompanionAgentSettings) -> some View {
        let sleeping = settings.sleeping
        Section {
            Text(summary(settings)).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                .accessibilityIdentifier("agent-settings-summary")
            if settings.hasLockedSettings {
                Label(CompanionAgentSettings.lockedHint, systemImage: "lock")
                    .font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    .accessibilityIdentifier("agent-settings-locked-hint")
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Color(palette.error))
                    .accessibilityIdentifier("agent-settings-error")
            }
        }

        Section {
            LabeledContent("Name") {
                TextField("Name", text: $nameDraft)
                    .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit {
                        let name = nameDraft.trimmingCharacters(in: .whitespaces)
                        if name.isEmpty || name == settings.name.value { nameDraft = settings.name.value } else { save(.init(name: name)) }
                    }
                    .disabled(!settings.name.canEdit(sleeping: sleeping) || saving)
                    .accessibilityIdentifier("agent-settings-name")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                CompanionColorSwatches(colors: settings.options.colors,
                                       selection: Binding(get: { settings.color.value }, set: { if $0 != settings.color.value { save(.init(color: $0)) } }),
                                       disabled: !settings.color.canEdit(sleeping: sleeping) || saving)
            }
            LabeledContent("Emoji") {
                HStack {
                    TextField("None", text: $emojiDraft)
                        .multilineTextAlignment(.trailing).submitLabel(.done)
                        .onSubmit {
                            let emoji = emojiDraft.trimmingCharacters(in: .whitespaces)
                            guard emoji != (settings.emoji.value ?? "") else { return }
                            guard emoji.utf16.count <= 16 else { emojiDraft = settings.emoji.value ?? ""; saveError = "Use a shorter emoji."; return }
                            save(.init(emoji: emoji.isEmpty ? .clear : .set(emoji)))
                        }
                        .accessibilityIdentifier("agent-settings-emoji")
                    if settings.emoji.value != nil {
                        Button("Clear emoji", systemImage: "xmark.circle.fill") { save(.init(emoji: .clear)) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(Color(palette.secondaryLabel))
                    }
                }
                .disabled(!settings.emoji.canEdit(sleeping: sleeping) || saving)
            }
        } header: { Text("Identity") } footer: {
            if settings.hasImageIcon { Text("This agent has an image icon. Setting an emoji replaces it.") }
        }

        Section {
            Picker("Runs on", selection: Binding(get: { settings.orchestrator.value ?? settings.resolvedOrchestrator },
                                                 set: { if $0 != (settings.orchestrator.value ?? settings.resolvedOrchestrator) { save(.init(orchestrator: $0)) } })) {
                ForEach(orchestratorChoices(settings), id: \.id) { Text($0.label).tag($0.id) }
            }
            .disabled(!settings.orchestrator.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-orchestrator")
            Picker("Model", selection: Binding(get: { settings.model.value }, set: { if $0 != settings.model.value { save(.init(model: $0)) } })) {
                ForEach(settings.options.models(for: settings.orchestrator.value ?? settings.resolvedOrchestrator, keeping: settings.model.value)) {
                    Text($0.label).tag($0.id)
                }
            }
            .disabled(!settings.model.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-model")
            Picker("Runtime", selection: Binding(get: { settings.runtime.value }, set: { if $0 != settings.runtime.value { save(.init(runtime: $0)) } })) {
                Text("Provider default").tag("default")
                Text("Chat").tag("chat")
                Text("Terminal").tag("terminal")
            }
            .disabled(!settings.runtime.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-runtime")
            Picker("Persona", selection: Binding(get: { settings.persona.value ?? "" },
                                                 set: { if $0 != (settings.persona.value ?? "") { save(.init(persona: $0.isEmpty ? .clear : .set($0))) } })) {
                Text("Project default").tag("")
                ForEach(settings.options.personas) { Text($0.name).tag($0.id) }
                if let current = settings.persona.value, !settings.options.personas.contains(where: { $0.id == current }) { Text(current).tag(current) }
            }
            .disabled(!settings.persona.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-persona")
        } header: { Text("Runtime") } footer: {
            Text(settings.runtime.editable == .never ? "Applied on the next wake. Chat isn't available for this CLI." : "Applied on the next wake.")
        }

        Section {
            Picker("Auto-sleep", selection: Binding(get: { settings.idleSleep.value }, set: { if $0 != settings.idleSleep.value { save(.init(idleSleep: $0)) } })) {
                ForEach(CompanionIdleSleep.choices(minutes: settings.idleSleepMinutes, current: settings.idleSleep.value), id: \.self) {
                    Text($0.label(appMinutes: settings.appIdleMinutes)).tag($0)
                }
            }
            .disabled(!settings.idleSleep.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-auto-sleep")
        } footer: {
            Text(settings.idleSleepApplies
                 ? "\(settings.autoSleepSummary). \(settings.idleSleep.value.source(appMinutes: settings.appIdleMinutes))."
                 : "Only agents running in chat sleep when idle. \(settings.idleSleep.value.source(appMinutes: settings.appIdleMinutes)).")
        }

        Section {
            if settings.clubhouseMode.editable != .never, let value = settings.clubhouseMode.value {
                Toggle("Clubhouse mode for this agent", isOn: Binding(get: { value }, set: { save(.init(clubhouseMode: $0)) }))
                    .disabled(!settings.clubhouseMode.canEdit(sleeping: sleeping) || saving)
            } else {
                LabeledContent("Clubhouse mode", value: clubhouseModeSummary(settings))
            }
            LabeledContent("Free Agent Mode", value: settings.freeAgentMode.value ? "On" : "Off")
                .accessibilityIdentifier("agent-settings-free-agent-mode")
        } header: { Text("Access") } footer: {
            Text("Free Agent Mode can only be changed on the desktop.")
        }
    }

    /// "Chat · Opus · Sleeps after 30 min", as the Settings card's one line.
    private func summary(_ settings: CompanionAgentSettings) -> String {
        var parts = [settings.resolvedRuntime == "terminal" ? "Terminal" : "Chat", settings.orchestratorName, settings.modelLabel]
        if settings.idleSleepApplies { parts.append(settings.autoSleepSummary) }
        return parts.joined(separator: " · ")
    }

    private func clubhouseModeSummary(_ settings: CompanionAgentSettings) -> String {
        switch settings.clubhouseMode.value {
        case nil: "Project isn't in Clubhouse mode"
        case true?: "On"
        case false?: "Off, keeps its own settings"
        }
    }

    private func orchestratorChoices(_ settings: CompanionAgentSettings) -> [(id: String, label: String)] {
        var choices = settings.options.orchestrators.map { (id: $0.id, label: $0.available ? $0.displayName : "\($0.displayName) (CLI not found)") }
        let current = settings.orchestrator.value ?? settings.resolvedOrchestrator
        if !choices.contains(where: { $0.id == current }) { choices.append((id: current, label: current)) }
        return choices
    }

    private func load() async {
        do {
            let loaded = try await store.settings(for: target)
            apply(loaded.keepingOptions(of: settings))
            loadError = nil
        } catch {
            if settings == nil { loadError = error.localizedDescription }
        }
    }

    private func save(_ change: CompanionSettingsChange) {
        guard !saving else { return }
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            do { apply(try await store.updateSettings(change, target: target).keepingOptions(of: settings)) }
            catch {
                saveError = error.localizedDescription
                // Put the controls back to what the desktop has.
                if let settings { apply(settings) }
                await load()
            }
        }
    }

    private func apply(_ loaded: CompanionAgentSettings) {
        settings = loaded
        nameDraft = loaded.name.value
        emojiDraft = loaded.emoji.value ?? ""
    }
}

/// Shown in a durable agent's chat right after the phone creates it: setting up, then "Wake with a message".
struct CompanionCreatedAgentNotice: View {
    @Bindable var store: CompanionStore
    let agent: CompanionAgent
    var onWakeWithMessage: () -> Void
    @Environment(\.companionPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            switch agent.status {
            case .starting:
                ProgressView()
                text("Setting up \(agent.name)", "Making its worktree and branch on your desktop.")
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color(palette.error))
                text("\(agent.name) couldn't be set up", "Open Clubhouse on your desktop to see why.")
            default:
                Image(systemName: "checkmark.circle").foregroundStyle(Color(palette.success))
                VStack(alignment: .leading, spacing: 8) {
                    text("\(agent.name) is ready", "It sleeps until you wake it.")
                    Button("Wake with a message", systemImage: "text.bubble", action: onWakeWithMessage)
                        .buttonStyle(.glassProminent).companionProminentLabel()
                        .accessibilityIdentifier("companion-wake-with-message")
                    // Or wake it without one. A new agent has no session yet, so this is Start New Session.
                    ForEach(store.wakeChoices(for: agent.id)) { choice in
                        Button(choice.label, systemImage: choice.systemImage) { Task { await store.wake(agent.id, choice) } }
                            .buttonStyle(.glass).disabled(!store.mayWake(agent.id))
                            .accessibilityIdentifier("companion-created-wake-\(choice.rawValue)")
                    }
                }
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark") { store.justCreated = nil }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(Color(palette.secondaryLabel))
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(.horizontal, 16).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion-created-agent")
        .onChange(of: agent.status) { old, new in
            // Done being created: read its chat again so the composer can wake it with a message.
            if old == .starting && new != .starting { Task { await store.load(agent.id, force: true) } }
            if new == .working { store.justCreated = nil }
        }
    }

    private func text(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
        }
    }
}
