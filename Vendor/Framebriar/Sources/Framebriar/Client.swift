import Foundation

public actor Client {
    public nonisolated let configuration: Configuration
    private let transport: any HTTPTransport
    private let enrollmentStore: any EnrollmentStore
    private let feedbackStore: any FeedbackStore
    private let now: @Sendable () -> Date
    private var enrollment: EnrollmentRecord
    private var queue: [QueuedFeedback]
    private var accessToken: String?
    private var accessExpiry: Date?
    private var paused = true
    private var busy = false
    private var generation = 0
    private var lastReceivedID: UUID?
    private var lastAttempt: (invitation: String, id: String, at: Date)?
    private var accessBackoff: Date = .distantPast

    public init(configuration: Configuration, transport: any HTTPTransport = URLSessionTransport(),
                enrollmentStore: any EnrollmentStore, feedbackStore: any FeedbackStore,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.configuration = configuration; self.transport = transport
        self.enrollmentStore = enrollmentStore; self.feedbackStore = feedbackStore; self.now = now
        do {
            let enrollment = try enrollmentStore.load(scope: configuration.storageScope)
            let queue = try feedbackStore.load(scope: configuration.storageScope)
            guard queue.count <= ClientStatus.maxItems,
                  queue.reduce(0, { $0 + ($1.feedback.screenshotPNG?.count ?? 0) }) <= ClientStatus.maxBytes,
                  Set(queue.map { $0.feedback.id }).count == queue.count,
                  enrollment.refreshToken == nil || (enrollment.enrolled && enrollment.expiresAt != nil && matches(enrollment.refreshToken!, "^[A-Za-z0-9_-]{43}$")) else { throw FramebriarError.storage }
            for item in queue {
                try item.feedback.validate(for: configuration)
                guard (0...32).contains(item.attempts), item.nextAttemptAt.timeIntervalSince1970.isFinite else { throw FramebriarError.storage }
            }
            self.enrollment = enrollment; self.queue = queue
        } catch { throw FramebriarError.storage }
    }

    public func status() -> ClientStatus {
        let expired = enrollment.enrolled && enrollment.expiresAt.map { $0 <= now() } == true
        let state: AccessState = expired ? .expired : paused ? .paused :
            accessExpiry.map { $0 > now() } == true ? .connected : (enrollment.notice == .connected ? .offline : enrollment.notice)
        return ClientStatus(access: state, canSubmit: enrollment.enrolled, enrollmentExpiresAt: enrollment.expiresAt,
                            queued: queue.count, queuedBytes: queue.reduce(0) { $0 + ($1.feedback.screenshotPNG?.count ?? 0) },
                            blocked: queue.filter(\.blocked).count, lastReceivedID: lastReceivedID)
    }

    /// Lifecycle pause stops subsequent requests. Already transmitted bytes cannot be recalled.
    /// A late result never starts media upload or removes a retained report.
    public func pause() { paused = true; generation += 1; accessToken = nil; accessExpiry = nil }
    public func resume() { paused = false }

    /// Explicit user action only. On uncertainty, repeating the same invite in this process uses
    /// the same idempotency attempt for 14 minutes. Neither invite nor attempt is written to disk.
    public func connect(invitation: String) async throws {
        guard !busy else { throw FramebriarError.busy }
        guard !paused else { throw FramebriarError.paused }
        guard matches(invitation, "^[A-Za-z0-9_-]{43}$") else { throw FramebriarError.invalidInput }
        busy = true; defer { busy = false }
        let ticket = generation
        if lastAttempt?.invitation != invitation || now().timeIntervalSince(lastAttempt!.at) > 14 * 60 {
            lastAttempt = (invitation, UUID().uuidString, now())
        }
        let body: [String: Any] = ["v": 1, "invitation": invitation, "gameId": configuration.gameID,
                                  "buildSha": configuration.buildSHA as Any? ?? NSNull(), "scopeVersion": 2, "attemptId": lastAttempt!.id]
        let value = try await request("v1/access/redeem", json: body, generation: ticket)
        try accept(value, previous: nil)
        lastAttempt = nil; accessBackoff = .distantPast
    }

    /// Silent renewal; never redeems an invitation. Safe to call on foreground/online events.
    public func refreshAccess() async throws {
        guard !busy else { throw FramebriarError.busy }
        busy = true; defer { busy = false }
        _ = try await token(generation)
    }

    /// Commits locally before returning. No network request or capture is performed here.
    @discardableResult public func enqueue(_ feedback: ReviewedFeedback) throws -> UUID {
        guard enrollment.enrolled else { throw FramebriarError.accessRequired }
        try feedback.validate(for: configuration)
        if let existing = queue.first(where: { $0.feedback.id == feedback.id }) {
            guard existing.feedback == feedback else { throw FramebriarError.conflict }
            return feedback.id
        }
        guard queue.count < ClientStatus.maxItems,
              queue.reduce(0, { $0 + ($1.feedback.screenshotPNG?.count ?? 0) }) + (feedback.screenshotPNG?.count ?? 0) <= ClientStatus.maxBytes else { throw FramebriarError.capacity }
        try persist(queue + [QueuedFeedback(feedback: feedback)])
        return feedback.id
    }

    /// One bounded pass, at most ten reports. The host schedules future foreground passes.
    /// Persisted backoff is respected even when manually called or after process restart.
    public func flush() async throws {
        guard !paused else { throw FramebriarError.paused }
        guard !busy else { return }
        busy = true; defer { busy = false }
        let ticket = generation
        for item in queue {
            try check(ticket)
            guard !item.blocked, item.nextAttemptAt <= now() else { continue }
            do {
                let bearer = try await token(ticket)
                let report = item.feedback
                var ack = try await request("v1/reports", data: report.wire(), bearer: bearer, generation: ticket)
                guard ack["id"] as? String == report.id.uuidString.lowercased() else { throw FramebriarError.invalidResponse }
                if ack["status"] as? String == "pending" {
                    guard let media = report.screenshotPNG, let uploadTicket = ack["ticket"] as? String,
                          matches(uploadTicket, "^[A-Za-z0-9_-]{43}$") else { throw FramebriarError.invalidResponse }
                    ack = try await request("v1/reports/\(report.id.uuidString.lowercased())/media", data: media,
                                            method: "PUT", type: "image/png", bearer: bearer,
                                            uploadTicket: uploadTicket, generation: ticket)
                }
                let hasAcknowledgedGame = ack["gameId"] != nil
                let acknowledgedGame = ack["gameId"] as? String
                guard ack["id"] as? String == report.id.uuidString.lowercased(),
                      ["ready", "processed"].contains(ack["status"] as? String ?? ""),
                      !hasAcknowledgedGame || acknowledgedGame == configuration.gameID else { throw FramebriarError.invalidResponse }
                try check(ticket)
                try persist(queue.filter { $0.feedback.id != report.id })
                lastReceivedID = report.id
            } catch {
                try check(ticket)
                if error as? FramebriarError == .storage { throw FramebriarError.storage }
                var updated = queue
                guard let index = updated.firstIndex(where: { $0.feedback.id == item.feedback.id }) else { continue }
                updated[index].attempts = min(32, updated[index].attempts + 1)
                let fault = error as? FramebriarError ?? .network
                let permanent = fault == .conflict || fault == .rejected || fault == .invalidInput
                updated[index].blocked = permanent
                var delay = min(300, 2 * pow(2, Double(min(updated[index].attempts, 8)) ))
                if case .unavailable(let retryAfter) = fault { delay = max(delay, retryAfter) }
                if fault == .accessRequired || fault == .expired { delay = max(delay, 300); accessToken = nil; accessExpiry = nil }
                updated[index].nextAttemptAt = now().addingTimeInterval(min(86400, delay))
                try persist(updated)
                // An access outage or service pause should not fan out into ten requests.
                if fault == .accessRequired || fault == .expired || fault == .network { break }
                if case .unavailable = fault { break }
            }
        }
    }

    /// Explicit destructive local action. Enrollment is unchanged; no remote deletion.
    public func clearQueuedFeedback() throws { generation += 1; try persist([]) }

    /// Forget locally first; reports remain. False means remote revocation is unconfirmed.
    @discardableResult public func disconnect() async throws -> Bool {
        generation += 1; let ticket = generation
        let old = enrollment.refreshToken
        try saveEnrollment(EnrollmentRecord())
        accessToken = nil; accessExpiry = nil; lastAttempt = nil
        guard let old else { return true }
        do {
            let reply = try await request("v1/access/disconnect", json: ["v": 1, "refreshToken": old], generation: ticket, allowPaused: true)
            return reply["v"] as? Int == 1 && reply["disconnected"] as? Bool == true
        } catch { return false }
    }

    private func check(_ ticket: Int, allowPaused: Bool = false) throws {
        guard generation == ticket, allowPaused || !paused else { throw FramebriarError.paused }
        try Task.checkCancellation()
    }
    private func persist(_ items: [QueuedFeedback]) throws {
        do { try feedbackStore.save(items, scope: configuration.storageScope); queue = items }
        catch { throw FramebriarError.storage }
    }
    private func saveEnrollment(_ record: EnrollmentRecord) throws {
        do { try enrollmentStore.save(record, scope: configuration.storageScope); enrollment = record }
        catch { throw FramebriarError.storage }
    }
    private func token(_ ticket: Int) async throws -> String {
        try check(ticket)
        if let end = enrollment.expiresAt, end <= now() {
            var record = enrollment; record.refreshToken = nil; record.notice = .expired
            try saveEnrollment(record); accessToken = nil; accessExpiry = nil
            throw FramebriarError.expired
        }
        if let accessToken, let expiry = accessExpiry, expiry.timeIntervalSince(now()) > 300 { return accessToken }
        guard let refresh = enrollment.refreshToken else { throw FramebriarError.accessRequired }
        guard now() >= accessBackoff else { throw FramebriarError.unavailable(retryAfter: accessBackoff.timeIntervalSince(now())) }
        do {
            let previous = enrollment
            let value = try await request("v1/access/refresh", json: ["v": 1, "refreshToken": refresh, "scopeVersion": 2], generation: ticket)
            try accept(value, previous: previous)
            return accessToken!
        } catch {
            try check(ticket)
            accessToken = nil; accessExpiry = nil
            if error as? FramebriarError == .storage { throw FramebriarError.storage }
            var record = enrollment
            if error as? FramebriarError == .accessRequired { record.refreshToken = nil; record.notice = .accessRequired }
            else { record.notice = .offline }
            try saveEnrollment(record)
            var delay: TimeInterval = 60
            if case .unavailable(let seconds) = error as? FramebriarError { delay = max(delay, seconds) }
            accessBackoff = now().addingTimeInterval(delay)
            throw error
        }
    }
    private func accept(_ value: [String: Any], previous: EnrollmentRecord?) throws {
        guard value["v"] as? Int == 1, value["scopeVersion"] as? Int == 2,
              value["gameId"] as? String == configuration.gameID,
              let token = value["token"] as? String, matches(token, "^[A-Za-z0-9_-]{43}$"),
              let refresh = value["refreshToken"] as? String, matches(refresh, "^[A-Za-z0-9_-]{43}$"),
              let expiry = (value["expiresAt"] as? String).flatMap(parseDate),
              let end = (value["refreshExpiresAt"] as? String).flatMap(parseDate),
              expiry > now(), expiry.timeIntervalSince(now()) <= 3600, end >= expiry,
              end.timeIntervalSince(now()) <= 365 * 86400,
              previous == nil || (previous?.refreshToken == refresh && previous?.expiresAt == end) else { throw FramebriarError.invalidResponse }
        try saveEnrollment(EnrollmentRecord(refreshToken: refresh, expiresAt: end, enrolled: true, notice: .connected))
        accessToken = token; accessExpiry = expiry
    }
    private func request(_ path: String, json: [String: Any], generation: Int, allowPaused: Bool = false) async throws -> [String: Any] {
        try await request(path, data: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), generation: generation, allowPaused: allowPaused)
    }
    private func request(_ path: String, data: Data, method: String = "POST", type: String = "application/json",
                         bearer: String? = nil, uploadTicket: String? = nil, generation: Int, allowPaused: Bool = false) async throws -> [String: Any] {
        try check(generation, allowPaused: allowPaused)
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = method; request.httpBody = data
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let uploadTicket { request.setValue(uploadTicket, forHTTPHeaderField: "x-upload-ticket") }
        let reply: HTTPResponse
        do { reply = try await transport.send(request) }
        catch { try check(generation, allowPaused: allowPaused); throw FramebriarError.network }
        try check(generation, allowPaused: allowPaused)
        switch reply.status {
        case 200..<300: break
        case 401, 403: throw FramebriarError.accessRequired
        case 409: throw FramebriarError.conflict
        case 408, 429, 500...599:
            let raw = reply.headers["retry-after"] ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let delay = Double(raw) ?? formatter.date(from: raw)?.timeIntervalSince(now()) ?? 0
            throw FramebriarError.unavailable(retryAfter: min(86400, max(reply.status == 429 ? 60 : 0, delay.isFinite ? delay : 0)))
        case 400..<500: throw FramebriarError.rejected
        default: throw FramebriarError.invalidResponse
        }
        guard reply.body.count <= 4096, reply.headers["content-type"]?.split(separator: ";").first == "application/json",
              let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any] else { throw FramebriarError.invalidResponse }
        return object
    }
}
