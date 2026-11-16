import SwiftUI
import FramebriarUI
import ClubhouseTransport

/// The production and preview sheets use the same sections and navigation destinations.
struct CompanionSettingsSections: View {
    @Bindable var store: CompanionStore
    @Bindable var preferences: CompanionPreferences
    var feedback: FeedbackModel?
    var initialCapture: CompanionFeedbackSettingsCapture?
    var exporter: AnnexOTLPExporter?
    var sessionHosts: Set<String> = []
    var removingHostID: String?
    var operationError: String? = nil
    var pair: () -> Void
    var forget: (CompanionHost) -> Void
    var endSession: (CompanionHost) -> Void = { _ in }

    var body: some View {
        Section("Desktops") {
            ForEach(store.hosts) { host in
                NavigationLink {
                    CompanionSettingsDesktopPage(store: store, hostID: host.id,
                        isSessionOnly: sessionHosts.contains(host.id), removing: removingHostID == host.id,
                        operationError: operationError,
                        forget: { forget(host) }, endSession: { endSession(host) })
                } label: {
                    CompanionSettingsRowLabel(host.name, symbol: "desktopcomputer",
                        tone: host.connection.canOperate ? .accent : .secondary, value: host.connection.label)
                }
                .disabled(removingHostID == host.id)
                .accessibilityIdentifier("settings-desktop-\(host.id)")
            }
            Button {
                CompanionUIActions.record(.connectDesktop, on: .settings)
                pair()
            } label: {
                CompanionSettingsRowLabel("Pair another desktop", symbol: "plus", tone: .accent)
            }.accessibilityIdentifier("settings-pair-desktop")
        }
        Section("Agents") {
            CompanionPlanLimitsLink(store: store, settingsRows: true)
            CompanionHelperPresetLinks(store: store, settingsRows: true)
            let hosts = store.hosts.filter { $0.dispatcher != nil }
            ForEach(hosts) { host in
                CompanionDispatcherSwitch(store: store, hostID: host.id,
                    label: hosts.count > 1 || store.hosts.count > 1 ? "\(host.dispatcherDisplayName) on \(host.name)" : nil,
                    settingsRow: true)
            }
            if store.hosts.isEmpty { Text("Pair a desktop to manage agents.").foregroundStyle(.secondary) }
        }
        Section("This phone") {
            NavigationLink {
                CompanionIdleProjectSettings(store: store, preferences: preferences)
            } label: {
                CompanionSettingsRowLabel("Fold idle projects", symbol: "moon", tone: .secondary,
                    value: preferences.idleDays == 0 ? "Never" : "After \(preferences.idleDays) days")
            }.accessibilityIdentifier("settings-idle-projects")
            NavigationLink {
                Form {
                    Section {
                        CompanionDeviceNameField(preferences: preferences)
                    } footer: {
                        Text(CompanionDeviceNameField.footer + " Desktops paired before a change keep the old name until you pair again.")
                    }
                }.navigationTitle("Name on desktops").navigationBarTitleDisplayMode(.inline)
            } label: {
                CompanionSettingsRowLabel("Name on desktops", symbol: "iphone", tone: .secondary,
                    value: preferences.deviceName.isEmpty ? preferences.systemDeviceName : preferences.deviceName)
            }.accessibilityIdentifier("settings-phone-name")
        }
        CompanionFeedbackSettings(model: feedback, initialCapture: initialCapture, compact: true)
        Section("Advanced") {
            NavigationLink { CompanionDiagnosticsView(exporter: exporter) } label: {
                CompanionSettingsRowLabel("Connection diagnostics", symbol: "waveform.path.ecg", tone: .secondary)
            }.accessibilityIdentifier("settings-connection-diagnostics")
            NavigationLink {
                Form {
                    Section {
                        Label("Direct connection", systemImage: "network")
                        Text("Connect over the same local network or a direct Tailscale address. Your agents keep running on your desktop when you leave the app.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.navigationTitle("Direct connection").navigationBarTitleDisplayMode(.inline)
            } label: {
                CompanionSettingsRowLabel("Direct connection", symbol: "network", tone: .info)
            }
        }
    }
}

private struct CompanionIdleProjectSettings: View {
    @Bindable var store: CompanionStore
    @Bindable var preferences: CompanionPreferences
    var body: some View {
        Form {
            Section {
                Picker("Fold idle projects after", selection: Binding(get: { preferences.idleDays }, set: {
                    if $0 != preferences.idleDays { CompanionUIActions.record(.selectBehavior, on: .settings) }
                    preferences.idleDays = $0
                })) {
                    ForEach(CompanionIdleRule.dayChoices, id: \.self) { days in
                        Text(days == 0 ? "Never" : "\(days) days").tag(days)
                    }
                }.pickerStyle(.inline)
            } footer: {
                let shared = store.hosts.filter(\.sharesProjectState).map(\.name)
                Text("Unpinned projects with no running agent and no activity for this long fold into one idle section. Kept on this phone."
                    + (shared.isEmpty ? "" : " \(shared.formatted(.list(type: .and))) \(shared.count == 1 ? "shares its" : "share their") pins and idle projects, and \(shared.count == 1 ? "uses its" : "use their") own setting."))
            }
        }.navigationTitle("Fold idle projects").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CompanionSettingsDesktopPage: View {
    @Bindable var store: CompanionStore
    let hostID: String
    var isSessionOnly: Bool
    var removing: Bool
    var operationError: String?
    var forget: () -> Void
    var endSession: () -> Void
    private var host: CompanionHost? { store.hosts.first { $0.id == hostID } }
    var body: some View {
        List {
            if let operationError {
                Section { Text(operationError).foregroundStyle(.red) }
            }
            if let host {
                Section {
                    CompanionSettingsRowLabel(host.name, symbol: "desktopcomputer", tone: .accent,
                        value: host.connection.label)
                    Text(host.endpoint).font(.subheadline).textSelection(.enabled)
                    if case .failed(let message) = host.connection {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(isSessionOnly ? "Session-only pairing" : "Remembered desktop")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { CompanionAppUpdateLink(store: store, host: host, settingsRow: true) }
                CompanionDesktopConnectionActions(host: host, isSessionOnly: isSessionOnly,
                    retry: { Task { await store.reconnect(hostID: hostID) } }, forget: forget, endSession: endSession)
            } else {
                ContentUnavailableView("Desktop removed", systemImage: "desktopcomputer")
            }
        }
        .disabled(removing)
        .navigationTitle(host?.name ?? "Desktop")
        .navigationBarTitleDisplayMode(.inline)
        .companionTelemetryScreen(.desktopSettings)
        .accessibilityIdentifier("settings-desktop-page")
    }
}

/// Decorative tiles do not add another VoiceOver label. Text wraps at accessibility sizes.
struct CompanionSettingsRowLabel: View {
    enum Tone { case accent, success, warning, info, secondary, error, feedback }
    let title: String
    let symbol: String
    var tone: Tone = .accent
    var value: String?
    @Environment(\.companionPalette) private var palette
    @Environment(\.dynamicTypeSize) private var textSize
    init(_ title: String, symbol: String, tone: Tone = .accent, value: String? = nil) {
        self.title = title; self.symbol = symbol; self.tone = tone; self.value = value
    }
    private var tile: CompanionRGB {
        switch tone {
        case .accent: palette.tint
        case .success: palette.success
        case .warning: palette.warning
        case .info: palette.info
        case .secondary: palette.secondaryLabel
        case .error, .feedback: palette.error
        }
    }
    private var titleColor: CompanionRGB {
        if case .error = tone { return palette.error }
        return palette.label
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(CompanionPalette.glyph(on: tile)))
                .frame(width: 30, height: 30).background(Color(tile), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(Color(titleColor))
                    if let value { Text(value).font(.subheadline).foregroundStyle(Color(palette.secondaryLabel)) }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(title).foregroundStyle(Color(titleColor)).fixedSize(horizontal: false, vertical: true)
                if let value {
                    Spacer(minLength: 8)
                    Text(value).foregroundStyle(Color(palette.secondaryLabel)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(minHeight: 44).accessibilityElement(children: .combine)
    }
}
