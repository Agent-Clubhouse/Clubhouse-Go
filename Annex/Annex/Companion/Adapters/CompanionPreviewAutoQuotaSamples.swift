import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif

/// Presentation-only copies of committed desktop words and shapes. All preview writes still refuse.
extension CompanionPreviewService {
    static var autoQuotaCapability: AnnexCapabilities.HelperRouting? {
        try? previewRoutingJSON(autoQuotaCapabilityJSON).decode(AnnexCapabilities.HelperRouting.self)
    }
    static var previewStartWarning: CompanionHelperStartWarning {
        .init(code: "cooling_down", asOf: Date(timeIntervalSince1970: 1800000000), message: "codex-cli failed to start or hit its limit recently. The helper is started on it anyway, as asked.")
    }
    static var autoQuotaSavedDecision: CompanionHelperRoutingDecision? { .init(json: previewRoutingJSON(savedWarningJSON)) }
    static func autoQuotaPage(projectID: String?, agentID: String?) -> CompanionHelperRouting {
        var page = helperPresets
        if case .object(let labels) = previewRoutingJSON(autoQuotaLabelsJSON) {
            page.labels = labels.compactMapValues { raw in
                guard case .object(let values) = raw else { return nil }
                return values.compactMapValues(\.string)
            }
        }
        page.serverTime = Date(timeIntervalSince1970: 1800000000)
        page.providers["claude-code"] = .init(autoEligible: true, models: [], cells: [:], quota: .init(json: previewRoutingJSON(modelWindowJSON)))
        page.providers["codex-cli"]?.quota = .init(json: previewRoutingJSON(staleQuotaJSON))
        page.providers["copilot-cli"] = .init(autoEligible: false, reason: "auto_not_supported", models: [], cells: [:], quota: .init(state: "unknown", unknownReason: "not_supported"))
        var scopes: [String: CompanionHelperAuto.Scope] = ["app": .init(value: .enabled(true), editable: true, choices: [])]
        page.auto = .init(effective: true, source: "app", scopes: scopes)
        if agentID == dispatcherTarget.agentID {
            page.auto = .init(effective: false, source: "dispatcher_locked", reason: "dispatcher_locked", scopes: [
                "app": .init(value: .enabled(true), editable: false, choices: []), "agent": .init(value: .inherit, editable: false, choices: [])])
        } else if projectID != nil || agentID != nil {
            scopes["project"] = .init(value: projectID == "website" ? .off : .inherit, editable: true, choices: [.off, .inherit])
            if let agentID {
                // Juniper keeps its own switch on but doesn't orchestrate, so Auto is off (`decideHelperAuto` on the desktop).
                let notOrchestrating = agentID == sleepingTarget.agentID
                scopes["agent"] = .init(value: notOrchestrating ? .enabled(true) : .inherit, editable: true, choices: [])
                page.auto = .init(effective: !notOrchestrating, source: notOrchestrating ? "agent" : "app",
                                  reason: notOrchestrating ? "orchestration_off" : nil, scopes: scopes)
            } else {
                page.auto = .init(effective: projectID != "website", source: projectID == "website" ? "project" : "app",
                                  reason: projectID == "website" ? "project_off" : nil, scopes: scopes)
            }
        }
        return page
    }
    /// Multiple desktops deliberately repeat provider IDs: their accounts are not known to be the same.
    static func planLimitsHosts() -> [CompanionHost] {
        [
            .init(id: "preview-work", name: "Work Mac", endpoint: "work.local", connection: .connected, projects: [],
                  helperRouting: autoQuotaCapability, providers: [.init(id: "claude-code", name: "Claude Code"), .init(id: "codex-cli", name: "Codex CLI")]),
            .init(id: "preview-legacy", name: "Older Mac", endpoint: "older.local", connection: .connected, projects: [])
        ]
    }
    static var planLimitsPage: CompanionHelperRouting {
        var page = autoQuotaPage(projectID: nil, agentID: nil)
        page.providers.removeValue(forKey: "copilot-cli")
        page.providers["claude-code"]?.quota = .init(state: "low", asOf: page.serverTime,
            weekly: .init(usedPercent: 88, resetsAt: page.serverTime?.addingTimeInterval(86_400)),
            fiveHour: .init(usedPercent: 36, resetsAt: page.serverTime?.addingTimeInterval(3_600)), refreshAfterSeconds: 300)
        page.providers["codex-cli"]?.quota = .init(state: "unknown", unknownReason: "read_failed", asOf: page.serverTime,
            weekly: .init(usedPercent: nil, resetsAt: page.serverTime?.addingTimeInterval(86_400)), refreshAfterSeconds: 300)
        return page
    }
    private static func previewRoutingJSON(_ text: String) -> AnnexJSON { (try? JSONDecoder().decode(AnnexJSON.self, from: Data(text.utf8))) ?? .null }
    private static let autoQuotaCapabilityJSON = #"""
    {
      "autoOffReasons": [
        "not_enabled",
        "project_off",
        "orchestration_off",
        "mcp_off",
        "dispatcher_locked"
      ],
      "cellStates": [
        "valid",
        "unverified",
        "stale"
      ],
      "commands": [
        "helperRouting.update"
      ],
      "difficulties": [
        "easy",
        "medium",
        "hard"
      ],
      "event": "helper_routing:changed",
      "fallbacks": [
        "none",
        "builtin_preset",
        "candidate_skipped",
        "model_unverified"
      ],
      "modes": [
        "explicit",
        "preset",
        "auto"
      ],
      "path": "/api/v1/mobile/helper-routing",
      "quota": true,
      "quotaSources": [
        "cli_query",
        "session_event",
        "none"
      ],
      "quotaStates": [
        "known",
        "low",
        "near_limit",
        "exhausted",
        "unknown"
      ],
      "reasons": [
        "explicit_request",
        "persona_pinned",
        "preset_on_cli",
        "only_candidate",
        "lower_pressure",
        "lower_load",
        "fair_rotation",
        "better_quota_tier",
        "unknown_fallback",
        "sticky",
        "default_order"
      ],
      "scopes": [
        "app",
        "project",
        "agent"
      ],
      "skipped": [
        "cli_disabled",
        "cli_unavailable",
        "auto_not_supported",
        "no_valid_mapping",
        "cooling_down",
        "quota_near_limit",
        "quota_exhausted"
      ],
      "snapshotField": "helperRoutingRevision",
      "unknownReasons": [
        "not_read",
        "stale",
        "not_applicable",
        "read_failed",
        "not_supported"
      ],
      "version": 1
    }
    """#
    private static let autoQuotaLabelsJSON = #"""
    {
      "autoOff": {
        "dispatcher_locked": "The Dispatcher doesn’t start helpers",
        "mcp_off": "Clubhouse MCP is off for this agent",
        "not_enabled": "It isn’t turned on",
        "orchestration_off": "This agent doesn’t orchestrate",
        "project_off": "This project turned it off"
      },
      "autoSource": {
        "agent": "Set on this agent",
        "app": "Set for the whole app",
        "default": "Off unless turned on",
        "dispatcher_locked": "Not for the Dispatcher",
        "mcp_off": "Clubhouse MCP is off for this agent",
        "project": "Set for this project"
      },
      "cell": {
        "stale": "No longer offered",
        "unverified": "Couldn’t be checked",
        "valid": "Offered"
      },
      "fallback": {
        "builtin_preset": "The saved choice is no longer offered, so the default was used",
        "candidate_skipped": "Another provider was skipped",
        "model_unverified": "The model list may be out of date, so this couldn’t be checked",
        "none": "None",
        "retried_after_spawn_failure": "Started on another provider after the first failed to start"
      },
      "generic": {
        "unknownCode": "Clubhouse gave a reason this version can’t show"
      },
      "quota": {
        "exhausted": "Limit reached",
        "known": "Limit available",
        "low": "Limit getting low",
        "near_limit": "Close to the limit",
        "unknown": "Unknown"
      },
      "reason": {
        "better_quota_tier": "This provider has more of its limit left",
        "default_order": "No reason to switch",
        "explicit_request": "You or the orchestrator chose this",
        "fair_rotation": "Its turn among providers with the same usage",
        "lower_load": "Fewer helpers running on this provider",
        "lower_pressure": "Less of this provider’s weekly limit is used",
        "only_candidate": "The only provider available",
        "persona_pinned": "Set by the persona",
        "preset_on_cli": "From the helper settings for this difficulty",
        "sticky": "Stayed on the provider chosen last",
        "unknown_fallback": "Its usage couldn’t be checked, and the others are getting close to their limits"
      },
      "skipped": {
        "auto_not_supported": "Auto doesn’t support this provider yet",
        "cli_disabled": "Turned off in Settings",
        "cli_unavailable": "Not available on this computer",
        "cooling_down": "It failed to start recently",
        "no_valid_mapping": "No choice for this difficulty is offered now",
        "quota_exhausted": "The provider reports its limit reached",
        "quota_near_limit": "Close to its limit"
      },
      "unknown": {
        "not_applicable": "This login has no plan limit",
        "not_read": "Not checked yet",
        "not_supported": "This provider doesn’t report it",
        "read_failed": "Couldn’t check",
        "stale": "Last checked too long ago"
      },
      "window": {
        "fiveHour": "5-hour limit",
        "other": "Plan limit",
        "weekly": "Weekly limit"
      }
    }
    """#
    private static let modelWindowJSON = #"""
    {
      "asOf": "2027-01-15T08:00:00.000Z",
      "fiveHour": null,
      "limitingWindow": "weekly",
      "modelWindows": [
        {
          "name": "Fable",
          "resetsAt": "2027-01-18T08:00:00.000Z",
          "usedPercent": 99
        }
      ],
      "refreshAfterSeconds": 300,
      "resetsAt": "2027-01-18T08:00:00.000Z",
      "source": "cli_query",
      "state": "known",
      "weekly": {
        "resetsAt": "2027-01-18T08:00:00.000Z",
        "usedPercent": 41
      }
    }
    """#
    private static let staleQuotaJSON = #"""
    {
      "asOf": "2027-01-15T07:44:59.999Z",
      "fiveHour": null,
      "refreshAfterSeconds": 300,
      "source": "cli_query",
      "state": "unknown",
      "unknownReason": "stale",
      "weekly": null
    }
    """#
    private static let savedWarningJSON = #"""
    {
      "balanced": false,
      "context": {
        "status": "none"
      },
      "decidedAt": "2027-01-15T08:00:00.000Z",
      "display": {
        "reason": "You or the orchestrator chose this",
        "summary": "gpt-6.1-sol, high effort. You or the orchestrator chose this.",
        "warning": "codex-cli failed to start or hit its limit recently. The helper is started on it anyway, as asked."
      },
      "fallback": "none",
      "mode": "explicit",
      "policyVersion": 1,
      "reason": "explicit_request",
      "requested": {
        "difficulty": null,
        "effort": "high",
        "model": "gpt-6.1-sol",
        "provider": "codex-cli"
      },
      "resolved": {
        "difficulty": null,
        "effort": "high",
        "model": "gpt-6.1-sol",
        "provider": "codex-cli"
      },
      "source": {
        "effort": "request",
        "model": "request",
        "provider": "request"
      },
      "warning": {
        "asOf": "2027-01-15T08:00:00.000Z",
        "code": "cooling_down",
        "message": "codex-cli failed to start or hit its limit recently. The helper is started on it anyway, as asked."
      }
    }
    """#
}
