import Foundation
import OSLog
import ClubhouseTransport

/// In-app log buffer for on-device debugging.
/// Captures key lifecycle events so the user can view and share logs
/// without needing Xcode connected.
@MainActor @Observable final class AppLog {
    static let shared = AppLog()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: String
        let message: String

        enum Level: String {
            case info = "INFO"
            case warn = "WARN"
            case error = "ERROR"
            case debug = "DEBUG"
        }

        var formatted: String {
            let ts = Self.formatter.string(from: timestamp)
            return "[\(ts)] [\(level.rawValue)] [\(category)] \(message)"
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    private(set) var entries: [Entry] = []
    private static let maxEntries = 500
    private let osLog = Logger(subsystem: "com.Agent-Clubhouse.Go", category: "app")

    private init() {}

    // MARK: - Logging Methods

    func info(_ category: String, _ message: String) {
        append(.info, category, message)
        osLog.info("Legacy diagnostic event; details omitted")
    }

    func warn(_ category: String, _ message: String) {
        append(.warn, category, message)
        osLog.warning("Legacy diagnostic event; details omitted")
    }

    func error(_ category: String, _ message: String) {
        append(.error, category, message)
        osLog.error("Legacy diagnostic event; details omitted")
    }

    func debug(_ category: String, _ message: String) {
        append(.debug, category, message)
        osLog.debug("Legacy diagnostic event; details omitted")
    }

    // MARK: - Export

    var exportText: String {
        entries.map(\.formatted).joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - Private

    private func append(_ level: Entry.Level, _ category: String, _ message: String) {
        let safeCategory = AnnexLegacyDiagnostic.category(category)
        let entry = Entry(timestamp: Date(), level: level, category: safeCategory, message: "Details omitted for privacy")
        let diagnostic = AnnexTelemetry.shared.begin(.legacyDiagnostic)
        if level == .error { diagnostic.fail(.unknown) }
        diagnostic.end()
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}
