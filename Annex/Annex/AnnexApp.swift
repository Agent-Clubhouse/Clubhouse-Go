import SwiftUI
import ClubhouseTransport
import ClubhouseTransport

@main
struct ClubhouseGoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// The process owns clients and transports; reconnecting a scene only mounts another view.
    @State private var runtimeLifetime: CompanionStateLifetime<CompanionRuntime>

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--scene-runtime-testing") {
                CompanionSceneTestRoot(runtimeLifetime: runtimeLifetime)
            } else if ProcessInfo.processInfo.arguments.contains("--deinit-probe") {
                CompanionDeinitProbe()
            } else if ProcessInfo.processInfo.arguments.contains("--reading-restore-ui-testing") {
                CompanionReadingRestoreFixture()
            } else if ProcessInfo.processInfo.arguments.contains("--diagnostics-ui-testing") {
                NavigationStack { CompanionDiagnosticsView() }
            } else if ProcessInfo.processInfo.arguments.contains("--framebriar-shake-ui-testing") {
                FramebriarShakePreview()
            } else if ProcessInfo.processInfo.arguments.contains("--companion-preview") {
                CompanionPreviewRoot()
            } else {
                CompanionAppRoot(runtimeLifetime: runtimeLifetime)
            }
            #else
            CompanionAppRoot(runtimeLifetime: runtimeLifetime)
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { AnnexTelemetry.shared.record(.foreground) }
            if newPhase == .background { AnnexTelemetry.shared.record(.background) }
        }
    }

    init() {
        #if DEBUG
        let testMode = ProcessInfo.processInfo.environment["CLUBHOUSE_COMPANION_TEST_INVITATION"] != nil || (ProcessInfo.processInfo.arguments.contains("--scene-runtime-testing") || ProcessInfo.processInfo.arguments.contains("--companion-root-ui-testing"))
        _runtimeLifetime = State(initialValue: CompanionStateLifetime {
            // Lazy: previews/probes never reset the install or construct a feedback client.
            if !testMode { CompanionInstallReset.clearLeftoversIfFreshInstall() }
            return CompanionRuntime(registry: testMode ? AnnexTransportRegistry() : AnnexTransportRegistry(pairings: KeychainAnnexPairingStore()), persistsDrafts: !testMode)
        })
        #else
        _runtimeLifetime = State(initialValue: CompanionStateLifetime {
            CompanionInstallReset.clearLeftoversIfFreshInstall()
            return CompanionRuntime()
        })
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--diagnostics-ui-testing") {
            UserDefaults.standard.removeObject(forKey: AnnexDiagnosticSettings.preferenceKey)
        }
        // UI tests wait for the app to go idle after every gesture; UIKit transitions make each wait longer.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-fast") {
            UIView.setAnimationsEnabled(false)
        }
        CompanionShakeDiagnostics.install()
        #endif
        _ = AnnexDiagnosticSettings.shared
        AnnexTelemetry.shared.record(.appLaunch)
    }
}
