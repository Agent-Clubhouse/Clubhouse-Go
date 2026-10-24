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
    public private(set) var destination: AnnexOTLPConfiguration?
    public private(set) var remoteEnabled: Bool
    public private(set) var revision = UUID()
    private static let destinationKey = "diagnostics.otlpDestination.v1"
    private static let remoteKey = "diagnostics.otlpConsent.v1"
    private let defaults: UserDefaults
    private let telemetry: AnnexTelemetry
    public init(defaults: UserDefaults = .standard, telemetry: AnnexTelemetry = .shared) {
        self.defaults = defaults; self.telemetry = telemetry
        mode = defaults.string(forKey: Self.preferenceKey) == AnnexDiagnosticCaptureMode.always.rawValue ? .always : .off
        destination = defaults.data(forKey: Self.destinationKey).flatMap { try? JSONDecoder().decode(AnnexOTLPConfiguration.self, from: $0) }
        remoteEnabled = destination != nil && defaults.bool(forKey: Self.remoteKey)
        telemetry.setEnabled(mode != .off)
        telemetry.setRemoteExportEnabled(remoteEnabled)
    }
    public func configureDestination(address: String) throws {
        let value = try AnnexOTLPConfiguration(address: address)
        defaults.set(try JSONEncoder().encode(value), forKey: Self.destinationKey)
        destination = value
        setRemoteEnabled(false) // Editing a destination always requires fresh consent.
    }
    public func setRemoteEnabled(_ enabled: Bool) {
        remoteEnabled = enabled && destination != nil
        defaults.set(remoteEnabled, forKey: Self.remoteKey)
        telemetry.setRemoteExportEnabled(remoteEnabled)
    }
    public func removeDestination() {
        setRemoteEnabled(false); destination = nil; defaults.removeObject(forKey: Self.destinationKey)
    }
    public func clear() { telemetry.clear(); revision = UUID() }
    public func select(_ mode: AnnexDiagnosticCaptureMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        defaults.set(mode == .always ? "always" : "off", forKey: Self.preferenceKey)
        telemetry.setEnabled(mode != .off)
        if mode != .off { telemetry.record(.settings) }
    }
}
