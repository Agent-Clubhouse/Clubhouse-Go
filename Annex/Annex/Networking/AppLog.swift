import Foundation
import OSLog

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
        osLog.info("[\(category)] \(message)")
    }

    func warn(_ category: String, _ message: String) {
        append(.warn, category, message)
        osLog.warning("[\(category)] \(message)")
    }

    func error(_ category: String, _ message: String) {
        append(.error, category, message)
        osLog.error("[\(category)] \(message)")
    }

    func debug(_ category: String, _ message: String) {
        append(.debug, category, message)
        osLog.debug("[\(category)] \(message)")
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
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }
}
