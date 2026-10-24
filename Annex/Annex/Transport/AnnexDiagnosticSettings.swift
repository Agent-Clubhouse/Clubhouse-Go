import Foundation
import Observation

nonisolated public enum AnnexDiagnosticCaptureMode: String, CaseIterable, Codable, Sendable {
    case off, session, always
    public var label: String {
        switch self { case .off: "Off"; case .session: "This session"; case .always: "Always" }
    }
}

/// Only Always is persisted. This session expires on process restart. No mode
/// enables a remote exporter or persists trace contents.
@MainActor @Observable public final class AnnexDiagnosticSettings {
    public static let shared = AnnexDiagnosticSettings()
    public static let preferenceKey = "diagnostics.captureMode.v1"
    public private(set) var mode: AnnexDiagnosticCaptureMode
    private let defaults: UserDefaults
    private let telemetry: AnnexTelemetry
    public init(defaults: UserDefaults = .standard, telemetry: AnnexTelemetry = .shared) {
        self.defaults = defaults; self.telemetry = telemetry
        mode = defaults.string(forKey: Self.preferenceKey) == AnnexDiagnosticCaptureMode.always.rawValue ? .always : .off
        telemetry.setEnabled(mode != .off)
    }
    public func select(_ mode: AnnexDiagnosticCaptureMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        defaults.set(mode == .always ? "always" : "off", forKey: Self.preferenceKey)
        telemetry.setEnabled(mode != .off)
        if mode != .off { telemetry.record(.settings) }
    }
}
