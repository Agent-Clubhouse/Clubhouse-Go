import Foundation
import CryptoKit

public enum FramebriarError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidInput, invalidResponse, network, storage
    case accessRequired, expired, paused, busy, capacity, conflict, rejected
    case unavailable(retryAfter: TimeInterval)
}

public struct Configuration: Sendable {
    public static let serviceURL = URL(string: "https://framebriar-masra91-poc.azurewebsites.net/api")!
    public let endpoint: URL
    public let gameID: String
    public let buildSHA: String?
    public var storageScope: String { "framebriar-v2-" + digest(Data((endpoint.absoluteString + "|" + gameID).utf8)) }
    public init(gameID: String, buildSHA: String? = nil, endpoint: URL = serviceURL) throws {
        guard matches(gameID, "^[a-z0-9-]{1,60}$"), buildSHA == nil || matches(buildSHA!, "^[a-f0-9]{7,40}$"),
              endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw FramebriarError.invalidConfiguration }
        self.gameID = gameID; self.buildSHA = buildSHA
        self.endpoint = endpoint
    }
}

public enum AccessState: String, Codable, Sendable {
    case disconnected, connected, offline, expired, accessRequired, paused
}

public struct ClientStatus: Sendable {
    public let access: AccessState
    public let canSubmit: Bool
    public let enrollmentExpiresAt: Date?
    public let queued: Int
    public let queuedBytes: Int
    public let blocked: Int
    public let lastReceivedID: UUID?
    public var correlationWaiting: Int = 0
    public static let maxItems = 10
    public static let maxBytes = 32 * 1024 * 1024
}

/// Prepared from explicit user input and optional reviewed incident references. No automatic capture.
public struct ReviewedFeedback: Codable, Sendable, Equatable {
    public let id: UUID
    public let notes: String
    public let screenshotPNG: Data?
    public let incident: FeedbackIncident?
    let gameID: String
    let buildSHA: String?
    let capturedAt: Date
    let sessionID: String

    public init(configuration: Configuration, notes: String, reviewedScreenshotPNG: Data? = nil,
                id: UUID = UUID(), capturedAt: Date = Date(), incident: FeedbackIncident? = nil) throws {
        try incident?.validate()
        guard matches(id.uuidString, "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89aAbB][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$"),
              notes.utf16.count <= 2000 else { throw FramebriarError.invalidInput }
        if let png = reviewedScreenshotPNG {
            guard png.count <= 8 * 1024 * 1024, png.starts(with: [137,80,78,71,13,10,26,10]) else { throw FramebriarError.invalidInput }
        }
        let clean = redact(notes)
        guard reviewedScreenshotPNG != nil || !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FramebriarError.invalidInput }
        self.incident = incident
        self.id = id; self.notes = clean; screenshotPNG = reviewedScreenshotPNG
        gameID = configuration.gameID; buildSHA = configuration.buildSHA
        self.capturedAt = capturedAt; sessionID = UUID().uuidString
    }

    func wire() throws -> Data {
        var value: [String: Any] = ["v": 1, "id": id.uuidString.lowercased(), "gameId": gameID,
            "buildSha": buildSHA as Any? ?? NSNull(), "scene": "user-feedback", "sessionId": sessionID,
            "seed": NSNull(), "platform": "ios", "input": "touch", "capturedAt": iso(capturedAt),
            "notes": notes, "breadcrumbs": [], "media": NSNull()]
        if let png = screenshotPNG { value["media"] = ["type": "image/png", "bytes": png.count, "sha256": digest(png)] }
        if let incident {
            try incident.validate()
            value["incident"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(incident))
            if let primary = incident.traces.first { value["traceId"] = primary.traceId; value["spanId"] = primary.spanId }
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 16384 else { throw FramebriarError.invalidInput }
        return data
    }
    func validate(for configuration: Configuration) throws {
        guard gameID == configuration.gameID else { throw FramebriarError.invalidInput }
        _ = try ReviewedFeedback(configuration: Configuration(gameID: gameID, buildSHA: buildSHA), notes: notes,
                                 reviewedScreenshotPNG: screenshotPNG, id: id, capturedAt: capturedAt, incident: incident)
        guard notes == redact(notes), matches(sessionID, "^[a-zA-Z0-9_-]{1,64}$"), capturedAt.timeIntervalSince1970.isFinite else { throw FramebriarError.invalidInput }
        _ = try wire()
    }
}

public struct EnrollmentRecord: Codable, Sendable {
    public var refreshToken: String?
    public var expiresAt: Date?
    public var enrolled: Bool
    public var notice: AccessState
    public init(refreshToken: String? = nil, expiresAt: Date? = nil, enrolled: Bool = false, notice: AccessState = .disconnected) {
        self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.enrolled = enrolled; self.notice = notice
    }
}

public struct QueuedFeedback: Codable, Sendable {
    public let feedback: ReviewedFeedback
    public var attempts: Int
    public var nextAttemptAt: Date
    public var blocked: Bool
    public init(feedback: ReviewedFeedback, attempts: Int = 0, nextAttemptAt: Date = .distantPast, blocked: Bool = false) {
        self.feedback = feedback; self.attempts = attempts; self.nextAttemptAt = nextAttemptAt; self.blocked = blocked
    }
}

func matches(_ value: String, _ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
func parseDate(_ value: String) -> Date? {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
func redact(_ text: String) -> String {
    let patterns: [(String, String)] = [
        (#"(?i)\b(?:https?://|www\.)\S+"#, "[url]"),
        (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[email]"),
        (#"(?i)\b(?:Bearer\s+\S+|(?:token|password|secret|api[_-]?key|authorization|cookie)\s*[:=]\s*[^\s,;]+)"#, "[redacted]"),
        (#"\b(?:gh[pousr]_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_.-]{20,})\b"#, "[credential]"),
        (#"(?:[A-Z]:\\|/(?:Users|home)/)[^\s]+"#, "[path]")
    ]
    return patterns.reduce(text) { result, item in result.replacingOccurrences(of: item.0, with: item.1, options: .regularExpression) }
}
