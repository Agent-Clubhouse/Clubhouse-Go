/// Holds a side-effectful dependency for a SwiftUI State lifetime. Creating an unused initial
/// value must not create clients, install global sinks or start tasks: SwiftUI may evaluate a
/// View initializer repeatedly while keeping the original State value.
@MainActor final class CompanionStateLifetime<Value> {
    // ARC-only teardown; reviewed in docs/isolated-deinit.md.
    nonisolated deinit {}
    private let makeValue: () -> Value
    private var cached: Value?
    init(_ makeValue: @escaping () -> Value) { self.makeValue = makeValue }
    var value: Value {
        if let cached { return cached }
        let value = makeValue()
        cached = value
        return value
    }
}
