import SwiftUI
import ClubhouseTransport

/// Owned by the whole settings form, not its lazy sections.
struct CompanionDispatcherSettingsDrafts {
    enum Field { case name, emoji, personality }

    struct TextDraft {
        var text = "" {
            didSet {
                if let baseline, text.utf8.elementsEqual(baseline.utf8) { serverChanged = false }
            }
        }
        private var baseline: String?
        private var serverChanged = false

        var hasConflict: Bool {
            serverChanged && baseline.map { !text.utf8.elementsEqual($0.utf8) } == true
        }

        mutating func receive(_ value: String, replacing: Bool = false) {
            let pending = baseline.map { !text.utf8.elementsEqual($0.utf8) } ?? false
            if replacing || !pending || text.utf8.elementsEqual(value.utf8) {
                text = value
                serverChanged = false
            } else if baseline.map({ !$0.utf8.elementsEqual(value.utf8) }) == true {
                serverChanged = true
            }
            baseline = value
        }
    }

    var name = TextDraft()
    var emoji = TextDraft()
    var personality = TextDraft()

    mutating func receive(_ settings: CompanionDispatcherSettings, saved field: Field? = nil) {
        name.receive(settings.identity.name, replacing: field == .name)
        emoji.receive(settings.identity.emoji ?? "", replacing: field == .emoji)
        personality.receive(settings.personality?.text ?? "", replacing: field == .personality)
    }
}

/// Settings > Dispatcher on the phone (#338): Behavior, Choose models yourself, its name and look, personality,
/// today's usage, and its two resets. Shown in the Dispatcher's settings instead of the raw model and Access rows.
/// Every change saves at once, and the desktop's result is what's shown. The resets each ask first, with the
/// confirmation read right before asking; a stale one asks again rather than retrying.
struct CompanionDispatcherSettingsSections: View {
    @Bindable var store: CompanionStore
    let hostID: String
    /// Colours and CLIs with their models, from its agent settings.
    let options: CompanionAgentOptions
    /// Efforts its live chat reports, offered for a pick alongside the CLI's default.
    var efforts: [String] = []
    @Binding var drafts: CompanionDispatcherSettingsDrafts
    let loadError: String?
    let reload: () async -> Void
    @Environment(\.companionPalette) private var palette
    @State private var saving = false
    @State private var saveError: String?

    private var settings: CompanionDispatcherSettings? { store.dispatcherSettings(hostID: hostID) }
    private var resetting: Bool { store.dispatcherResetting.contains(hostID) }

    var body: some View {
        if let settings {
            content(settings)
        } else if let loadError {
            Section("Dispatcher") {
                Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(Color(palette.error))
                    .accessibilityIdentifier("dispatcher-settings-error")
                Button("Try again") { Task { await reload() } }
            }
        } else {
            Section { ProgressView("Loading Dispatcher settings…").frame(maxWidth: .infinity) }
        }
    }

    /// The prompt for this desktop's Dispatcher.
    private var prompt: CompanionDispatcherResetPrompt? {
        store.dispatcherResetPrompt.flatMap { $0.hostID == hostID ? $0 : nil }
    }

    @ViewBuilder private func content(_ settings: CompanionDispatcherSettings) -> some View {
        behaviorSection(settings)
        modelsSection(settings)
        identitySection(settings)
        if let personality = settings.personality { personalitySection(personality) }
        if let usage = settings.usage { usageSection(usage) }
        resetsSection(settings)
    }

    // MARK: Behavior

