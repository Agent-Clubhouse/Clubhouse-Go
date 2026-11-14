import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif
import Observation

nonisolated struct CompanionHelperRouting: Sendable, Equatable {
    typealias Labels = [String: [String: String]]
    struct Selection: Sendable, Equatable {
        var model: String
        var effort: String?
        var summary: String { [model, effort.map { "\($0) effort" }].compactMap { $0 }.joined(separator: ", ") }
    }
    struct Model: Identifiable, Sendable, Equatable {
        var id: String
        var label: String
        var efforts: [String]
    }
    struct Cell: Sendable, Equatable {
        var effective: Selection?
        var custom: Selection?
        var builtin: Selection?
        var source: String
        var state: String
        var staleReason: String?
        var fallback: String?
        var editable: Bool
        var follows: String? = nil
        var inheritanceSummary: String? { follows.map { "Same as \($0.capitalized)" } }
        var choiceSource: String { custom != nil ? "Custom" : inheritanceSummary ?? "Built-in" }
    }
    struct Provider: Sendable, Equatable {
        var autoEligible: Bool
        var autoCandidate = true
        var reason: String?
        var choicesSource: String?
        var choicesAsOf: String?
        var models: [Model]
        var cells: [String: Cell]
        var quota: CompanionHelperQuota?
    }
    struct Agent: Sendable, Equatable {
        var usable: Bool
        var reason: String? = nil
    }
    var revision: String
    var labels: Labels
    var providers: [String: Provider]
    var agent: Agent?
    var auto: CompanionHelperAuto?
    var serverTime: Date?
    var copilotAuto: Bool?
    var nextRefreshDelay: Double? { CompanionHelperQuota.nextRefreshDelay(providers.values.compactMap(\.quota)) }
    static func label(_ labels: Labels, family: String, code: String) -> String {
        labels[family]?[code] ?? labels["generic"]?["unknownCode"] ?? "Other"
    }
    func label(_ family: String, _ code: String) -> String { Self.label(labels, family: family, code: code) }
    func autoCandidateText(_ id: String, capability: AnnexCapabilities.HelperRouting) -> String {
        guard providers[id]?.autoCandidate == true, capability.autoCandidates?.contains(id) != false else {
            return "Preset only. Auto doesn’t choose this provider."
        }
        if id == "copilot-cli", copilotAuto == false { return label("skipped", "auto_disabled") }
        return capability.lastResortCandidates?.contains(id) == true ? "Auto candidate (last resort)" : "Auto candidate"
    }
}

/// Codes in snapshots, with desktop-owned display text only in agent settings. No second context notice.
nonisolated struct CompanionHelperRoutingDecision: Sendable, Equatable {
    var mode: String
    var selection: CompanionRequestedRouting
    var reason: String
    var fallback: String?
    var summary: String?
    var displayReason: String?
    var displayFallback: String?
    var decidedAt: Date?
    var balanced = false
    var load: [String: Int] = [:]
    var quota: [String: CompanionHelperQuota] = [:]
    var skipped: [String: String] = [:]
    var warning: CompanionHelperStartWarning?
    var displayWarning: String?
    func reasonText(labels: CompanionHelperRouting.Labels) -> String {
        displayReason ?? CompanionHelperRouting.label(labels, family: "reason", code: reason)
    }
}

/// Held starts have no resolved choice. Show only the request's supplied fields.
nonisolated struct CompanionRequestedRouting: Sendable, Equatable {
    var provider: String?
    var model: String?
    var effort: String?
    var difficulty: String?
    var summary: String { [provider, model, effort.map { "\($0) effort" }, difficulty].compactMap { $0 }.joined(separator: " · ") }
}

nonisolated enum CompanionHelperRoutingError: Error, LocalizedError {
    case stale(CompanionHelperRouting, String)
    var errorDescription: String? { switch self { case .stale(_, let message): message } }
}
nonisolated struct CompanionHelperRequestConsumed: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// How a `grant.answer` didn't go through. `gone` means the request no longer waits: drop its row.
/// `refused` means nothing changed and it still waits, so the user can try again or decline.
nonisolated enum CompanionGrantRequestError: Error, LocalizedError, Equatable {
    case gone(String)
    case refused(String)
    static let updateDesktop = "Update Clubhouse on your desktop to answer Clubhouse permission requests from your phone."
    static let goneMessage = "This request has expired or was already answered."
    var errorDescription: String? { switch self { case .gone(let message), .refused(let message): message } }
    /// The desktop's refusal codes (`docs/mobile-control-v1.md` → grant.answer). Its message is a sentence; these stand in without one.
    static func message(code: String, message: String?) -> String {
        if let message, !message.isEmpty, message != code, message.first?.isUppercase == true { return message }
        switch code {
        case "grant_request_not_found": return goneMessage
        case "grant_answer_not_offered": return "This request doesn't take that answer. Allow or decline it."
        case "grant_answer_failed": return "Couldn’t save the permission. Try again, or decline it."
        default: return "The desktop couldn’t take this answer. Try again."
        }
    }
}

/// A page keeps its values after read failures. A stale write replaces them and requires a new human edit.
@MainActor @Observable final class CompanionHelperPresetsScreen {
    private(set) var settings: CompanionHelperRouting?
    private(set) var error: String?
    private(set) var saving = false
    private var readID = UUID()
    private(set) var refreshID = UUID()
    private(set) var receivedAt: ContinuousClock.Instant = .now
    // SwiftUI may discard eager State candidates away from the main actor. This model owns no cleanup resources.
    nonisolated deinit {}
    func load(_ read: () async throws -> CompanionHelperRouting) async {
        guard !saving else { return }
        let id = UUID()
        readID = id
        defer { if readID == id { refreshID = UUID() } }
        do {
            let fresh = try await read()
            guard readID == id else { return }
            settings = fresh; receivedAt = .now; error = nil
        } catch {
            guard readID == id else { return }
            self.error = error.localizedDescription
        }
    }
    func save(_ write: (String) async throws -> CompanionHelperRouting) async {
        guard !saving, let revision = settings?.revision else { return }
        // A periodic read cannot swallow an explicit edit, or replace its result afterward.
        readID = UUID()
        saving = true; error = nil
        defer { saving = false; refreshID = UUID() }
        do { settings = try await write(revision); receivedAt = .now }
        catch CompanionHelperRoutingError.stale(let fresh, let message) { settings = fresh; receivedAt = .now; error = message }
        catch { self.error = error.localizedDescription }
    }
}
