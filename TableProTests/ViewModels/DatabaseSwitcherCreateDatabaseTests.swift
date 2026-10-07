//
//  DatabaseSwitcherCreateDatabaseTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("DatabaseSwitcherViewModel createDatabase")
@MainActor
struct DatabaseSwitcherCreateDatabaseTests {
    @Test("creating a database adds it to the sidebar database list")
    func createRefreshesSidebarList() async throws {
        let connection = TestFixtures.makeConnection(type: .pglite)
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let service = DatabaseTreeMetadataService.shared
        driver.databasesToReturn = [connection.database]
        await service.loadDatabases(connectionId: connection.id, databaseType: connection.type)

        let viewModel = DatabaseSwitcherViewModel(
            connectionId: connection.id,
            currentDatabase: nil,
            databaseType: connection.type
        )
        driver.databasesToReturn = [connection.database, "reports"]
        try await viewModel.createDatabase(name: "reports", values: [:])

        #expect(service.databases(for: connection.id).map(\.name) == ["reports", connection.database])

        await service.handleDisconnect(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }
}
