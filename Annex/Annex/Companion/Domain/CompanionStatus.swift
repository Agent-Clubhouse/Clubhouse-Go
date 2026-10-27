import Foundation

enum CompanionAgentStatus: String, Sendable, Codable {
    case idle, working, approval, waiting, completed, failed, stopped, sleeping, starting
    /// The desktop's status word (`agent-status.tsx` DOT_LABEL), so an agent reads the same on both.
    var label: String { dot.label }
    /// Which of the desktop's six status dots this is. The phone keeps finer states (approval vs question,
    /// a finished quick agent, a cancelled one) for its own cards, but shows them as the desktop does.
    var dot: CompanionStatusDot {
        switch self {
        case .working: .working
        case .idle, .completed: .done
        case .approval, .waiting: .needsYou
        case .failed: .error
        case .sleeping, .stopped: .sleeping
        case .starting: .starting
        }
    }
    var symbol: String {
        switch self {
        case .idle: "checkmark.circle"
        case .working: "waveform"
        case .approval: "hand.raised.fill"
        case .waiting: "questionmark.bubble.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .sleeping: "moon.zzz"
        case .stopped: "stop.circle"
        case .starting: "circle.dotted"
        }
    }
    /// Approvals, questions and failures wait on the person holding the phone.
    var needsYou: Bool { self == .approval || self == .waiting || self == .failed }
}

/// The desktop's six agent status dots (`AgentDot` in `agent-status.tsx`). `done` is the desktop's `idle`:
/// an agent between turns.
enum CompanionStatusDot: String, Sendable, CaseIterable {
    case working, done, needsYou, error, sleeping, starting
    var label: String {
        switch self {
        case .working: "Working"
        case .done: "Done"
        case .needsYou: "Needs you"
        case .error: "Error"
        case .sleeping: "Sleeping"
        case .starting: "Starting"
        }
    }
    /// Sleeping and Starting are drawn as a ring rather than a filled dot, as on the desktop.
    var isHollow: Bool { self == .sleeping || self == .starting }
}

/// The Agents tab's filters, named with the desktop's status words. Needs you holds errors too, as the
/// desktop's Needs you list does; Done is an agent between turns, not a finished one.
enum CompanionAgentFilter: Hashable, CaseIterable, Sendable {
    case all, working, needsYou, done, sleeping
    var label: String {
        switch self {
        case .all: "All"
        case .working: CompanionStatusDot.working.label
        case .needsYou: CompanionStatusDot.needsYou.label
        case .done: CompanionStatusDot.done.label
        case .sleeping: CompanionStatusDot.sleeping.label
        }
    }
    func matches(_ status: CompanionAgentStatus) -> Bool {
        switch self {
        case .all: true
        case .working: status.dot == .working
        case .needsYou: status.needsYou
        case .done: status.dot == .done
        case .sleeping: status.dot == .sleeping
        }
    }
}

extension CompanionStatusDot {
    /// The desktop's dot colors (`DOT_COLOR`): Working green, Done and Starting blue, Needs you amber.
    func color(in palette: CompanionPalette) -> CompanionRGB {
        switch self {
        case .working: palette.success
        case .done, .starting: palette.info
        case .needsYou: palette.warning
        case .error: palette.error
        case .sleeping: palette.secondaryLabel
        }
    }
    /// The desktop's status text tone (`STATUS_TONE`): only Needs you and Error stand out.
    func textColor(in palette: CompanionPalette) -> CompanionRGB {
        switch self {
        case .needsYou: palette.warning
        case .error: palette.error
        default: palette.secondaryLabel
        }
    }
}
