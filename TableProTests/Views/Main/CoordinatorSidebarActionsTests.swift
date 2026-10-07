//
//  CoordinatorSidebarActionsTests.swift
//  TableProTests
//
//  Tests for sidebar action guard conditions on MainContentCoordinator.
//

import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("CoordinatorSidebarActions")
struct CoordinatorSidebarActionsTests {
    // MARK: - Helpers

    @MainActor
    private func makeCoordinator(
        type: DatabaseType = .mysql,
        safeModeLevel: SafeModeLevel = .silent
    ) -> (MainContentCoordinator, QueryTabManager) {
        var connection = TestFixtures.makeConnection(type: type)
        connection.safeModeLevel = safeModeLevel
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
        return (coordinator, tabManager)
    }

    @MainActor
    private func scope(of coordinator: MainContentCoordinator, database: String = "testdb") -> DatabaseScope {
        DatabaseScope(connectionId: coordinator.connectionId, database: database, schema: nil)
    }

    // MARK: - createView

    @Test("createView with readOnly safe mode returns early without crashing")
    @MainActor
    func createViewBlockedByReadOnlySafeMode() {
        let (coordinator, _) = makeCoordinator(safeModeLevel: .readOnly)
        defer { coordinator.teardown() }

        coordinator.createView(scope: scope(of: coordinator))
    }

    @Test("createView does not crash for each database type", arguments: [
        DatabaseType.mysql, .mariadb, .postgresql, .sqlite, .redshift,
        .clickhouse, .mssql, .oracle, .mongodb, .redis, .duckdb,
    ])
    @MainActor
    func createViewDoesNotCrash(type: DatabaseType) {
        let (coordinator, _) = makeCoordinator(type: type)
        defer { coordinator.teardown() }

        coordinator.createView(scope: scope(of: coordinator))
    }

    // MARK: - openImportDialog

    @Test("openImportDialog with readOnly safe mode returns early without crashing")
    @MainActor
    func openImportDialogBlockedByReadOnlySafeMode() {
        let (coordinator, _) = makeCoordinator(safeModeLevel: .readOnly)
        defer { coordinator.teardown() }

        coordinator.openImportDialog(formatId: "sql", scope: scope(of: coordinator))
    }

    @Test("openImportDialog with MongoDB returns early at type guard")
    @MainActor
    func openImportDialogBlockedForMongoDB() {
        let (coordinator, _) = makeCoordinator(type: .mongodb)
        defer { coordinator.teardown() }

        coordinator.openImportDialog(formatId: "sql", scope: scope(of: coordinator))
    }

    @Test("openImportDialog with Redis returns early at type guard")
    @MainActor
    func openImportDialogBlockedForRedis() {
        let (coordinator, _) = makeCoordinator(type: .redis)
        defer { coordinator.teardown() }

        coordinator.openImportDialog(formatId: "sql", scope: scope(of: coordinator))
    }

    // MARK: - openExportDialog

    @Test("openExportDialog sets activeSheet to exportDialog")
    @MainActor
    func openExportDialogSetsActiveSheet() {
        let (coordinator, _) = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.openExportDialog(scope: scope(of: coordinator, database: "reports"))

        #expect(coordinator.activeSheet?.id == "exportDialog")
        #expect(coordinator.exportScope == scope(of: coordinator, database: "reports"))
    }

    @Test("Maintenance carries the table's own scope")
    @MainActor
    func maintenanceCarriesScope() {
        let (coordinator, _) = makeCoordinator()
        defer { coordinator.teardown() }
        let target = scope(of: coordinator, database: "reports")

        coordinator.showMaintenanceSheet(operation: "OPTIMIZE", tableName: "users", scope: target)

        guard case .maintenance(_, let tableName, let sheetScope) = coordinator.activeSheet else {
            Issue.record("expected the maintenance sheet")
            return
        }
        #expect(tableName == "users")
        #expect(sheetScope == target)
    }

    @Test("A read-only connection cannot create a table on any of its databases")
    @MainActor
    func createTableBlockedByReadOnly() {
        let (coordinator, tabManager) = makeCoordinator(safeModeLevel: .readOnly)
        defer { coordinator.teardown() }
        coordinator.setSafeModeLevel(.readOnly)

        coordinator.createNewTable(scope: scope(of: coordinator, database: "reports"))

        #expect(tabManager.tabs.isEmpty)
    }

    @Test("Creating a table on an empty window uses the scope's database")
    @MainActor
    func createTableUsesScopeDatabase() {
        let (coordinator, tabManager) = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.createNewTable(scope: scope(of: coordinator, database: "reports"))

        #expect(tabManager.tabs.first?.tableContext.databaseName == "reports")
    }
}
