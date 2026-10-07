//
//  DatabaseListMigrationTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProImport
import Testing

@MainActor
@Suite("Connection Databases setting")
struct DatabaseListMigrationTests {
    private let settings = DatabaseListSettings(
        useCustomList: true,
        shown: ["app", "reports"],
        autoOpen: ["reports"]
    )

    private func makeStorage() throws -> ConnectionStorage {
        let suite = "DatabaseListMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        return ConnectionStorage(fileURL: fileURL, userDefaults: defaults, keychain: InMemoryKeychain())
    }

    @Test("The setting round-trips through the stored connection")
    func storedConnectionRoundTrip() throws {
        var connection = TestFixtures.makeConnection()
        connection.databaseListSettings = settings

        let data = try JSONEncoder().encode(StoredConnection(from: connection))
        let decoded = try JSONDecoder().decode(StoredConnection.self, from: data).toConnection()

        #expect(decoded.databaseListSettings == settings)
    }

    @Test("A stored connection written before the setting existed decodes without one")
    func oldStoredConnectionDecodes() throws {
        let data = try JSONEncoder().encode(StoredConnection(from: TestFixtures.makeConnection()))
        let decoded = try JSONDecoder().decode(StoredConnection.self, from: data).toConnection()

        #expect(decoded.databaseListSettings == nil)
    }

    @Test("An empty setting is not stored")
    func emptySettingIsDropped() {
        var connection = TestFixtures.makeConnection()
        connection.databaseListSettings = .empty

        #expect(StoredConnection(from: connection).databaseListSettings == nil)
    }

    @Test("Duplicating a connection keeps its Databases setting")
    func duplicateKeepsSetting() throws {
        let storage = try makeStorage()
        var connection = TestFixtures.makeConnection()
        connection.databaseListSettings = settings
        _ = storage.saveConnections([connection])

        let duplicate = storage.duplicateConnection(connection)

        #expect(duplicate.databaseListSettings == settings)
        #expect(storage.loadConnection(id: duplicate.id)?.databaseListSettings == settings)
    }

    @Test("Export and import carry the Databases setting")
    func exportCarriesSetting() {
        let exported = ConnectionExportService.exportable(settings)
        let imported = ConnectionExportService.databaseListSettings(exported)

        #expect(exported.shown == ["app", "reports"])
        #expect(imported == settings)
    }

    @Test("Auto Open skips the default database and hidden databases")
    func autoOpenSkipsDefaultAndHidden() {
        let custom = DatabaseListSettings(useCustomList: true, shown: ["app", "reports"], autoOpen: ["app", "reports", "gone"])
        #expect(custom.databasesToAutoOpen(defaultDatabase: "app") == ["reports"])

        let everything = DatabaseListSettings(useCustomList: false, shown: [], autoOpen: ["gone", "reports"])
        #expect(everything.databasesToAutoOpen(defaultDatabase: "app") == ["gone", "reports"])
    }
}
