import Foundation

enum AgentStatus: Codable, Hashable, Sendable {
    case starting, running, sleeping, error
    case completed, failed, cancelled
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "starting": self = .starting
        case "running": self = .running
        case "sleeping": self = .sleeping
        case "error": self = .error
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .starting: return "starting"
        case .running: return "running"
        case .sleeping: return "sleeping"
        case .error: return "error"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .unknown(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self.init(rawValue: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentState: String, Codable, Hashable, Sendable {
    case idle, working
    case needsPermission = "needs_permission"
    case toolError = "tool_error"
}

struct AgentDetailedStatus: Hashable, Codable, Sendable {
    let state: AgentState
    let message: String
    let toolName: String?
    let timestamp: Int
}
