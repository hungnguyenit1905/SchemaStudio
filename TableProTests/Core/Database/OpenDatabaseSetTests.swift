//
//  OpenDatabaseSetTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("Open database set", .serialized)
@MainActor
struct OpenDatabaseSetTests {
    private func inject(
        database: String = "app",
        type: DatabaseType = .mysql,
        open: Set<String> = []
    ) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: database, type: type)
        var session = ConnectionSession(connection: connection)
        session.driver = MockDatabaseDriver()
        session.status = .connected
        session.openDatabases = open
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    @Test("The session default database is always open")
    func defaultDatabaseIsOpen() {
        let connection = inject()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.isDatabaseOpen("app", for: connection.id))
        #expect(DatabaseManager.shared.openDatabases(for: connection.id) == ["app"])
    }

    @Test("Opening a database is idempotent and keeps others open")
    func openingIsIdempotent() async throws {
        let connection = inject()
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.markDatabaseOpen("reports", for: connection.id)
        try await DatabaseManager.shared.markDatabaseOpen("reports", for: connection.id)
        try await DatabaseManager.shared.markDatabaseOpen("archive", for: connection.id)

        #expect(DatabaseManager.shared.openDatabases(for: connection.id) == ["app", "reports", "archive"])
    }

    @Test("The session default database cannot be closed")
    func defaultDatabaseIsNotClosable() {
        let connection = inject(open: ["app"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(!DatabaseManager.shared.markDatabaseClosed("app", for: connection.id))
        #expect(DatabaseManager.shared.isDatabaseOpen("app", for: connection.id))
    }

    @Test("Closing a non-default database removes only that database")
    func closingRemovesOnlyThatDatabase() {
        let connection = inject(open: ["app", "reports", "archive"])
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.markDatabaseClosed("reports", for: connection.id))
        #expect(DatabaseManager.shared.openDatabases(for: connection.id) == ["app", "archive"])
        #expect(!DatabaseManager.shared.markDatabaseClosed("reports", for: connection.id))
    }

    @Test("Opening a database without a session fails")
    func openingWithoutSessionFails() async {
        await #expect(throws: DatabaseError.self) {
            try await DatabaseManager.shared.markDatabaseOpen("app", for: UUID())
        }
    }

    @Test("Removing the session clears its open set")
    func removingSessionClearsOpenSet() async throws {
        let connection = inject()
        try await DatabaseManager.shared.markDatabaseOpen("reports", for: connection.id)

        DatabaseManager.shared.removeSession(for: connection.id)

        #expect(DatabaseManager.shared.openDatabases(for: connection.id).isEmpty)
        #expect(!DatabaseManager.shared.isDatabaseOpen("reports", for: connection.id))
    }

    @Test("A failed connect leaves nothing open")
    func failedConnectLeavesNothingOpen() {
        let connection = inject()

        DatabaseManager.shared.finalizeConnectionFailure(for: connection.id, cancelled: false)

        #expect(DatabaseManager.shared.openDatabases(for: connection.id).isEmpty)
    }

    @Test("Disconnect clears the open set")
    func disconnectClearsOpenSet() async throws {
        let connection = inject()
        try await DatabaseManager.shared.markDatabaseOpen("reports", for: connection.id)

        await DatabaseManager.shared.disconnectSession(connection.id)

        #expect(DatabaseManager.shared.openDatabases(for: connection.id).isEmpty)
    }

    @Test("An engine without a database level counts as open while connected")
    func engineWithoutDatabaseLevelIsOpenWhenConnected() async throws {
        let connection = inject(database: "/tmp/file.sqlite", type: .sqlite)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.markDatabaseOpen("other", for: connection.id)

        #expect(DatabaseManager.shared.isDatabaseOpen("anything", for: connection.id))
        #expect(DatabaseManager.shared.openDatabases(for: connection.id).isEmpty)
    }

    @Test("Seeding on connect opens the default database only")
    func seedingOpensTheDefault() {
        var session = ConnectionSession(connection: TestFixtures.makeConnection(database: "app"))
        session.openDatabases = ["stale"]
        session.openDatabases = []

        DatabaseManager.shared.seedOpenDatabases(&session)

        #expect(session.openDatabases == ["app"])
    }

    @Test("Seeding a connection with no database opens nothing")
    func seedingWithoutDatabaseOpensNothing() {
        var session = ConnectionSession(connection: TestFixtures.makeConnection(database: ""))

        DatabaseManager.shared.seedOpenDatabases(&session)

        #expect(session.openDatabases.isEmpty)
    }
}
