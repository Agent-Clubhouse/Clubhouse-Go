import SwiftUI
import ClubhouseTransport

private struct CompanionTelemetryScreenKey: EnvironmentKey {
    static let defaultValue: AnnexUIAction.Screen? = nil
}

extension EnvironmentValues {
    var companionTelemetryScreen: AnnexUIAction.Screen? {
        get { self[CompanionTelemetryScreenKey.self] }
        set { self[CompanionTelemetryScreenKey.self] = newValue }
    }
}

extension View {
    /// Shared row menus inherit their actual originating screen. An unadopted surface records no guessed screen.
    func companionTelemetryScreen(_ screen: AnnexUIAction.Screen) -> some View {
        environment(\.companionTelemetryScreen, screen)
    }
}

enum CompanionUIActions {
    static func record(_ control: AnnexUIAction.Control, on screen: AnnexUIAction.Screen?) {
        guard let screen else { return }
        AnnexTelemetry.shared.recordAction(screen: screen, control: control)
    }

    static func wake(_ choice: CompanionWakeChoice, on screen: AnnexUIAction.Screen?) {
        let control: AnnexUIAction.Control = switch choice {
        case .resume: .wakeAndResume
        case .newSession: .startNewSession
        case .wake: .wakeAgent
        }
        record(control, on: screen)
    }
}
