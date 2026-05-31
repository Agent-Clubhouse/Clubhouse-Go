import Testing
import Foundation
@testable import ClubhouseGo

// Covers GH #96: outbound PTY input is parked while the socket is down and
// flushed in order on reconnect, instead of being silently lost.

struct OutboundQueueTests {
    @Test func startsEmpty() {
        let q = OutboundQueue()
        #expect(q.isEmpty)
        #expect(q.count == 0)
        #expect(q.droppedCount == 0)
    }

    @Test func enqueuePreservesFIFOOrder() {
        var q = OutboundQueue()
        q.enqueue("a")
        q.enqueue("b")
        q.enqueue("c")
        #expect(q.count == 3)
        #expect(!q.isEmpty)
        #expect(q.drain() == ["a", "b", "c"])
    }

    @Test func drainEmptiesTheQueue() {
        var q = OutboundQueue()
        q.enqueue("x")
        _ = q.drain()
        #expect(q.isEmpty)
        #expect(q.drain() == [])
    }

    @Test func enqueueReturnsZeroDropsUnderCapacity() {
        var q = OutboundQueue(capacity: 3)
        #expect(q.enqueue("a") == 0)
        #expect(q.enqueue("b") == 0)
        #expect(q.enqueue("c") == 0)
        #expect(q.droppedCount == 0)
    }

    @Test func dropsOldestPastCapacityAndKeepsMostRecent() {
        var q = OutboundQueue(capacity: 2)
        q.enqueue("a")
        q.enqueue("b")
        let dropped = q.enqueue("c") // pushes out "a"
        #expect(dropped == 1)
        #expect(q.droppedCount == 1)
        #expect(q.count == 2)
        #expect(q.drain() == ["b", "c"])
    }

    @Test func droppedCountAccumulatesAcrossEnqueues() {
        var q = OutboundQueue(capacity: 1)
        q.enqueue("a")
        q.enqueue("b") // drops a
        q.enqueue("c") // drops b
        #expect(q.droppedCount == 2)
        #expect(q.drain() == ["c"])
    }

    @Test func clearDiscardsWithoutResettingDropCount() {
        var q = OutboundQueue(capacity: 1)
        q.enqueue("a")
        q.enqueue("b") // drops a → droppedCount 1
        q.clear()
        #expect(q.isEmpty)
        #expect(q.droppedCount == 1)
    }

    @Test func capacityBoundaryExact() {
        var q = OutboundQueue(capacity: 3)
        for s in ["a", "b", "c"] { q.enqueue(s) }
        #expect(q.droppedCount == 0)
        #expect(q.count == 3)
        q.enqueue("d")
        #expect(q.drain() == ["b", "c", "d"])
    }
}
