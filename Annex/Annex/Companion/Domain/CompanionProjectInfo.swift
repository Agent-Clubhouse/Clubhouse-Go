import Foundation

/// Presentation of values already returned by create-options. Missing data never becomes a guessed default.
nonisolated struct CompanionProjectInfoDefaults: Equatable, Sendable {
    let access: String?
    /// Nil means unreported; an empty array is the desktop's explicit selection of no default servers.
    let mcpServers: [String]?

    init(options: CompanionCreateOptions) {
        access = options.defaultAccess.map { level in
            options.options.accessLevels.first { $0.id == level }?.label ?? level.label
        }
        if options.mcpDefaultsReported {
            var seen: Set<String> = []
            mcpServers = options.mcpDefaults.filter { seen.insert($0).inserted }.map { id in
                options.mcpCatalog.first { $0.id == id }?.name ?? id
            }
        } else { mcpServers = nil }
    }
}
