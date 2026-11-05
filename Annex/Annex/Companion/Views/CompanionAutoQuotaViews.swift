import SwiftUI
import ClubhouseTransport

/// Only the scope on this page is changed. The desktop supplies effective policy and all blocking reasons.
struct CompanionHelperAutoSection: View {
    @Bindable var store: CompanionStore
    @Bindable var screen: CompanionHelperPresetsScreen
    let hostID: String
    let projectID: String?
    let agentID: String?
    let policy: CompanionHelperAuto
    private var scopeID: String { agentID != nil ? "agent" : projectID != nil ? "project" : "app" }
    private var host: CompanionHost? { store.hosts.first { $0.id == hostID } }
    private var choices: [CompanionHelperAuto.Value] {
        guard let scope = policy.scopes[scopeID] else { return [] }
        switch scopeID {
        case "app": return [.enabled(true), .enabled(false)]
        case "agent": return [.enabled(true), .enabled(false), .inherit]
        default: return scope.choices
        }
    }
    private var isReportOnly: Bool {
        guard let agentID, let target = host?.allAgents.first(where: { $0.id.agentID == agentID })?.id else { return false }
        return store.isMCPReportOnly(target)
    }
    private var canEdit: Bool {
        host?.connection.canOperate == true && !screen.saving && policy.scopes[scopeID]?.editable == true
            && host?.helperRouting?.scopes.contains(scopeID) == true
            && (scopeID == "agent" ? host?.canEditSettings == true && host?.canOrchestrate == true : host?.canEditHelperPresets == true)
    }
    var body: some View {
        Section("Auto provider") {
            LabeledContent("Effective", value: policy.effective ? "On" : "Off").accessibilityIdentifier("helper-auto-effective")
            Text(policy.sourceText(labels: screen.settings?.labels ?? [:])).accessibilityIdentifier("helper-auto-source")
            if let reason = policy.reasonText(labels: screen.settings?.labels ?? [:]) {
                Text(reason).accessibilityIdentifier("helper-auto-reason")
            }
            ForEach(["app", "project", "persona", "agent"], id: \.self) { id in
                if let scope = policy.scopes[id] {
                    LabeledContent(id.capitalized, value: valueText(scope.value, scope: id))
                        .accessibilityIdentifier("helper-auto-scope-\(id)")
                }
            }
            if isReportOnly { Text(CompanionOrchestration.reportOnlyHelp) }
            if policy.scopes[scopeID]?.editable == true {
                ForEach(choices.filter { !isReportOnly || $0 != .enabled(true) }, id: \.self) { value in
                    Button(valueText(value, scope: scopeID)) { change(value) }
                        .disabled(!canEdit || value == policy.scopes[scopeID]?.value || (value == .enabled(true) && policy.reason == "mcp_off"))
                        .accessibilityIdentifier("helper-auto-change-\(choiceID(value))")
                }
            }
        }
    }
    private func choiceID(_ value: CompanionHelperAuto.Value) -> String {
        switch value { case .enabled(true): "on"; case .enabled(false), .off: "off"; case .inherit: "inherit" }
    }
    private func valueText(_ value: CompanionHelperAuto.Value, scope: String) -> String {
        switch value {
        case .enabled(let on): on ? "On" : "Off"
        case .off: "Off"
        case .inherit: scope == "agent" ? "Follow app" : "No override"
        }
    }
    private func change(_ value: CompanionHelperAuto.Value) {
        guard canEdit else { return }
        Task {
            await screen.save { revision in
                if let agentID, let target = host?.allAgents.first(where: { $0.id.agentID == agentID })?.id {
                    let field: CompanionOrchestrationChange.Field<Bool>
                    switch value { case .enabled(let on): field = .set(on); case .inherit: field = .clear; case .off: field = .set(false) }
                    _ = try await store.updateSettings(.init(orchestration: .init(autoHelpers: field)), target: target)
                    // agent.update has agent settings, not a scoped routing page. Read the authoritative outcome once.
                    return try await store.helperRouting(hostID: hostID, agentID: agentID)
                }
                let wireValue: AnnexHelperRoutingUpdate.AutoValue
                switch value { case .enabled(let on): wireValue = .enabled(on); case .off: wireValue = .off; case .inherit: wireValue = .inherit }
                return try await store.updateHelperRouting(.init(revision: revision, scope: scopeID, projectId: projectID, auto: wireValue), hostID: hostID)
            }
        }
    }
}