    private func behaviorSection(_ settings: CompanionDispatcherSettings) -> some View {
        Section {
            ForEach(settings.behavior.choices) { choice in
                let selected = choice.id == settings.behavior.value
                Button {
                    if !selected { save { try await store.updateDispatcher(.init(behavior: choice.id), hostID: hostID) } }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label).foregroundStyle(Color(palette.label))
                            if let description = choice.description {
                                Text(description).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                            }
                        }
                        Spacer()
                        if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!settings.behavior.editable || saving)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("dispatcher-behavior-\(choice.id)")
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Color(palette.error))
                    .accessibilityIdentifier("dispatcher-settings-save-error")
            }
        } header: { Text("Behavior") } footer: {
            if let note = settings.behavior.note { Text(note) }
        }
    }

    // MARK: Choose models yourself

    @ViewBuilder private func modelsSection(_ settings: CompanionDispatcherSettings) -> some View {
        Section {
            Toggle("Choose models yourself", isOn: Binding(get: { settings.models.byHand }, set: { on in
                save { try await store.setDispatcherModels(.byHand(on), hostID: hostID) }
            }))
            .disabled(!settings.models.editable || saving)
            .accessibilityIdentifier("dispatcher-models-by-hand")
            if settings.models.byHand {
                ForEach(settings.models.roles) { role in roleRows(role, editable: settings.models.editable) }
            }
        } header: { Text("Models") } footer: {
            if settings.models.byHand, let note = settings.models.note { Text(note) }
        }
    }

    @ViewBuilder private func roleRows(_ role: CompanionDispatcherSettings.Role, editable: Bool) -> some View {
        let pick = role.pick
        let provider = pick?.provider ?? options.orchestrators.first?.id
        VStack(alignment: .leading, spacing: 2) {
            Text(role.label).font(.headline)
            if let help = role.help { Text(help).font(.caption).foregroundStyle(Color(palette.secondaryLabel)) }
        }
        .accessibilityElement(children: .combine)
        Picker("CLI", selection: Binding(get: { provider ?? "" }, set: { id in
            if id != provider { save { try await store.setDispatcherModels(.pick(role: role.id, provider: id), hostID: hostID) } }
        })) {
            ForEach(options.orchestrators) { Text($0.displayName).tag($0.id) }
            if let provider, options.orchestrator(provider) == nil { Text(provider).tag(provider) }
        }
        .disabled(!editable || saving)
        .accessibilityIdentifier("dispatcher-model-\(role.id)-provider")
        let models = options.models(for: provider, keeping: pick?.model)
        Picker("Model", selection: Binding(get: { pick?.model ?? "default" }, set: { id in
            if id != (pick?.model ?? "default") { save { try await store.setDispatcherModels(.pick(role: role.id, model: id), hostID: hostID) } }
        })) {
            ForEach(models) { Text($0.label).tag($0.id) }
        }
        .companionModelPickerStyle(count: models.count)
        .disabled(!editable || saving)
        .accessibilityIdentifier("dispatcher-model-\(role.id)-model")
        let choices = effortChoices(current: pick?.effort)
        if !choices.isEmpty {
            Picker("Effort", selection: Binding<String?>(get: { pick?.effort }, set: { effort in
                guard effort != pick?.effort else { return }
                save { try await store.setDispatcherModels(.pick(role: role.id, effort: effort.map { .set($0) } ?? .cliDefault), hostID: hostID) }
            })) {
                Text("CLI default").tag(String?.none)
                ForEach(choices, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
            }
            .disabled(!editable || saving)
            .accessibilityIdentifier("dispatcher-model-\(role.id)-effort")
        }
    }

    private func effortChoices(current: String?) -> [String] {
        var choices = efforts
        if let current, !choices.contains(current) { choices.append(current) }
        return choices
    }

    // MARK: Name and look

    private func identitySection(_ settings: CompanionDispatcherSettings) -> some View {
        let identity = settings.identity
        return Section {
            LabeledContent("Name") {
                TextField("Name", text: $drafts.name.text)
                    .multilineTextAlignment(.trailing).autocorrectionDisabled().submitLabel(.done)
                    .onSubmit {
                        let name = String(drafts.name.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(identity.maxNameLength))
                        if name.isEmpty || name.utf8.elementsEqual(identity.name.utf8) { drafts.name.receive(identity.name, replacing: true) }
                        else { save(.name) { try await store.updateDispatcher(.init(name: name), hostID: hostID) } }
                    }
                    .disabled(!identity.nameEditable || saving)
                    .accessibilityIdentifier("dispatcher-name")
            }
            if drafts.name.hasConflict { conflictNotice("name", id: "name") }
            if !options.colors.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Color")
                    CompanionColorSwatches(colors: options.colors,
                                           selection: Binding(get: { identity.color ?? "" }, set: { color in
                                               if color != identity.color { save { try await store.updateDispatcher(.init(color: color), hostID: hostID) } }
                                           }),
                                           disabled: !identity.colorEditable || saving)
                }
            }
            LabeledContent("Emoji") {
                HStack {
                    TextField("None", text: $drafts.emoji.text)
                        .multilineTextAlignment(.trailing).submitLabel(.done)
                        .onSubmit {
                            let emoji = drafts.emoji.text.trimmingCharacters(in: .whitespaces)
                            guard !emoji.utf8.elementsEqual((identity.emoji ?? "").utf8) else { return }
                            guard emoji.utf16.count <= 16 else { drafts.emoji.receive(identity.emoji ?? "", replacing: true); saveError = "Use a shorter emoji."; return }
                            save(.emoji) { try await store.updateDispatcher(.init(emoji: emoji.isEmpty ? .clear : .set(emoji)), hostID: hostID) }
                        }
                        .accessibilityIdentifier("dispatcher-emoji")
                    if identity.emoji != nil {
                        Button("Clear emoji", systemImage: "xmark.circle.fill") { save(.emoji) { try await store.updateDispatcher(.init(emoji: .clear), hostID: hostID) } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(Color(palette.secondaryLabel))
                    }
                }
                .disabled(!identity.emojiEditable || saving)
            }
            if drafts.emoji.hasConflict { conflictNotice("emoji", id: "emoji") }
        } header: { Text("Name and look") } footer: {
            if identity.hasImageIcon { Text("It has an image icon. Setting an emoji replaces it.") }
        }
    }

    // MARK: Personality

    private func personalitySection(_ personality: CompanionDispatcherSettings.Personality) -> some View {
        Section {
            Picker("Personality", selection: Binding(get: { personality.preset ?? "custom" }, set: { preset in
                if preset != personality.preset {
                    save(.personality) { try await store.updateDispatcher(.init(personality: .init(preset: preset)), hostID: hostID) }
                }
            })) {
                ForEach(personality.presets) { Text($0.label).tag($0.id) }
            }
            .disabled(!personality.editable || saving)
            .accessibilityIdentifier("dispatcher-personality")
            if let description = personality.selected?.description {
                Text(description).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
            }
            TextField("What it's told about how to sound", text: $drafts.personality.text, axis: .vertical)
                .lineLimit(3...8)
                .disabled(!personality.editable || saving)
                .accessibilityIdentifier("dispatcher-personality-text")
            if drafts.personality.hasConflict { conflictNotice("personality", id: "personality") }
            if !drafts.personality.text.utf8.elementsEqual(personality.text.utf8) {
                let text = String(drafts.personality.text.prefix(personality.maxLength))
                HStack {
                    Button("Revert") { drafts.personality.receive(personality.text, replacing: true) }.buttonStyle(.borderless)
                    Spacer()
                    Button("Save personality") { save(.personality) { try await store.updateDispatcher(.init(personality: .init(text: text)), hostID: hostID) } }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("dispatcher-personality-save")
                }
                .disabled(saving)
            }
        } header: { Text("Personality") } footer: {
            Text("Used from the next time it starts.")
        }
    }

    // MARK: Usage

    private func usageSection(_ usage: CompanionDispatcherSettings.Usage) -> some View {
        Section("Usage") {
            usageRow(CompanionDispatcherSettings.conversationsLabel, usage.conversations, id: "conversations")
            usageRow(CompanionDispatcherSettings.backgroundLabel, usage.background, id: "background")
        }
    }

    private func usageRow(_ label: String, _ split: CompanionDispatcherSettings.UsageSplit?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label, value: Self.usageSummary(split))
            if let split, split.turnsWithoutUsage > 0 {
                Text("\(split.turnsWithoutUsage) \(split.turnsWithoutUsage == 1 ? "turn" : "turns") reported no usage.")
                    .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dispatcher-usage-\(id)")
    }

    /// "4 turns · 188,400 tokens · ~$0.42", or "None yet".
    static func usageSummary(_ split: CompanionDispatcherSettings.UsageSplit?) -> String {
        guard let split, split.turns > 0 else { return CompanionDispatcherSettings.noUsage }
        var parts = ["\(split.turns) \(split.turns == 1 ? "turn" : "turns")"]
        if split.tokens > 0 { parts.append("\(split.tokens.formatted()) tokens") }
        if let cost = split.costUSD {
            parts.append((split.costIsEstimate ? "~" : "") + cost.formatted(.currency(code: "USD")))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Resets

    private func resetsSection(_ settings: CompanionDispatcherSettings) -> some View {
        Section {
            Button("Clear chat", role: .destructive) { Task { await store.askDispatcherReset(.clearChat, hostID: hostID) } }
                .disabled(resetting || settings.clearChat.expectedState == nil)
                .accessibilityIdentifier("dispatcher-clear-chat")
            Button("Forget everything", role: .destructive) { Task { await store.askDispatcherReset(.forgetEverything, hostID: hostID) } }
                .disabled(resetting || settings.forgetEverything.expectedState == nil)
                .accessibilityIdentifier("dispatcher-forget-everything")
            if resetting { ProgressView().frame(maxWidth: .infinity) }
            if let notice = store.dispatcherResetNotices[hostID] {
                Text(notice).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    .accessibilityIdentifier("dispatcher-reset-notice")
            }
        } header: { Text("Start over") } footer: {
            Text("Clear chat starts its conversation over; it keeps its memory. Forget everything clears its memory and can’t be undone; its chat stays. Each asks first.")
        }
        // On the section with the buttons: a Form doesn't keep sections scrolled out of view, nor what they present.
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { store.cancelDispatcherReset() } }),
               presenting: prompt) { prompt in
            Button(prompt.reset.action, role: .destructive) { Task { await store.confirmDispatcherReset(prompt) } }
            Button("Cancel", role: .cancel) { store.cancelDispatcherReset() }
        } message: { prompt in Text(prompt.message) }
    }

    // MARK: Saving

    private func conflictNotice(_ field: String, id: String) -> some View {
        Label("The \(field) changed on the desktop. Your unsaved edit is kept.", systemImage: "info.circle")
            .font(.caption).foregroundStyle(Color(palette.secondaryLabel))
            .accessibilityIdentifier("dispatcher-\(id)-changed")
    }

    private func save(_ field: CompanionDispatcherSettingsDrafts.Field? = nil,
                      _ change: @escaping () async throws -> CompanionDispatcherSettings) {
        guard !saving else { return }
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            do { drafts.receive(try await change(), saved: field) }
            catch {
                saveError = error.localizedDescription
                // Revert only the refused field, not other pending edits.
                if let settings { drafts.receive(settings, saved: field) }
                await reload()
            }
        }
    }
}
