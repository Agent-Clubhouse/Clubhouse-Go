import Foundation
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
    }
    struct Provider: Sendable, Equatable {
        var autoEligible: Bool
        var reason: String?
        var choicesSource: String?
        var choicesAsOf: String?
        var models: [Model]
        var cells: [String: Cell]
    }
    struct Agent: Sendable, Equatable {
        var usable: Bool
        var reason: String? = nil
    }
    var revision: String
    var labels: Labels
    var providers: [String: Provider]
    var agent: Agent?
    static func label(_ labels: Labels, family: String, code: String) -> String {
        labels[family]?[code] ?? labels["generic"]?["unknownCode"] ?? "Other"
    }
    func label(_ family: String, _ code: String) -> String { Self.label(labels, family: family, code: code) }
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

/// A page keeps its values after read failures. A stale write replaces them and requires a new human edit.
@MainActor @Observable final class CompanionHelperPresetsScreen {
    private(set) var settings: CompanionHelperRouting?
    private(set) var error: String?
    private(set) var saving = false
    private var loading = false
    // SwiftUI may discard eager State candidates away from the main actor. This model owns no cleanup resources.
    nonisolated deinit {}
    func load(_ read: () async throws -> CompanionHelperRouting) async {
        guard !saving, !loading else { return }
        loading = true
        defer { loading = false }
        do { settings = try await read(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func save(_ write: (String) async throws -> CompanionHelperRouting) async {
        guard !saving, !loading, let revision = settings?.revision else { return }
        saving = true; error = nil
        defer { saving = false }
        do { settings = try await write(revision) }
        catch CompanionHelperRoutingError.stale(let fresh, let message) { settings = fresh; error = message }
        catch { self.error = error.localizedDescription }
    }
}
