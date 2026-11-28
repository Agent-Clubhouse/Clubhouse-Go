import Foundation
import ClubhouseTransport

// RSA-2048 generation in `AnnexClientIdentity.ephemeral()` is 0.1 s to over a second of synchronous CPU per key.
// swift test starts every test at once on a cooperative pool only as wide as the runner's cores (3 on hosted
// macOS), and that pool never preempts a job. Generating the suite's ~30 keys there at startup held every pool
// thread for seconds, and a `Result { }` global made other tests touching it block in swift_once as well, so
// unrelated tests' live-clock waits went unscheduled past their deadlines. Keys are generated here on Dispatch
// threads, which the kernel time-slices, while the awaiting test suspends instead of holding a pool thread.

/// A fresh ephemeral identity, generated off the cooperative pool.
func ephemeralIdentity() async throws -> AnnexClientIdentity {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try AnnexClientIdentity.ephemeral() }) }
    }
}

/// One identity shared by a file's tests: generated off the pool on first use, and awaited, never blocked on.
final class SharedEphemeralIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AnnexClientIdentity, Error>?
    private var waiters: [CheckedContinuation<AnnexClientIdentity, Error>]?

    func get() async throws -> AnnexClientIdentity {
        try await withCheckedThrowingContinuation { continuation in
            enum Next { case done(Result<AnnexClientIdentity, Error>), generate, wait }
            let next: Next = lock.withLock {
                if let result { return .done(result) }
                if waiters == nil { waiters = [continuation]; return .generate }
                waiters!.append(continuation); return .wait
            }
            switch next {
            case .done(let result): continuation.resume(with: result)
            case .wait: break
            case .generate:
                DispatchQueue.global().async { [self] in
                    let generated = Result { try AnnexClientIdentity.ephemeral() }
                    let ready = lock.withLock { result = generated; defer { waiters = nil }; return waiters ?? [] }
                    ready.forEach { $0.resume(with: generated) }
                }
            }
        }
    }
}