/// A reading's age uses the desktop clock plus continuous elapsed time, including time the phone was suspended.
struct CompanionQuotaView: View {
    let quota: CompanionHelperQuota
    let labels: CompanionHelperRouting.Labels
    var serverTime: Date? = nil
    var receivedAt: ContinuousClock.Instant? = nil
    var showsProgress = false
    var showsReadingDate = true
    private func label(_ family: String, _ code: String) -> String { CompanionHelperRouting.label(labels, family: family, code: code) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label("quota", quota.state)).foregroundStyle(stateColor).accessibilityIdentifier("helper-quota-state-\(quota.state)")
            if let reason = quota.unknownReason { Text(label("unknown", reason)).font(.subheadline) }
            if !showsProgress {
                if let limiting = quota.limitingWindow { Text(label("window", limiting)).font(.subheadline) }
                if let resetsAt = quota.resetsAt { resetText(resetsAt) }
            }
            if let weekly = quota.weekly { window(weekly, name: label("window", "weekly")) }
            else if showsProgress { Text("\(label("window", "weekly")): \(label("quota", "unknown"))").font(.subheadline) }
            if let fiveHour = quota.fiveHour { window(fiveHour, name: label("window", "fiveHour"), secondary: showsProgress) }
            ForEach(quota.unreadableWindows.filter { $0 != "weekly" && $0 != "fiveHour" }, id: \.self) { code in
                Text("\(label("window", code)): \(label("quota", "unknown"))").font(.subheadline)
            }
            if !quota.modelWindows.isEmpty {
                if showsProgress {
                    DisclosureGroup("Limits for individual models") { modelWindows }
                        .font(.subheadline)
                } else {
                    Text("Limits for individual models").font(.caption).foregroundStyle(.secondary)
                    modelWindows
                }
            }
            if let asOf = quota.asOf, showsReadingDate || receivedAt == nil || serverTime == nil {
                Text("Read at \(asOf.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            if let receivedAt {
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    if let age = CompanionHelperQuota.age(asOf: quota.asOf, serverTime: serverTime, elapsed: receivedAt.duration(to: .now)) {
                        Text(ageText(age)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("helper-quota-age")
                    } else { Text("Reading age unavailable").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: showsProgress)
        .accessibilityElement(children: showsProgress ? .combine : .contain)
    }
    private var stateColor: Color {
        guard showsProgress else { return .primary }
        return warningColor ?? .primary
    }
    /// Quota tiers belong to the desktop; the phone does not infer tiers from percentages.
    private var warningColor: Color? {
        switch quota.state { case "exhausted": return .red; case "near_limit", "low": return .orange; default: return nil }
    }
    private var modelWindows: some View {
        ForEach(Array(quota.modelWindows.enumerated()), id: \.offset) { _, item in window(item.window, name: item.name) }
    }
    private func ageText(_ age: Double) -> String {
        if age < 60 { return "Read less than a minute ago" }
        let minutes = Int(min(age / 60, Double(Int.max / 2)))
        return "Read \(minutes) minutes ago" + (age > 900 ? " · over 15 minutes old" : "")
    }
    private func window(_ window: CompanionHelperQuota.Window, name: String, secondary: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(name): \(window.usedPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "% used" } ?? label("quota", "unknown"))").font(secondary ? .caption : .subheadline)
            if showsProgress, let percent = window.usedPercent {
                ProgressView(value: percent, total: 100)
                    .controlSize(secondary ? .small : .regular)
                    .tint(warningColor ?? .accentColor)
                    .accessibilityLabel(name)
                    .accessibilityValue("\(percent.formatted(.number.precision(.fractionLength(0...1))))% used")
            }
            if let resetsAt = window.resetsAt { resetText(resetsAt) }
        }
        .accessibilityElement(children: .combine)
    }
    private func resetText(_ date: Date) -> some View {
        Text("Resets \(date.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CompanionHelperWarningView: View {
    let warning: CompanionHelperStartWarning
    let phase: String
    var message: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(phase).font(.caption).foregroundStyle(.secondary)
            Text(message ?? warning.message).font(.subheadline)
            Text(warning.knownAtText).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A saved decision is historical. Never refresh it or turn diagnostic quotaBasis into a health label.
struct CompanionHelperDecisionDetails: View {
    let routing: CompanionHelperRoutingDecision
    let labels: CompanionHelperRouting.Labels
    let showsQuota: Bool
    var body: some View {
        if let decidedAt = routing.decidedAt { Text("Decided \(decidedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        if let warning = routing.warning {
            CompanionHelperWarningView(warning: warning, phase: "Warning saved with this start", message: routing.displayWarning)
                .accessibilityIdentifier("helper-routing-warning")
        }
        ForEach(routing.skipped.keys.sorted(), id: \.self) { provider in
            Text("\(provider): \(CompanionHelperRouting.label(labels, family: "skipped", code: routing.skipped[provider] ?? ""))")
                .font(.subheadline).accessibilityIdentifier("helper-routing-skipped-\(provider)")
        }
        ForEach(routing.load.keys.sorted(), id: \.self) { provider in
            LabeledContent(provider + " helpers at decision", value: String(routing.load[provider] ?? 0)).font(.subheadline)
        }
        if showsQuota {
            ForEach(routing.quota.keys.sorted(), id: \.self) { provider in
                if let quota = routing.quota[provider] {
                    DisclosureGroup(provider + " limit at decision") { CompanionQuotaView(quota: quota, labels: labels) }
                }
            }
        }
    }
}

struct CompanionHelperStartAlerts: ViewModifier {
    @Bindable var store: CompanionStore
    func body(content: Content) -> some View {
        content
            .alert("Helper couldn't start", isPresented: Binding(get: { store.helperRequestNotice != nil }, set: { if !$0 { store.helperRequestNotice = nil } })) {
                Button("OK", role: .cancel) { }
            } message: { Text(store.helperRequestNotice ?? "") }
            .alert("Helper start warning", isPresented: Binding(get: { store.helperStartWarning != nil }, set: { if !$0 { store.helperStartWarning = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(store.helperStartWarning.map { "At approval: \($0.message)\n\($0.knownAtText)" } ?? "")
            }
    }
}
