import SwiftUI
import ClubhouseTransport

/// Shared whole-session action. A stop acknowledgment is deliberately not presented as sleep completion.
struct CompanionSleepAction: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    var title = "Sleep agent"
    var confirm: () -> Void = {}

    var body: some View {
        if store.sleepRequests.contains(target) {
            Label("Sleep requested. Waiting for the desktop to confirm.", systemImage: "moon")
                .accessibilityIdentifier("agent-sleep-pending")
            Button("Check sleep status", systemImage: "arrow.clockwise") { Task { await store.refreshSleepState(target) } }
                .disabled(store.sleepRefreshes.contains(target) || store.host(for: target)?.connection.canOperate != true)
                .accessibilityIdentifier("agent-sleep-refresh")
        } else if store.canSleep(target) {
            Button(title, systemImage: "moon", action: confirm)
                .accessibilityIdentifier("agent-sleep")
        }
    }
}

struct CompanionSleepConfirmation: ViewModifier {
    let store: CompanionStore
    let target: CompanionTarget
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        content.confirmationDialog("Sleep \(store.agent(for: target)?.name ?? "agent")?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Sleep agent", role: .destructive) { Task { await store.sleepAgent(target) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops the agent's session on \(store.host(for: target)?.name ?? "the desktop"). Wait for Sleeping before changing its provider. Starting again is a separate action.")
        }
    }
}

/// Non-menu surfaces own their confirmation here; a menu must present it from the enclosing screen.
struct CompanionSleepControl: View {
    let store: CompanionStore
    let target: CompanionTarget
    var title = "Sleep agent"
    @State private var confirming = false
    var body: some View {
        CompanionSleepAction(store: store, target: target, title: title) { confirming = true }
            .modifier(CompanionSleepConfirmation(store: store, target: target, isPresented: $confirming))
    }
}

