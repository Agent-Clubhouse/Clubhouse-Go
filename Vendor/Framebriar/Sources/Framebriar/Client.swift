import Foundation
import CoreFoundation

public actor Client {
    public nonisolated let configuration: Configuration
    /// Synchronous, thread-safe view of the enrollment for telemetry gating. Never holds a credential.
    public nonisolated let enrollmentSignal = EnrollmentSignal()
    private let transport: any HTTPTransport
    private let enrollmentStore: any EnrollmentStore
    private let feedbackStore: any FeedbackStore
    private let now: @Sendable () -> Date
    private var enrollment: EnrollmentRecord
    private var queue: [QueuedFeedback]
    private var accessToken: String?
    private var accessExpiry: Date?
    private var correlationSupported = false
    private var paused = true
    private var busy = false
    private var generation = 0
    private var lastReceivedID: UUID?
    private var receivedIDs: [UUID] = []
    private var lastDeliveryResult: String?
    private var lastFaults: [UUID: FramebriarError] = [:]
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
            // A record from before refs existed gets one, kept from now on.
            var settled = enrollment
            if settled.enrollmentRef == nil, settled.enrolled {
                settled.enrollmentRef = UUID().uuidString.lowercased()
                try enrollmentStore.save(settled, scope: configuration.storageScope)
            }
            self.enrollment = settled; self.queue = queue
            // Fence on load too, so a downgrade right after this launch can't send a held report.
            let fenced = Self.settled(queue, enrollment: settled, seen: true)
            if !Self.sameBindings(fenced, queue) {
                try feedbackStore.save(fenced, scope: configuration.storageScope)
                self.queue = fenced
            }
        } catch { throw FramebriarError.storage }
        enrollmentSignal.update(self.enrollment)
    }

    private static let unbound = "unbound"
    /// Reports from an older SDK can't be told apart: bind them once to the enrollment present now, or
    /// persist `unbound` so a later enrollment can never claim them. `seen` is false during a change: a
    /// report first seen then never belonged to the new enrollment. Then fence held reports with
    /// `blocked`, which older SDKs skip and keep. Attempts are unchanged.
    private static func settled(_ items: [QueuedFeedback], enrollment: EnrollmentRecord, seen: Bool) -> [QueuedFeedback] {
        items.map { source in
            var item = source
            if item.enrollmentRef == nil {
                // A blocked report with no ref may be one an older SDK re-encoded: it keeps `blocked`.
                item.enrollmentRef = seen && enrollment.refreshToken != nil ? enrollment.enrollmentRef : unbound
            }
            if !item.heldForEnrollment, !item.blocked, item.enrollmentRef != enrollment.enrollmentRef {
                item.heldForEnrollment = true; item.blocked = true; item.nextAttemptAt = .distantPast
            }
            return item
        }
    }
    private static func sameBindings(_ a: [QueuedFeedback], _ b: [QueuedFeedback]) -> Bool {
        zip(a, b).allSatisfy { $0.enrollmentRef == $1.enrollmentRef && $0.heldForEnrollment == $1.heldForEnrollment }
    }
    private func isHeld(_ item: QueuedFeedback) -> Bool { item.heldForEnrollment || (!item.blocked && item.enrollmentRef != enrollment.enrollmentRef) }
    private func held() -> [QueuedFeedback] { queue.filter(isHeld) }
    /// Changes with the current enrollment or the set of held reports; can't be reversed to the ref.
    private func releaseToken(_ items: [QueuedFeedback]) -> String? {
        guard !items.isEmpty, let ref = enrollment.enrollmentRef, hasActiveEnrollment else { return nil }
        let ids = items.map { $0.feedback.id.uuidString.lowercased() }.sorted()
        return digest(Data((["framebriar-release-v1", ref] + ids).joined(separator: "\n").utf8))
    }
    private var hasActiveEnrollment: Bool {
        enrollment.refreshToken != nil && enrollment.expiresAt.map { $0 > now() } == true
    }

    public func status() -> ClientStatus {
        let expired = enrollment.enrolled && enrollment.expiresAt.map { $0 <= now() } == true
        let state: AccessState = expired ? .expired : paused ? .paused :
            accessExpiry.map { $0 > now() } == true ? .connected : (enrollment.notice == .connected ? .offline : enrollment.notice)
        return ClientStatus(access: state, canSubmit: enrollment.enrolled, enrollmentExpiresAt: enrollment.expiresAt,
                            queued: queue.count, queuedBytes: queue.reduce(0) { $0 + ($1.feedback.screenshotPNG?.count ?? 0) },
                            blocked: queue.filter { $0.blocked && !$0.heldForEnrollment }.count, lastReceivedID: lastReceivedID,
                            correlationWaiting: correlationSupported && accessExpiry.map { $0 > now() } == true ? 0 : queue.filter { $0.feedback.incident != nil && !isHeld($0) }.count,
                            lastDeliveryResult: lastDeliveryResult,
                            heldForEnrollment: held().count, heldBytes: held().reduce(0) { $0 + ($1.feedback.screenshotPNG?.count ?? 0) },
                            releaseToken: releaseToken(held()),
                            notice: enrollment.responseRejection == nil ? nil : "enrollment-response-rejected",
                            noticeReason: enrollment.responseRejection)
    }

    /// Lifecycle pause stops subsequent requests. Already transmitted bytes cannot be recalled.
    /// A late result never starts media upload or removes a retained report.
    public func pause() { paused = true; generation += 1; accessToken = nil; accessExpiry = nil; correlationSupported = false }
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
        if enrollment.responseRejection != nil {
            var record = enrollment; record.responseRejection = nil
            try saveEnrollment(record)
        }
        let value = try await request("v1/access/redeem", json: body, generation: ticket)
        if let reason = rejection(value) {
            var record = enrollment; record.responseRejection = reason
            try saveEnrollment(record)
            throw FramebriarError.invalidResponse
        }
        try accept(value, previous: nil)
        lastAttempt = nil; accessBackoff = .distantPast
    }

    /// Silent renewal; never redeems an invitation. Safe to call on foreground/online events.
    public func refreshAccess() async throws {
        guard !busy else { throw FramebriarError.busy }
        busy = true; defer { busy = false }
        _ = try await token(generation)
    }

    /// Current enrollment access token for `Telemetry` (or another in-process exporter). Never persisted
    /// or logged. Nil when not enrolled, paused, expired, revoked, or when no token can be issued now;
    /// callers back off and retry. `refresh: true` discards the cached token first (after an HTTP 401).
    /// While a feedback pass holds the client busy only a still-valid cached token is returned.
    public func telemetryToken(refresh: Bool = false) async -> String? {
        guard !paused, enrollment.refreshToken != nil else { return nil }
        if refresh { accessToken = nil; accessExpiry = nil }
        if let accessToken, let expiry = accessExpiry, expiry.timeIntervalSince(now()) > 300 { return accessToken }
        guard !busy else { return nil }
        busy = true; defer { busy = false }
        return try? await token(generation)
    }

    /// Commits locally before returning, bound to the enrollment the draft was opened under. A different
    /// or nil ref saves nothing and throws `enrollmentChanged`. The same report under the same enrollment
    /// is idempotent.
    @discardableResult public func enqueue(_ feedback: ReviewedFeedback, enrollmentRef: String?) throws -> UUID {
        guard enrollment.enrolled else { throw FramebriarError.accessRequired }
        guard let enrollmentRef, enrollmentRef == enrollment.enrollmentRef else { throw FramebriarError.enrollmentChanged }
        return try commit(feedback, enrollmentRef: enrollmentRef)
    }

    /// Binds to the enrollment at this call, for a report built just now with no open draft. Use
    /// `enqueue(_:enrollmentRef:)` for anything captured earlier.
    @available(*, deprecated, message: "Use enqueue(_:enrollmentRef:) with the ref recorded when the report was opened.")
    @discardableResult public func enqueue(_ feedback: ReviewedFeedback) throws -> UUID {
        guard enrollment.enrolled else { throw FramebriarError.accessRequired }
        return try commit(feedback, enrollmentRef: enrollment.enrollmentRef ?? Self.unbound)
    }

    private func commit(_ feedback: ReviewedFeedback, enrollmentRef: String) throws -> UUID {
        try feedback.validate(for: configuration)
        if let existing = queue.first(where: { $0.feedback.id == feedback.id }) {
            guard existing.feedback == feedback else { throw FramebriarError.conflict }
            return feedback.id
        }
        guard queue.count < ClientStatus.maxItems,
              queue.reduce(0, { $0 + ($1.feedback.screenshotPNG?.count ?? 0) }) + (feedback.screenshotPNG?.count ?? 0) <= ClientStatus.maxBytes else { throw FramebriarError.capacity }
        try persist(queue + [QueuedFeedback(feedback: feedback, enrollmentRef: enrollmentRef)])
        // A receipt covers the bytes it was for. These get their own, from their own attempt.
        receivedIDs.removeAll { $0 == feedback.id }
        return feedback.id
    }

    /// The only way a held report gets a new enrollment. Pass the `releaseToken` from the status the user
    /// saw: if the enrollment or the held set has changed since, nothing rebinds. Each report rebinds
    /// durably or stays held. Report bytes don't change. Delivery follows on the next `flush()`, so
    /// `released` doesn't mean delivered.
    @discardableResult public func releaseHeldReports(releaseToken supplied: String?) -> HeldReleaseResult {
        let items = held()
        guard hasActiveEnrollment, let ref = enrollment.enrollmentRef else {
            return HeldReleaseResult(released: 0, remaining: items.count, failed: 0, code: "not-enrolled")
        }
        guard let supplied, supplied == releaseToken(items) else {
            return HeldReleaseResult(released: 0, remaining: items.count, failed: 0, code: "stale-release")
        }
        var released = 0, failed = 0
        for item in items {
            var updated = queue
            guard let index = updated.firstIndex(where: { $0.feedback.id == item.feedback.id }) else { continue }
            updated[index].enrollmentRef = ref; updated[index].heldForEnrollment = false; updated[index].blocked = false
            updated[index].nextAttemptAt = .distantPast
            do { try persist(updated); released += 1 } catch { failed += 1 }
        }
        return HeldReleaseResult(released: released, remaining: items.count - released, failed: failed)
    }

    /// Discards held reports only. Takes no token and sends nothing, so it works while unenrolled.
    @discardableResult public func clearHeldReports() -> HeldClearResult {
        let items = held()
        var cleared = 0, failed = 0
        for item in items {
            do { try persist(queue.filter { $0.feedback.id != item.feedback.id }); cleared += 1 } catch { failed += 1 }
        }
        return HeldClearResult(cleared: cleared, remaining: items.count - cleared, failed: failed)
    }

    /// One bounded pass, at most ten reports. The host schedules future foreground passes.
    /// Persisted backoff is respected even when manually called or after process restart.
    public func flush() async throws {
        guard !paused else { throw FramebriarError.paused }
        guard !busy else { return }
        busy = true; defer { busy = false }
        try await pass(queue, ticket: generation)
    }

    /// Attempts one committed report now, for an immediate result after Send. Other queued reports
    /// wait for the next `flush()`. Never throws and never removes an undelivered report. An older
    /// pass still running after `waitLimit` seconds leaves this report queued for the next one.
    public func deliver(_ id: UUID, waitLimit: TimeInterval = 10) async -> FeedbackDeliveryOutcome {
        var waited: TimeInterval = 0
        while busy, waited < waitLimit {
            try? await Task.sleep(nanoseconds: 50_000_000); waited += 0.05
        }
        guard !busy else { return .saved(.serviceBusy) }
        if !paused, let item = queue.first(where: { $0.feedback.id == id }), !item.blocked, !isHeld(item), item.nextAttemptAt <= now() {
            busy = true; defer { busy = false }
            try? await pass([item], ticket: generation)
        }
        return outcome(of: id)
    }

    private func outcome(of id: UUID) -> FeedbackDeliveryOutcome {
        if receivedIDs.contains(id) { return .sent }
        guard let item = queue.first(where: { $0.feedback.id == id }) else { return .needsAttention(.removed) }
        if isHeld(item) { return .needsAttention(.heldForEnrollment) }
        if item.blocked { return .needsAttention(.rejected) }
        if enrollment.refreshToken == nil || enrollment.expiresAt.map({ $0 <= now() }) == true { return .needsAttention(.accessRequired) }
        if paused { return .saved(.paused) }
        switch lastFaults[id] {
        case .storage?: return .needsAttention(.deliveryUnconfirmed)
        case .network?: return .saved(.offline)
        case .some: return .saved(.serviceBusy)
        case nil: return item.feedback.incident != nil && !correlationSupported ? .saved(.waitingForService) : .saved(.serviceBusy)
        }
    }

    private func pass(_ items: [QueuedFeedback], ticket: Int) async throws {
        for item in items {
            try check(ticket)
            guard !item.blocked, item.nextAttemptAt <= now() else { continue }
            // Before any token, and read again from the queue: a release may have run during an await.
            guard let current = queue.first(where: { $0.feedback.id == item.feedback.id }), !isHeld(current) else { continue }
            do {
                let bearer = try await token(ticket)
                // A token only exists for the current enrollment. Refuse if it moved during that await.
                guard current.enrollmentRef == enrollment.enrollmentRef else { continue }
                let report = item.feedback
                // An old service silently drops unknown report fields. Retain this report
                // unchanged until refreshed access explicitly advertises schema support.
                guard report.incident == nil || correlationSupported else { continue }
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
                receivedIDs = Array((receivedIDs + [report.id]).suffix(ClientStatus.maxItems * 2))
                lastDeliveryResult = "ok"; lastFaults[report.id] = nil
            } catch {
                try check(ticket)
                // The enrollment moved during this attempt: the report is held now. No retry is spent.
                if current.enrollmentRef != enrollment.enrollmentRef { continue }
                lastFaults[item.feedback.id] = error as? FramebriarError ?? .network
                lastDeliveryResult = failureName(error as? FramebriarError ?? .network)
                if error as? FramebriarError == .storage { throw FramebriarError.storage }
                var updated = queue
                guard let index = updated.firstIndex(where: { $0.feedback.id == item.feedback.id }) else { continue }
                updated[index].attempts = min(32, updated[index].attempts + 1)
                let fault = error as? FramebriarError ?? .network
                let permanent = fault == .conflict || fault == .rejected || fault == .invalidInput
                updated[index].blocked = permanent
                var delay = min(300, 2 * pow(2, Double(min(updated[index].attempts, 8)) ))
                if case .unavailable(let retryAfter) = fault { delay = max(delay, retryAfter) }
                if fault == .accessRequired || fault == .expired { delay = max(delay, 300); accessToken = nil; accessExpiry = nil; correlationSupported = false }
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
        enrollmentSignal.update(EnrollmentRecord()) // telemetry stops even if the local save fails
        try saveEnrollment(EnrollmentRecord())
        fenceHeldReports()
        accessToken = nil; accessExpiry = nil; correlationSupported = false; lastAttempt = nil
        guard let old else { return true }
        do {
            let reply = try await request("v1/access/disconnect", json: ["v": 1, "refreshToken": old], generation: ticket, allowPaused: true)
            return reply["v"] as? Int == 1 && reply["disconnected"] as? Bool == true
        } catch { return false }
    }

    private func failureName(_ fault: FramebriarError) -> String {
        switch fault {
        case .network: "offline"
        case .unavailable: "server"
        case .accessRequired, .expired: "auth"
        case .rejected, .conflict, .invalidInput, .invalidResponse: "protocol"
        case .storage, .capacity: "storage"
        case .busy: "busy"
        case .paused: "cancelled"
        case .enrollmentChanged: "auth"
        case .invalidConfiguration: "unknown"
        }
    }
    private func check(_ ticket: Int, allowPaused: Bool = false) throws {
        guard generation == ticket, allowPaused || !paused else { throw FramebriarError.paused }
        try Task.checkCancellation()
    }
    /// Best effort. If this save fails the next launch retries, and this code still won't send them.
    private func fenceHeldReports() {
        try? persist(Self.settled(queue, enrollment: enrollment, seen: false))
    }
    /// A store can replace its file and then fail. A failed save still counts when reading the store back
    /// finds exactly `items`, because that's what a relaunch would load. Anything else is a failure, and
    /// memory isn't touched: what's on disk is never adopted. Every caller builds `items` from `queue` in
    /// this actor turn, so this can't bring back or lose anything a successful save wouldn't.
    private func persist(_ items: [QueuedFeedback]) throws {
        do { try feedbackStore.save(items, scope: configuration.storageScope) }
        catch {
            guard let stored = try? feedbackStore.load(scope: configuration.storageScope), Self.sameContents(stored, items) else { throw FramebriarError.storage }
        }
        queue = items
    }
    private static func sameContents(_ a: [QueuedFeedback], _ b: [QueuedFeedback]) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let left = try? encoder.encode(a), let right = try? encoder.encode(b) else { return false }
        return left == right
    }
    private func saveEnrollment(_ record: EnrollmentRecord) throws {
        do { try enrollmentStore.save(record, scope: configuration.storageScope); enrollment = record }
        catch { throw FramebriarError.storage }
        enrollmentSignal.update(record)
    }
    private func token(_ ticket: Int) async throws -> String {
        try check(ticket)
        if let end = enrollment.expiresAt, end <= now() {
            var record = enrollment; record.refreshToken = nil; record.notice = .expired
            try saveEnrollment(record); accessToken = nil; accessExpiry = nil; correlationSupported = false
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
            accessToken = nil; accessExpiry = nil; correlationSupported = false
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
    /// Tolerated on upper bounds only: a device clock behind the issuer's sees its deadlines as further away.
    private static let clockSkew: TimeInterval = 300
    /// Why a parsed reply can't be used, or nil. Only the reason leaves here, never the reply's values.
    private func rejection(_ value: [String: Any]) -> String? {
        guard value["v"] as? Int == 1, value["scopeVersion"] as? Int == 2 else { return "invalid-response" }
        guard value["gameId"] as? String == configuration.gameID else { return "wrong-game" }
        guard let token = value["token"] as? String, matches(token, "^[A-Za-z0-9_-]{43}$"),
              let refresh = value["refreshToken"] as? String, matches(refresh, "^[A-Za-z0-9_-]{43}$") else { return "invalid-token" }
        guard let expiry = (value["expiresAt"] as? String).flatMap(parseDate),
              let end = (value["refreshExpiresAt"] as? String).flatMap(parseDate),
              expiry > now(), expiry.timeIntervalSince(now()) <= 3600 + Self.clockSkew, end >= expiry,
              end.timeIntervalSince(now()) <= 365 * 86400 + Self.clockSkew else { return "invalid-deadline" }
        return nil
    }
    private func accept(_ value: [String: Any], previous: EnrollmentRecord?) throws {
        guard rejection(value) == nil,
              let token = value["token"] as? String, let refresh = value["refreshToken"] as? String,
              let expiry = (value["expiresAt"] as? String).flatMap(parseDate),
              let end = (value["refreshExpiresAt"] as? String).flatMap(parseDate),
              previous == nil || (previous?.refreshToken == refresh && previous?.expiresAt == end) else { throw FramebriarError.invalidResponse }
        // A redemption is a new enrollment, even under the same invitation. A refresh is not.
        let ref = previous == nil ? UUID().uuidString.lowercased() : previous?.enrollmentRef
        try saveEnrollment(EnrollmentRecord(refreshToken: refresh, expiresAt: end, enrolled: true, notice: .connected, enrollmentRef: ref,
                                            responseRejection: previous?.responseRejection))
        // In the same actor turn, before the new token can be used for anything.
        if previous == nil { fenceHeldReports() }
        accessToken = token; accessExpiry = expiry
        correlationSupported = (value["feedbackCorrelationVersion"] as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0 == 1 } ?? false
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
