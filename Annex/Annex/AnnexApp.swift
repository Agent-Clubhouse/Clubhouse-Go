import SwiftUI
import ClubhouseTransport

@main
struct ClubhouseGoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--diagnostics-ui-testing") {
                NavigationStack { CompanionDiagnosticsView() }
            } else if ProcessInfo.processInfo.arguments.contains("--framebriar-shake-ui-testing") {
                FramebriarShakePreview()
            } else if ProcessInfo.processInfo.arguments.contains("--companion-preview") {
                CompanionPreviewRoot()
            } else {
                CompanionAppRoot()
            }
            #else
            CompanionAppRoot()
            #endif
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { AnnexTelemetry.shared.record(.foreground) }
            if newPhase == .background { AnnexTelemetry.shared.record(.background) }
        }
    }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--diagnostics-ui-testing") {
            UserDefaults.standard.removeObject(forKey: AnnexDiagnosticSettings.preferenceKey)
        }
        #endif
        _ = AnnexDiagnosticSettings.shared
        AnnexTelemetry.shared.record(.appLaunch)
    }
}
