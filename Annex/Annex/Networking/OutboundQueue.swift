import Foundation

/// Bounded FIFO of encoded WebSocket messages awaiting transmission.
///
/// When the socket is down — i.e. the connection is `.reconnecting` or
/// `.disconnected` — outbound PTY input would otherwise be fired into a dead
/// socket and silently lost (GH #96: `"Socket is not connected"`). Such
/// messages are parked here and flushed, in order, once the connection is
/// restored.
///
/// The queue is bounded: past `capacity` the oldest entries are dropped so a
/// long outage can't grow memory without limit. Drops are counted (never
/// silent) so they can be logged.
struct OutboundQueue: Equatable {
    private(set) var messages: [String]
    let capacity: Int
    private(set) var droppedCount: Int

    init(capacity: Int = 256) {
        precondition(capacity > 0, "OutboundQueue capacity must be positive")
        self.capacity = capacity
        self.messages = []
        self.droppedCount = 0
    }

    var count: Int { messages.count }
    var isEmpty: Bool { messages.isEmpty }

    /// Append a message. If this pushes the queue past `capacity`, the oldest
    /// message(s) are discarded (we keep the most recent input). Returns the
    /// number of messages dropped by this call.
    @discardableResult
    mutating func enqueue(_ message: String) -> Int {
        messages.append(message)
        var dropped = 0
        while messages.count > capacity {
            messages.removeFirst()
            droppedCount += 1
            dropped += 1
        }
        return dropped
    }

    /// Remove and return all queued messages in FIFO order.
    mutating func drain() -> [String] {
        defer { messages.removeAll() }
        return messages
    }

    /// Discard all queued messages without returning them (e.g. on a
    /// user-initiated disconnect). Does not reset `droppedCount`.
    mutating func clear() {
        messages.removeAll()
    }
}
