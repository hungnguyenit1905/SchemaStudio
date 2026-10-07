//
//  SwitchDatabaseTests.swift
//  TableProTests
//
//  Every tab owns its database. Opening a table in another database or moving a tab to
//  another database never changes the session's default database or any other tab.
//

import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("SwitchDatabase")
@MainActor
struct SwitchDatabaseTests {
    private func withConnectedCoordinator(
        _ body: (MainContentCoordinator, QueryTabManager) async throws -> Void
    ) async throws {
        let connection = TestFixtures.makeConnection(database: "db_a", type: .mysql)
        let driver = MockDatabaseDriver(connection: connection)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: driver),
            for: connection.id
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        defer { coordinator.teardown() }

        try await body(coordinator, tabManager)
    }

    @Test("openTableTab skips when table is already active tab in same database")
    func openTableTabSkipsForSameTableSameDatabase() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        defer { coordinator.teardown() }

        try tabManager.addTableTab(tableName: "users", databaseType: .mysql, databaseName: "db_a")
        let tabCountBefore = tabManager.tabs.count

        coordinator.openTableTab("users")

        #expect(tabManager.tabs.count == tabCountBefore)
    }

    // MARK: - Tab-owned databases

    @Test("Opening a table in another database leaves the session default and other tabs alone")
    func openingInAnotherDatabaseLeavesSessionAlone() async throws {
        try await withConnectedCoordinator { coordinator, tabManager in
            tabManager.addTab(initialQuery: "SELECT NOW()", databaseName: "db_a")
            let connectionId = coordinator.connectionId

            coordinator.openTableTab(
                TableInfo(name: "orders", type: .table, rowCount: nil, schema: nil),
                scope: DatabaseScope(connectionId: connectionId, database: "db_b", schema: nil)
            )

            #expect(DatabaseManager.shared.session(for: connectionId)?.resolvedBrowseDatabase == "db_a")
            #expect(tabManager.tabs.first?.tableContext.databaseName == "db_a")
        }
    }

    @Test("A tab's scope follows the tab's own database, not the session")
    func tabScopeFollowsTheTab() async throws {
        try await withConnectedCoordinator { coordinator, tabManager in
            tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_b")
            let tab = try #require(tabManager.tabs.first)

            #expect(coordinator.scope(for: tab)?.database == "db_b")
            #expect(DatabaseManager.shared.session(for: coordinator.connectionId)?.resolvedBrowseDatabase == "db_a")
        }
    }

    @Test("An unscoped open lands on the focused tab's database")
    func unscopedOpenUsesFocusedTab() async throws {
        try await withConnectedCoordinator { coordinator, tabManager in
            tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_b")

            #expect(coordinator.selectedTabScope?.database == "db_b")
        }
    }
}
