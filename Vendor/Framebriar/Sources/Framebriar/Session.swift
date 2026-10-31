import Foundation

/// One session ID per app run (docs/correlation.md "One session ID"). Feedback reports use it as
/// `sessionId` and telemetry sends it as the resource `session.id`, which the gateway maps to
/// `framebriar.session.id`. A random lowercase UUID, memory only, never derived from the device.
public enum FramebriarSession {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value = UUID().uuidString.lowercased()
    }
    private static let storage = Storage()
    public static var id: String { storage.lock.withLock { storage.value } }
    /// Hosts that already have a per-run ID may adopt it before creating telemetry or reports.
    public static func adopt(_ id: String) throws {
        guard matches(id, "^[A-Za-z0-9_-]{1,64}$") else { throw FramebriarError.invalidInput }
        storage.lock.withLock { storage.value = id }
    }
}

/// Thread-safe, credential-free view of a `Client` enrollment. Telemetry records only while
/// `isEnrolled`, and forgets its queue the moment the enrollment is cleared, revoked or expires.
public final class EnrollmentSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRefresh = false
    private var deadline: Date?
    private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

    public init() {}
    public func isEnrolled(at date: Date) -> Bool {
        lock.withLock { hasRefresh && (deadline.map { $0 > date } ?? false) }
    }
    /// The handler runs on the updating thread whenever enrollment is gained or lost.
    public func observe(_ handler: @escaping @Sendable (Bool) -> Void) -> UUID {
        let key = UUID(); lock.withLock { observers[key] = handler }; return key
    }
    public func removeObserver(_ key: UUID) { _ = lock.withLock { observers.removeValue(forKey: key) } }

    func update(_ record: EnrollmentRecord) {
        let enrolled = record.refreshToken != nil && record.enrolled
        let (changed, handlers) = lock.withLock { () -> (Bool, [@Sendable (Bool) -> Void]) in
            let changed = enrolled != hasRefresh
            hasRefresh = enrolled; deadline = enrolled ? record.expiresAt : nil
            return (changed, Array(observers.values))
        }
        if changed { for handler in handlers { handler(enrolled) } }
    }
}
