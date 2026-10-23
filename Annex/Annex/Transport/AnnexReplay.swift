import Foundation

nonisolated public struct AnnexBackoff: Sendable {
    public let initialSeconds: Double
    public let maximumSeconds: Double
    public init(initialSeconds: Double = 0.5, maximumSeconds: Double = 30) {
        self.initialSeconds = initialSeconds.isFinite ? max(0.05, initialSeconds) : 0.5
        self.maximumSeconds = maximumSeconds.isFinite ? max(self.initialSeconds, maximumSeconds) : 30
    }
    /// Equal jitter avoids synchronized reconnect storms without an immediate retry loop.
    public func delay(attempt: Int, randomUnit: Double = Double.random(in: 0...1)) -> Double {
        let ceiling = min(maximumSeconds, initialSeconds * pow(2, Double(min(30, max(0, attempt - 1)))))
        let random = randomUnit.isFinite ? min(1, max(0, randomUnit)) : 0.5
        return ceiling * (0.5 + random * 0.5)
    }
}

/// Cursor belongs to one host connection, never shared among hosts. Snapshot
/// connection boundaries are authoritative; refreshes never rewind it.
/// A reconnect requests history refresh explicitly;
/// global Annex seq is distinct from chat's per-session seq.
nonisolated public struct AnnexReplayCursor: Sendable {
    public private(set) var lastSequence: Int64?
    public private(set) var epoch: String?
    private var needsSnapshot = true
    public init() {}
    public mutating func beginConnection() { needsSnapshot = true }
    public enum Decision: Equatable, Sendable { case deliver, duplicate, resync(AnnexResyncReason) }
    public mutating func accept(_ envelope: AnnexEnvelope) -> Decision {
        if envelope.type == "snapshot" {
            guard let sequence = envelope.snapshotSequence, sequence >= 0 else { return .resync(.sequenceGap) }
            if !needsSnapshot, let lastSequence {
                if let nextEpoch = envelope.epoch, let epoch, nextEpoch != epoch { return .resync(.serverRestart) }
                if sequence < lastSequence { return .duplicate }
                // A catalog snapshot does not contain chat deltas. Keep the
                // previous cursor so replay can recover every skipped event.
                if sequence > lastSequence { return .resync(.sequenceGap) }
                return .deliver
            }
            needsSnapshot = false
            let restarted = (envelope.epoch != nil && epoch != nil && envelope.epoch != epoch)
                || (envelope.snapshotSequence != nil && lastSequence != nil && envelope.snapshotSequence! < lastSequence!)
            lastSequence = sequence
            epoch = envelope.epoch
            return restarted ? .resync(.serverRestart) : .deliver
        }
        if envelope.type == "replay:gap" { return .resync(.replayGap) }
        if let nextEpoch = envelope.epoch, let epoch, nextEpoch != epoch { return .resync(.serverRestart) }
        guard let seq = envelope.seq else { return .deliver }
        guard seq >= 0 else { return .resync(.sequenceGap) }
        if let lastSequence {
            if seq <= lastSequence { return .duplicate }
            if seq - lastSequence > 1 { return .resync(.sequenceGap) }
        }
        lastSequence = seq
        return .deliver
    }
}