/// Opens an agent's details, and a durable agent's settings, from anywhere: the chat header, or an agent row's long-press menu.
struct CompanionAgentSettingsAction {
    var canOpen: @MainActor (CompanionTarget) -> Bool
    var open: @MainActor (CompanionTarget) -> Void
    /// Agent details, for any agent. Nil hides the menu item.
    var openDetails: (@MainActor (CompanionTarget) -> Void)?
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
/// Agent details, and Agent settings when its desktop offers them.
struct CompanionAgentMenu: ViewModifier {
    let target: CompanionTarget
    @Environment(\.companionAgentSettings) private var settings
    @Environment(\.companionAgentWake) private var wake
    @Environment(\.companionTerminal) private var terminal
    func body(content: Content) -> some View {
        let choices = wake?.choices(target) ?? []
        let hasSettingsItems = settings.map { $0.openDetails != nil || $0.canOpen(target) } ?? false
        let hasTerminal = terminal?.availability(.agentShell(target)).isShown == true
        if hasSettingsItems || !choices.isEmpty || hasTerminal {
            content.contextMenu {
                if let wake {
                    ForEach(choices) { choice in
                        Button(choice.label, systemImage: choice.systemImage) { wake.wake(target, choice) }
                    }
                }
                if let settings { CompanionAgentMenuItems(target: target, actions: settings) }
                CompanionTerminalMenuItem(scope: .agentShell(target))
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
            if index == 0 { button.buttonStyle(.glassProminent).companionProminentLabel() } else { button.buttonStyle(.bordered).buttonBorderShape(.capsule) }
        }
    }
}

/// Agent details and Agent settings, for the long-press menu and the chat header's menu.
struct CompanionAgentMenuItems: View {
    let target: CompanionTarget
    let actions: CompanionAgentSettingsAction
    var body: some View {
        if let openDetails = actions.openDetails {
            Button("Agent details", systemImage: "info.circle") { openDetails(target) }
        }
        if actions.canOpen(target) {
            Button("Agent settings", systemImage: "slider.horizontal.3") { actions.open(target) }
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

/// A durable agent's settings in a sheet of their own.
struct CompanionAgentSettingsSheet: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    var focusContext = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CompanionAgentSettingsForm(store: store, target: target, focusContext: focusContext)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A durable agent's settings, as the desktop's Details → Settings card and the General page of Agent settings.
/// Every change saves at once. Settings read at spawn wait for the agent to sleep; auto-sleep changes any time.
/// Shown in its own sheet, or pushed from Agent details.
struct CompanionAgentSettingsForm: View {
    @Bindable var store: CompanionStore
    let target: CompanionTarget
    var focusContext = false
    @Environment(\.companionPalette) private var palette
    @State private var settings: CompanionAgentSettings?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saving = false
    @State private var nameDraft = ""
    @State private var emojiDraft = ""
    @State private var confirmFreeAgentMode = false
    @State private var pendingOrchestrator: String?
    @State private var confirmOrchestratorChange = false

    private var agent: CompanionAgent? { store.agent(for: target) }
    /// The Dispatcher has only the settings the desktop lets you change: no identity, persona, Clubhouse mode or orchestration.
    private var isDispatcher: Bool { store.isDispatcher(target) }
    /// Re-read when the snapshot changes what the agent is doing, its name or its orchestration, as the desktop broadcasts after an update.
    private var refreshKey: String {
        let sleeping = agent?.isSleepingOnDesktop
        let lifecycle = sleeping == true ? "asleep" : sleeping == false ? "awake" : "unknown"
        return [agent?.status.rawValue ?? "", agent?.name ?? "", store.host(for: target)?.connection.label ?? "",
         agent?.orchestration.map { "\($0)" } ?? "", agent?.parentAgentID ?? "",
         lifecycle].joined(separator: "|")
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if store.canSleep(target) || store.sleepRequests.contains(target) {
                    Section("Session") {
                        CompanionSleepControl(store: store, target: target)
                        if let error = store.operationErrors[target] { Text(error).foregroundStyle(.red) }
                    }
                } else if let error = store.operationErrors[target] {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let settings { form(settings).disabled(store.sleepRequests.contains(target)) }
                else if let loadError {
                    contextSection(nil)
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
            .task(id: refreshKey) { await load() }
            .task(id: settings != nil) {
                if focusContext, settings != nil { proxy.scrollTo("agent-context-section", anchor: .top) }
            }
            .confirmationDialog(CompanionFreeAgentMode.confirmTitle, isPresented: $confirmFreeAgentMode, titleVisibility: .visible) {
                Button("Turn on Free Agent Mode", role: .destructive) { save(.init(freeAgentMode: true)) }
            } message: { Text(CompanionFreeAgentMode.help) }
            .confirmationDialog("Change CLI?", isPresented: $confirmOrchestratorChange, titleVisibility: .visible) {
                Button("Change CLI", role: .destructive) {
                    if let pendingOrchestrator { save(.init(orchestrator: pendingOrchestrator)) }
                    pendingOrchestrator = nil
                }
                Button("Cancel", role: .cancel) { pendingOrchestrator = nil }
            } message: {
                if let pendingOrchestrator, let settings,
                   let warning = settings.orchestratorChangeWarning(to: pendingOrchestrator, agentName: settings.name.value) {
                    Text(warning)
                }
            }
        }
    }

    /// Current usage/report stays readable even if this desktop cannot load editable agent settings.
    @ViewBuilder private func contextSection(_ settings: CompanionAgentSettings?) -> some View {
        if settings?.contextWindow != nil || agent?.chatControls?.context != nil || agent?.contextUsage != nil {
            Section("Context") {
                if let context = settings?.contextWindow { contextWindow(context, sleeping: settings?.sleeping ?? false) }
                if let usage = agent?.contextUsage {
                    LabeledContent("Context used", value: "\(usage.used.formatted()) / \(usage.size.formatted()) tokens")
                }
                if let report = agent?.chatControls?.context {
                    VStack(alignment: .leading, spacing: 4) {
                        if !report.summary.isEmpty { Text(report.summary) }
                        if let note = report.note { Text(note) }
                    }
                    .font(.subheadline).foregroundStyle(Color(palette.secondaryLabel))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("companion-context-report")
                }
            }
            .id("agent-context-section")
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
            if let contextResetNotice = settings.contextWindowReset?.message {
                Label(contextResetNotice, systemImage: "info.circle").font(.subheadline)
                    .accessibilityIdentifier("agent-settings-context-reset-notice")
            }
        }

        contextSection(settings)

        if let routing = settings.routing, store.host(for: target)?.helperRouting != nil {
            Section("Helper routing") {
                if let summary = routing.summary { Text(summary).accessibilityIdentifier("helper-routing-summary") }
                Text(routing.reasonText(labels: store.host(for: target)?.helperRoutingLabels ?? [:]))
                    .accessibilityIdentifier("helper-routing-reason")
                if let fallback = routing.displayFallback { Text(fallback).font(.subheadline).foregroundStyle(.secondary) }
                CompanionHelperDecisionDetails(routing: routing, labels: store.host(for: target)?.helperRoutingLabels ?? [:], showsQuota: store.host(for: target)?.helperRouting?.quota == true)
            }
        }

        if let feature = store.host(for: target)?.helperRouting, feature.modes.contains("auto"), feature.scopes.contains("agent") {
            Section("Helpers") {
                NavigationLink("Auto provider and plan limits") { CompanionHelperPresetsView(store: store, hostID: target.hostID, agentID: target.agentID) }
                    .accessibilityIdentifier("agent-settings-helper-auto")
                if let effective = settings.orchestration?.autoHelpersEffective {
                    LabeledContent("Auto provider effective", value: effective ? "On" : "Off")
                }
            }
        }
        if isDispatcher {
            Section { CompanionDispatcherSwitch(store: store, hostID: target.hostID) }
        }

        if !isDispatcher {
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
        }

        Section {
            Menu {
                ForEach(orchestratorChoices(settings), id: \.id) { choice in
                    Button {
                        guard choice.available, choice.id != (settings.orchestrator.value ?? settings.resolvedOrchestrator) else { return }
                        if settings.orchestratorChangeWarning(to: choice.id, agentName: settings.name.value) != nil {
                            pendingOrchestrator = choice.id
                            confirmOrchestratorChange = true
                        } else { save(.init(orchestrator: choice.id)) }
                    } label: {
                        if choice.id == (settings.orchestrator.value ?? settings.resolvedOrchestrator) { Label(choice.label, systemImage: "checkmark") }
                        else { Text(choice.label) }
                    }
                    .disabled(!choice.available)
                }
            } label: {
                LabeledContent("Runs on", value: settings.orchestratorName)
            }
            .disabled(!settings.orchestrator.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-orchestrator")
            let models = settings.options.models(for: settings.orchestrator.value ?? settings.resolvedOrchestrator, keeping: settings.model.value)
            Picker("Model", selection: Binding(get: { settings.model.value }, set: { if $0 != settings.model.value { save(.init(model: $0)) } })) {
                ForEach(models) { Text($0.label).tag($0.id) }
            }
            .companionModelPickerStyle(count: models.count)
            .disabled(!settings.model.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-model")
            Picker("Runtime", selection: Binding(get: { settings.runtime.value }, set: { if $0 != settings.runtime.value { save(.init(runtime: $0)) } })) {
                Text("Provider default").tag("default")
                Text("Chat").tag("chat")
                Text("Terminal").tag("terminal")
            }
            .disabled(!settings.runtime.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-runtime")
            if !isDispatcher {
            Picker("Persona", selection: Binding(get: { settings.persona.value ?? "" },
                                                 set: { if $0 != (settings.persona.value ?? "") { save(.init(persona: $0.isEmpty ? .clear : .set($0))) } })) {
                Text("Project default").tag("")
                ForEach(settings.options.personas) { Text($0.name).tag($0.id) }
                if let current = settings.persona.value, !settings.options.personas.contains(where: { $0.id == current }) { Text(current).tag(current) }
            }
            .disabled(!settings.persona.canEdit(sleeping: sleeping) || saving)
            .accessibilityIdentifier("agent-settings-persona")
            }
        } header: { Text("Runtime") } footer: {
            Text(settings.runtime.editable == .never ? "Applied on the next wake. Chat isn't available for this CLI." : "Applied on the next wake.")
            Text("Sign-in and remaining quota aren't reported by this provider list.")
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
            if isDispatcher {
                // It lives outside every project, so there's no project mode to follow.
            } else if settings.clubhouseMode.editable != .never, let value = settings.clubhouseMode.value {
                Toggle("Clubhouse mode for this agent", isOn: Binding(get: { value }, set: { save(.init(clubhouseMode: $0)) }))
                    .disabled(!settings.clubhouseMode.canEdit(sleeping: sleeping) || saving)
                    .accessibilityIdentifier("agent-settings-clubhouse-mode")
            } else {
                LabeledContent("Clubhouse mode", value: clubhouseModeSummary(settings))
            }
            if canSetFreeAgentMode {
                Toggle(CompanionFreeAgentMode.title, isOn: Binding(get: { settings.freeAgentMode.value },
                                                                     set: { if $0 { confirmFreeAgentMode = true } else { save(.init(freeAgentMode: false)) } }))
                    .disabled(!settings.freeAgentMode.canEdit(sleeping: sleeping) || saving)
                    .accessibilityIdentifier("agent-settings-free-agent-mode")
            } else {
                LabeledContent("Free Agent Mode", value: settings.freeAgentMode.value ? "On" : "Off")
                    .accessibilityIdentifier("agent-settings-free-agent-mode")
            }
        } header: { Text("Access") } footer: {
            Text(freeAgentModeFooter(settings))
        }

        if let orchestration = orchestration(settings) {
            orchestrateSection(orchestration, name: settings.name.value, running: !sleeping,
                               isHelper: settings.parentAgentID != nil || agent?.parentAgentID != nil)
        }
    }

    /// Shared by durable agents and the Dispatcher. Choices belong to the returned provider/model settings.
    private func contextWindow(_ context: CompanionContextWindow, sleeping: Bool) -> some View {
        let canEdit = context.canEdit(sleeping: sleeping) && store.canEditSettings(target)
            && store.host(for: target)?.canSetContextWindow == true && !saving
        let canReset = context.canReset(sleeping: sleeping, isDispatcher: isDispatcher) && store.canEditSettings(target)
            && store.host(for: target)?.canSetContextWindow == true && !saving
        return VStack(alignment: .leading, spacing: 6) {
            Picker(context.displayLabel, selection: Binding<String?>(get: { context.value }, set: {
                if let change = context.change(to: $0) { save(change) }
            })) {
                Text(context.displayDefaultLabel).tag(String?.none)
                ForEach(context.choices) { choice in
                    Text(context.isSavedNotApplied && choice.id == context.value ? context.selectedLabel : choice.label).tag(Optional(choice.id))
                }
                if let value = context.value, !context.choices.contains(where: { $0.id == value }) {
                    Text(context.selectedLabel).tag(Optional(value)).disabled(true)
                }
            }
            .disabled(!canEdit)
            .accessibilityIdentifier("agent-settings-context-window")
            if let description = context.description {
                Text(description).font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
            }
            Text(context.applicationNote)
                .font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
            if let reason = context.availabilityReason {
                Text(reason).font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
                    .accessibilityIdentifier("agent-settings-context-window-reason")
            }
            if store.host(for: target)?.canSetContextWindow != true {
                Text("This desktop doesn't offer context setting changes from the phone.").font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
            }
            if let tokens = context.defaultTokens {
                Text("Default: \(tokens.formatted()) tokens").font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
            }
            if let maximum = context.maxTokens {
                Text("Maximum: \(maximum.formatted()) tokens").font(.footnote).foregroundStyle(Color(palette.secondaryLabel))
            }
            if let costNote = context.costNote { Text(costNote).font(.footnote).foregroundStyle(Color(palette.secondaryLabel)) }
            if let notice = context.notice { Text(notice).font(.footnote).foregroundStyle(Color(palette.secondaryLabel)) }
            if context.value != nil {
                Button("Reset to Default") { if let change = context.change(to: nil) { save(change) } }
                    .buttonStyle(.borderless)
                    .disabled(!canReset)
                    .accessibilityIdentifier("agent-settings-context-window-reset")
            }
        }
    }

    /// The desktop's Orchestrate card. It changes at any time, and is hidden on desktops without `orchestration` v1.
    @ViewBuilder private func orchestrateSection(_ policy: CompanionOrchestration, name: String, running: Bool, isHelper: Bool) -> some View {
        Section {
            if policy.mcpReportOnly {
                Text(CompanionOrchestration.reportOnlyHelp)
                    .accessibilityIdentifier("agent-settings-report-only")
            }
            Toggle("Let this agent orchestrate", isOn: Binding(get: { policy.orchestrate },
                                                               set: { save(.init(orchestration: .init(orchestrate: .set($0)))) }))
                .disabled(saving || !policy.canChangeMCPOption(current: policy.orchestrate))
                .accessibilityIdentifier("agent-settings-orchestrate")
            if policy.orchestrate && !policy.mcpReportOnly {
                Picker("Helpers get", selection: Binding(get: { policy.access },
                                                         set: { if $0 != policy.access { save(.init(orchestration: .init(access: .set($0)))) } })) {
                    ForEach(policy.accessChoices, id: \.self) { Text(CompanionOrchestration.accessLabel($0, agentName: name)).tag($0) }
                }
                .disabled(saving)
                .accessibilityIdentifier("agent-settings-orchestrate-access")
                Picker("Control", selection: Binding(get: { policy.control },
                                                     set: { if $0 != policy.control { save(.init(orchestration: .init(control: .set($0)))) } })) {
                    ForEach(policy.controlChoices, id: \.self) { Text(CompanionOrchestration.controlLabel($0)).tag($0) }
                }
                .disabled(saving)
                .accessibilityIdentifier("agent-settings-orchestrate-control")
                Stepper(value: Binding(get: { policy.maxHelpers },
                                       set: { if $0 != policy.maxHelpers { save(.init(orchestration: .init(maxHelpers: .set($0)))) } }),
                        in: policy.maxHelpersRange) {
                    LabeledContent("Helpers at once", value: "\(policy.maxHelpers)")
                }
                .disabled(saving)
                .accessibilityIdentifier("agent-settings-orchestrate-max-helpers")
            }
            if policy.sources["crossProjectHelpers"] != nil && (policy.orchestrate || !policy.hasFullMCP) {
                Toggle(isOn: Binding(get: { policy.crossProjectHelpers },
                                     set: { save(.init(orchestration: .init(crossProjectHelpers: .set($0)))) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cross-project helpers")
                        Text(CompanionOrchestration.crossProjectHelp).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    }
                }
                .disabled(saving || !policy.canChangeMCPOption(current: policy.crossProjectHelpers))
                .accessibilityLabel("Let \(name) start helpers in other projects")
                .accessibilityIdentifier("agent-settings-orchestrate-cross-project")
            }
            // Older desktops omit helper identity; keep showing their authoritative returned value.
            if policy.sources["connectToDispatcher"] != nil,
               (policy.mcpReportOnly && policy.connectToDispatcher) || (!isHelper && store.host(for: target)?.dispatcher?.enabled == true && store.host(for: target)?.dispatcher?.mcpOff == nil) {
                Toggle(isOn: Binding(get: { policy.connectToDispatcher },
                                     set: { save(.init(orchestration: .init(connectToDispatcher: .set($0)))) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect to Dispatcher")
                        Text(CompanionOrchestration.dispatcherHelp).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    }
                }
                .disabled(saving || !policy.canChangeMCPOption(current: policy.connectToDispatcher))
                .accessibilityLabel("Connect \(name) to the Dispatcher")
                .accessibilityIdentifier("agent-settings-orchestrate-dispatcher")
            }
        } header: { Text("Orchestrate") } footer: {
            if !policy.mcpReportOnly { Text(orchestrateFooter(policy, name: name, running: running)) }
        }
    }

    /// The desktop sends the policy with the settings; older settings routes leave it to the catalog.
    private func orchestration(_ settings: CompanionAgentSettings) -> CompanionOrchestration? {
        guard store.host(for: target)?.canOrchestrate == true, !isDispatcher else { return nil }
        return settings.orchestration ?? agent?.orchestration
    }

    /// The card's notes: what helpers get, what Control means, the cap, and when the tools appear.
    private func orchestrateFooter(_ policy: CompanionOrchestration, name: String, running: Bool) -> String {
        guard policy.hasFullMCP else { return CompanionOrchestration.mcpRequiredHelp }
        guard policy.orchestrate else { return CompanionOrchestration.offHelp(agentName: name) }
        var notes = [CompanionOrchestration.accessNote(agentName: name)]
        if let help = CompanionOrchestration.controlHelp(policy.control, agentName: name) { notes.append(help) }
        notes.append("Up to \(policy.maxHelpersCap) at once, your app-wide limit. Change it in Settings → Helpers on the desktop.")
        if !running { notes.append(CompanionOrchestration.nextStartNote(agentName: name)) }
        return notes.joined(separator: " ")
    }

    /// The desktop takes Free Agent Mode from a phone; older ones keep it for themselves.
    private var canSetFreeAgentMode: Bool { store.host(for: target)?.canSetFreeAgentMode == true }

    /// Why the toggle can't change, else the desktop's help text.
    private func freeAgentModeFooter(_ settings: CompanionAgentSettings) -> String {
        guard canSetFreeAgentMode else { return "Free Agent Mode can only be changed on the desktop." }
        if settings.freeAgentMode.editable == .never { return CompanionFreeAgentMode.unsupported }
        if settings.freeAgentMode.isLocked(sleeping: settings.sleeping) { return "\(CompanionAgentSettings.lockedHint). \(CompanionFreeAgentMode.help)" }
        return CompanionFreeAgentMode.help
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

    private func orchestratorChoices(_ settings: CompanionAgentSettings) -> [(id: String, label: String, available: Bool)] {
        var choices = settings.options.orchestrators.map {
            (id: $0.id, label: $0.available ? $0.displayName : "\($0.displayName) (\($0.unavailableReason ?? "Unavailable on this desktop"))", available: $0.available)
        }
        let current = settings.orchestrator.value ?? settings.resolvedOrchestrator
        if !choices.contains(where: { $0.id == current }) { choices.append((id: current, label: "\(current) (availability unknown)", available: false)) }
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
            do {
                var saved = try await store.updateSettings(change, target: target)
                // A result without the policy: show the change until the catalog catches up.
                if saved.orchestration == nil, let orchestration = change.orchestration, let current = settings.flatMap(self.orchestration) {
                    saved.orchestration = orchestration.applied(to: current)
                }
                apply(saved.keepingOptions(of: settings))
            }
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

/// The desktop's "Turn on Dispatcher" switch (Settings › Dispatcher), disabled with the reason when it can't be turned on here.
struct CompanionDispatcherSwitch: View {
    @Bindable var store: CompanionStore
    let hostID: String
    /// The desktop's name, when more than one is paired.
    var label: String?
    @Environment(\.companionPalette) private var palette

    var body: some View {
        if let host = store.hosts.first(where: { $0.id == hostID }), let dispatcher = host.dispatcher {
            let switching = store.dispatcherSwitching.contains(hostID)
            VStack(alignment: .leading, spacing: 6) {
                if dispatcher.mcpOff == nil {
                    Toggle(isOn: Binding(get: { dispatcher.enabled },
                                         set: { on in Task { await store.setDispatcher(enabled: on, hostID: hostID) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Turn on Dispatcher")
                            if let label { Text(label).font(.caption).foregroundStyle(Color(palette.secondaryLabel)) }
                        }
                    }
                    // Turning it off is always allowed; turning it on needs the desktop's flag and layout.
                    .disabled(switching || !host.connection.canOperate || !dispatcher.canToggle || (!dispatcher.enabled && dispatcher.turnOnBlocker != nil))
                    .accessibilityIdentifier("dispatcher-enabled-\(hostID)")
                }
                Text(note(dispatcher)).font(.caption).foregroundStyle(Color(palette.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dispatcher-enabled-note-\(hostID)")
                if let error = store.dispatcherErrors[hostID] {
                    Text(error).font(.caption).foregroundStyle(Color(palette.error)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("dispatcher-enabled-error-\(hostID)")
                }
            }
        }
    }

    private func note(_ dispatcher: CompanionDispatcher) -> String {
        if let note = dispatcher.statusNote { return note }
        if dispatcher.enabled { return CompanionDispatcher.offNote }
        return dispatcher.turnOnBlocker ?? "One app-wide agent that sends your orchestrators work and gets their reports."
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
