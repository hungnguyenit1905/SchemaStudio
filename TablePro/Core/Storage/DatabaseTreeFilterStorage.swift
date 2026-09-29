import Foundation

@MainActor
final class DatabaseTreeFilterStorage {
    static let shared = DatabaseTreeFilterStorage()

    private let defaults: UserDefaults
    private let connectionStorage: () -> ConnectionStorage

    init(
        defaults: UserDefaults = .standard,
        connectionStorage: @escaping @autoclosure () -> ConnectionStorage = .shared
    ) {
        self.defaults = defaults
        self.connectionStorage = connectionStorage
    }

    private func legacyDatabasesKey(connectionId: UUID) -> String {
        "com.SchemaStudio.treeDatabaseFilter.\(connectionId.uuidString).selected"
    }

    private func migratedKey(connectionId: UUID) -> String {
        "com.SchemaStudio.treeDatabaseFilter.\(connectionId.uuidString).migrated"
    }

    func settings(connectionId: UUID) -> DatabaseListSettings {
        let storage = connectionStorage()
        if let stored = storage.loadConnection(id: connectionId)?.databaseListSettings {
            return stored
        }
        guard !defaults.bool(forKey: migratedKey(connectionId: connectionId)) else { return .empty }
        let legacy = legacySelection(connectionId: connectionId)
        guard !legacy.isEmpty, storage.loadConnection(id: connectionId) != nil else { return .empty }
        let migrated = DatabaseListSettings(useCustomList: true, shown: legacy)
        if storage.updateDatabaseListSettings(migrated, for: connectionId) {
            defaults.set(true, forKey: migratedKey(connectionId: connectionId))
        }
        return migrated
    }

    func setSettings(_ settings: DatabaseListSettings, connectionId: UUID) {
        connectionStorage().updateDatabaseListSettings(settings, for: connectionId)
        defaults.set(true, forKey: migratedKey(connectionId: connectionId))
    }

    func selectedDatabases(connectionId: UUID) -> Set<String> {
        settings(connectionId: connectionId).filterSelection
    }

    func setSelectedDatabases(_ databases: Set<String>, connectionId: UUID) {
        var updated = settings(connectionId: connectionId)
        updated.useCustomList = !databases.isEmpty
        updated.shown = databases
        setSettings(updated, connectionId: connectionId)
    }

    func legacySelection(connectionId: UUID) -> Set<String> {
        guard let data = defaults.data(forKey: legacyDatabasesKey(connectionId: connectionId)),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    func removeFilter(for connectionId: UUID) {
        defaults.removeObject(forKey: legacyDatabasesKey(connectionId: connectionId))
        defaults.removeObject(forKey: migratedKey(connectionId: connectionId))
    }

    func removeFilters(for connectionIds: Set<UUID>) {
        for id in connectionIds {
            removeFilter(for: id)
        }
    }
}
