//
//  AutoOpenDatabasesTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Auto Open databases", .serialized)
@MainActor
struct AutoOpenDatabasesTests {
    private func inject(type: DatabaseType = .mysql, settings: DatabaseListSettings?) -> DatabaseConnection {
        var connection = TestFixtures.makeConnection(database: "app", type: type)
        connection.databaseListSettings = settings
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        session.status = .connected
        DatabaseManager.shared.seedOpenDatabases(&session)
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    @Test("Auto Open databases open on connect next to the default")
    func autoOpenOpensTheList() async {
        let connection = inject(settings: DatabaseListSettings(autoOpen: ["reports", "archive"]))
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        DatabaseManager.shared.openAutoOpenDatabases(for: connection.id)
        while DatabaseManager.shared.openDatabases(for: connection.id).count < 3 { await Task.yield() }

        #expect(DatabaseManager.shared.openDatabases(for: connection.id) == ["app", "reports", "archive"])
    }

    @Test("A connection without the setting opens only its default database")
    func noSettingOpensOnlyTheDefault() {
        let connection = inject(settings: nil)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.autoOpenDatabases(for: connection.id).isEmpty)
        #expect(DatabaseManager.shared.openDatabases(for: connection.id) == ["app"])
    }

    @Test("A database that fails to open stays closed and the connection stays up")
    func failedOpenStaysClosed() async {
        let connection = inject(type: .postgresql, settings: DatabaseListSettings(autoOpen: ["missing"]))
        defer {
            DatabaseManager.shared.closeAllDatabaseSessions(for: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        let original = DatabaseManager.shared.databaseDriverOpener
        var attempted = false
        DatabaseManager.shared.databaseDriverOpener = { _ in
            attempted = true
            throw DatabaseError.connectionFailed("database \"missing\" does not exist")
        }
        defer { DatabaseManager.shared.databaseDriverOpener = original }

        DatabaseManager.shared.openAutoOpenDatabases(for: connection.id)
        while !attempted { await Task.yield() }
        await Task.yield()

        #expect(!DatabaseManager.shared.isDatabaseOpen("missing", for: connection.id))
        #expect(DatabaseManager.shared.session(for: connection.id)?.isConnected == true)
    }

    @Test("The Databases pane builds the setting from its rows")
    func paneBuildsSettings() {
        let model = ConnectionDatabasesPaneViewModel()
        var connection = TestFixtures.makeConnection(type: .postgresql)
        connection.databaseListSettings = DatabaseListSettings(useCustomList: true, shown: ["app"], autoOpen: [])
        model.load(from: connection, liveDatabases: ["app", "reports"])

        model.rows[1].opensAutomatically = true
        model.newDatabaseName = "archive"
        model.addDatabase()

        let settings = model.settings(for: .postgresql)
        #expect(settings?.shown == ["app", "archive"])
        #expect(settings?.autoOpen == ["reports"])
        #expect(model.settings(for: .sqlite) == nil)
    }

    @Test("The Databases pane is offered only for engines with a database level", arguments: [
        (DatabaseType.postgresql, true), (.mssql, true), (.mysql, true), (.mongodb, true), (.sqlite, false)
    ])
    func paneVisibility(type: DatabaseType, isShown: Bool) {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.network.type = type

        #expect(coordinator.visiblePanes.contains(.databases) == isShown)
    }
}
