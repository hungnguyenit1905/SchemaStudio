import Foundation
@testable import SchemaStudio
import Testing

@MainActor
@Suite("DatabaseTreeFilterStorage")
struct DatabaseTreeFilterStorageTests {
    private struct Fixture {
        let storage: DatabaseTreeFilterStorage
        let connections: ConnectionStorage
        let defaults: UserDefaults
    }

    private func makeFixture(connections ids: [UUID]) throws -> Fixture {
        let suite = "DatabaseTreeFilterStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let connections = ConnectionStorage(fileURL: fileURL, userDefaults: defaults, keychain: InMemoryKeychain())
        _ = connections.saveConnections(ids.map { TestFixtures.makeConnection(id: $0) })
        return Fixture(
            storage: DatabaseTreeFilterStorage(defaults: defaults, connectionStorage: connections),
            connections: connections,
            defaults: defaults
        )
    }

    @Test("Defaults to an empty selection")
    func defaultsEmpty() throws {
        let id = UUID()
        let fixture = try makeFixture(connections: [id])
        #expect(fixture.storage.selectedDatabases(connectionId: id).isEmpty)
    }

    @Test("Selected databases round-trip through the connection")
    func selectedRoundTrip() throws {
        let id = UUID()
        let fixture = try makeFixture(connections: [id])
        fixture.storage.setSelectedDatabases(["db1", "db2"], connectionId: id)

        #expect(fixture.storage.selectedDatabases(connectionId: id) == ["db1", "db2"])
        #expect(fixture.connections.loadConnection(id: id)?.databaseListSettings?.useCustomList == true)
    }

    @Test("Setting an empty selection turns the custom list off")
    func emptySelectionClears() throws {
        let id = UUID()
        let fixture = try makeFixture(connections: [id])
        fixture.storage.setSelectedDatabases(["db1"], connectionId: id)
        fixture.storage.setSelectedDatabases([], connectionId: id)

        #expect(fixture.storage.selectedDatabases(connectionId: id).isEmpty)
        #expect(fixture.connections.loadConnection(id: id)?.databaseListSettings == nil)
    }

    @Test("Selection is isolated per connection")
    func perConnectionIsolation() throws {
        let a = UUID()
        let b = UUID()
        let fixture = try makeFixture(connections: [a, b])
        fixture.storage.setSelectedDatabases(["x"], connectionId: a)

        #expect(fixture.storage.selectedDatabases(connectionId: b).isEmpty)
        #expect(fixture.storage.selectedDatabases(connectionId: a) == ["x"])
    }

    @Test("Changing the list keeps the Auto Open databases")
    func selectionKeepsAutoOpen() throws {
        let id = UUID()
        let fixture = try makeFixture(connections: [id])
        fixture.storage.setSettings(DatabaseListSettings(autoOpen: ["reports"]), connectionId: id)
        fixture.storage.setSelectedDatabases(["reports", "app"], connectionId: id)

        #expect(fixture.storage.settings(connectionId: id).autoOpen == ["reports"])
    }

    @Test("A legacy sidebar filter migrates into the connection's custom list once")
    func legacyFilterMigrates() throws {
        let id = UUID()
        let fixture = try makeFixture(connections: [id])
        let legacyKey = "com.SchemaStudio.treeDatabaseFilter.\(id.uuidString).selected"
        fixture.defaults.set(try JSONEncoder().encode(["billing", "analytics"]), forKey: legacyKey)

        let migrated = fixture.storage.settings(connectionId: id)

        #expect(migrated == DatabaseListSettings(useCustomList: true, shown: ["billing", "analytics"]))
        #expect(fixture.connections.loadConnection(id: id)?.databaseListSettings == migrated)
        #expect(fixture.storage.legacySelection(connectionId: id) == ["billing", "analytics"])
    }

    @Test("A cleared list is not migrated again from the legacy key")
    func migrationRunsOnce() throws {
        let id = UUID()
        let fixture = try makeFixture(connections: [id])
        let legacyKey = "com.SchemaStudio.treeDatabaseFilter.\(id.uuidString).selected"
        fixture.defaults.set(try JSONEncoder().encode(["billing"]), forKey: legacyKey)

        _ = fixture.storage.settings(connectionId: id)
        fixture.storage.setSelectedDatabases([], connectionId: id)

        #expect(fixture.storage.selectedDatabases(connectionId: id).isEmpty)
    }

    @Test("Remove filter drops the legacy value")
    func removeClearsLegacy() throws {
        let id = UUID()
        let fixture = try makeFixture(connections: [id])
        let legacyKey = "com.SchemaStudio.treeDatabaseFilter.\(id.uuidString).selected"
        fixture.defaults.set(try JSONEncoder().encode(["billing"]), forKey: legacyKey)

        fixture.storage.removeFilters(for: [id])

        #expect(fixture.storage.legacySelection(connectionId: id).isEmpty)
    }
}
