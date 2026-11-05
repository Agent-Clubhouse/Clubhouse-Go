import Foundation
#if canImport(ClubhouseTransport)
import ClubhouseTransport
#endif
import Observation

/// Identity is always desktop-local. Never combine provider readings across accounts or machines.
struct CompanionPlanLimitsGroup: Identifiable, Sendable {
    let host: CompanionHost
    var id: String { host.id }
    var canRead: Bool { host.connection.canOperate && host.helperRouting?.version == 1 && host.helperRouting?.quota == true }
    var unavailableText: String? {
        if !host.connection.canOperate { return host.connection.sentence(hostName: host.name) }
        if !canRead { return "This desktop doesn’t report plan limits." }
        return nil
    }
    static func groups(_ hosts: [CompanionHost]) -> [Self] { hosts.map { Self(host: $0) } }
    func providerIDs(in page: CompanionHelperRouting) -> [String] {
        Set(host.providers.map(\.id)).union(page.providers.keys).sorted()
    }
}

/// Screen-owned snapshots; no retained task, timer, service or callback. SwiftUI owns polling lifetime.
@MainActor @Observable final class CompanionPlanLimitsScreen {
    private(set) var readings: [String: CompanionHelperPresetsScreen] = [:]
    nonisolated deinit {}

    func load(hostID: String, read: @MainActor @Sendable (String) async throws -> CompanionHelperRouting) async {
        let reading: CompanionHelperPresetsScreen
        if let existing = readings[hostID] { reading = existing }
        else { reading = CompanionHelperPresetsScreen(); readings[hostID] = reading }
        await reading.load {
            let page = try await read(hostID)
            try Task.checkCancellation()
            return page
        }
    }
    func refresh(hosts: [CompanionHost], read: @escaping @MainActor @Sendable (String) async throws -> CompanionHelperRouting) async {
        await withTaskGroup(of: Void.self) { group in
            let ids = CompanionPlanLimitsGroup.groups(hosts).filter(\.canRead).map(\.id)
            for id in ids {
                group.addTask { await self.load(hostID: id, read: read) }
            }
        }
    }
    func poll(hostID: String, read: @escaping @MainActor @Sendable (String) async throws -> CompanionHelperRouting) async {
        repeat {
            guard !Task.isCancelled else { return }
            await load(hostID: hostID, read: read)
            guard !Task.isCancelled, let delay = readings[hostID]?.settings?.nextRefreshDelay else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        } while !Task.isCancelled
    }
}
