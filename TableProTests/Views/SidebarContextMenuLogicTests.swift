//
//  SidebarContextMenuLogicTests.swift
//  TableProTests
//
//  Tests for SidebarContextMenu computed property logic extracted into SidebarContextMenuLogic.
//

@testable import SchemaStudio
import SwiftUI
import TableProPluginKit
import Testing

@Suite("SidebarContextMenuLogicTests")
struct SidebarContextMenuLogicTests {
    // MARK: - hasSelection

    @Test("hasSelection false when empty selection and no clicked table")
    func hasSelectionEmpty() {
        #expect(!SidebarContextMenuLogic.hasSelection(selectedTables: [], clickedTable: nil))
    }

    @Test("hasSelection true when clicked table exists")
    func hasSelectionClickedOnly() {
        let table = TestFixtures.makeTableInfo(name: "users")
        #expect(SidebarContextMenuLogic.hasSelection(selectedTables: [], clickedTable: table))
    }

    @Test("hasSelection true when selection exists")
    func hasSelectionSelectedOnly() {
        let table = TestFixtures.makeTableInfo(name: "users")
        #expect(SidebarContextMenuLogic.hasSelection(selectedTables: [table], clickedTable: nil))
    }

    @Test("hasSelection true when both exist")
    func hasSelectionBoth() {
        let t1 = TestFixtures.makeTableInfo(name: "users")
        let t2 = TestFixtures.makeTableInfo(name: "orders")
        #expect(SidebarContextMenuLogic.hasSelection(selectedTables: [t1], clickedTable: t2))
    }

    // MARK: - isView

    @Test("isView true for view type")
    func isViewTrue() {
        let view = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(SidebarContextMenuLogic.isView(clickedTable: view))
    }

    @Test("isView false for table type")
    func isViewFalseForTable() {
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(!SidebarContextMenuLogic.isView(clickedTable: table))
    }

    @Test("isView false for nil")
    func isViewFalseForNil() {
        #expect(!SidebarContextMenuLogic.isView(clickedTable: nil))
    }

    // MARK: - Import Visibility

    @Test("Import visible for table with import support")
    func importVisibleForTable() {
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(SidebarContextMenuLogic.importVisible(clickedTable: table, supportsImport: true))
    }

    @Test("Import hidden for view")
    func importHiddenForView() {
        let view = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: view, supportsImport: true))
    }

    @Test("Import hidden for materialized view")
    func importHiddenForMaterializedView() {
        let mv = TestFixtures.makeTableInfo(name: "mv", type: .materializedView)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: mv, supportsImport: true))
    }

    @Test("Import hidden for foreign table")
    func importHiddenForForeignTable() {
        let ft = TestFixtures.makeTableInfo(name: "ft", type: .foreignTable)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: ft, supportsImport: true))
    }

    @Test("Import hidden when import not supported")
    func importHiddenWhenNotSupported() {
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: table, supportsImport: false))
    }

    // MARK: - Truncate Visibility

    @Test("Truncate visible for table")
    func truncateVisibleForTable() {
        let table = TestFixtures.makeTableInfo(name: "t", type: .table)
        #expect(SidebarContextMenuLogic.truncateVisible(clickedTable: table))
    }

    @Test("Truncate hidden for view")
    func truncateHiddenForView() {
        let view = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: view))
    }

    @Test("Truncate hidden for materialized view")
    func truncateHiddenForMaterializedView() {
        let mv = TestFixtures.makeTableInfo(name: "mv", type: .materializedView)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: mv))
    }

    @Test("Truncate hidden for foreign table")
    func truncateHiddenForForeignTable() {
        let ft = TestFixtures.makeTableInfo(name: "ft", type: .foreignTable)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: ft))
    }

    @Test("Truncate hidden for system table")
    func truncateHiddenForSystemTable() {
        let sys = TestFixtures.makeTableInfo(name: "s", type: .systemTable)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: sys))
    }

    // MARK: - Delete Label per Kind

    @Test("Delete label for table")
    func deleteLabelForTable() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .table) == "Delete")
    }

    @Test("Delete label for view")
    func deleteLabelForView() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .view) == "Drop View")
    }

    @Test("Delete label for materialized view")
    func deleteLabelForMaterializedView() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .materializedView) == "Drop Materialized View")
    }

    @Test("Delete label for foreign table")
    func deleteLabelForForeignTable() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .foreignTable) == "Drop Foreign Table")
    }

    @Test("Delete label for nil falls back to Delete")
    func deleteLabelForNil() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: nil) == "Delete")
    }

    // MARK: - Disabled State Combinations

    @Test("Copy name disabled with no selection")
    func copyNameDisabledNoSelection() {
        let hasSelection = SidebarContextMenuLogic.hasSelection(selectedTables: [], clickedTable: nil)
        #expect(!hasSelection)
    }

    @Test("Copy name enabled with selection")
    func copyNameEnabledWithSelection() {
        let table = TestFixtures.makeTableInfo(name: "users")
        let hasSelection = SidebarContextMenuLogic.hasSelection(selectedTables: [table], clickedTable: nil)
        #expect(hasSelection)
    }

    @Test("Show structure disabled when clicked table is nil")
    func showStructureDisabledNilTable() {
        let clickedTable: TableInfo? = nil
        #expect(clickedTable == nil)
    }

    @Test("Show structure enabled when clicked table exists")
    func showStructureEnabledWithTable() {
        let clickedTable: TableInfo? = TestFixtures.makeTableInfo(name: "users")
        #expect(clickedTable != nil)
    }

    // MARK: - Maintenance group disabled rule

    @Test("Maintenance group enabled with selection, writable, and supported ops")
    func maintenanceEnabledAllConditions() {
        #expect(SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: false,
            hasSelection: true,
            supportedOperations: ["ANALYZE", "OPTIMIZE"]
        ))
    }

    @Test("Maintenance group disabled when read-only")
    func maintenanceDisabledReadOnly() {
        #expect(!SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: true,
            hasSelection: true,
            supportedOperations: ["ANALYZE"]
        ))
    }

    @Test("Maintenance group disabled with no selection")
    func maintenanceDisabledNoSelection() {
        #expect(!SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: false,
            hasSelection: false,
            supportedOperations: ["ANALYZE"]
        ))
    }

    @Test("Maintenance group disabled when driver exposes no ops")
    func maintenanceDisabledNoOps() {
        #expect(!SidebarContextMenuLogic.maintenanceGroupEnabled(
            isReadOnly: false,
            hasSelection: true,
            supportedOperations: []
        ))
    }

    // MARK: - External Tables

    @Test("External table counts as a read-only kind")
    func externalTableIsReadOnlyKind() {
        #expect(SidebarContextMenuLogic.isReadOnlyKind(.externalTable))
    }

    @Test("Import is hidden for an external table")
    func importHiddenForExternalTable() {
        let table = TableInfo(name: "customers", type: .externalTable, rowCount: nil)
        #expect(!SidebarContextMenuLogic.importVisible(clickedTable: table, supportsImport: true))
    }

    @Test("Truncate is hidden for an external table")
    func truncateHiddenForExternalTable() {
        let table = TableInfo(name: "customers", type: .externalTable, rowCount: nil)
        #expect(!SidebarContextMenuLogic.truncateVisible(clickedTable: table))
    }

    @Test("External table drop label names the object kind")
    func externalTableDeleteLabel() {
        #expect(SidebarContextMenuLogic.deleteLabel(for: .externalTable) == "Drop External Table")
    }

    // MARK: - Duplicate Table

    @Test("Duplicate is offered for a table on a supported type")
    func duplicateVisibleForTable() {
        let table = TableInfo(name: "orders", type: .table, rowCount: nil)
        #expect(SidebarContextMenuLogic.duplicateVisible(clickedTable: table, databaseType: .postgresql))
    }

    @Test("Duplicate is hidden for read-only object kinds", arguments: [
        TableInfo.TableType.view,
        .materializedView,
        .foreignTable,
        .systemTable,
        .externalTable
    ])
    func duplicateHiddenForReadOnlyKinds(_ type: TableInfo.TableType) {
        let object = TableInfo(name: "orders", type: type, rowCount: nil)
        #expect(!SidebarContextMenuLogic.duplicateVisible(clickedTable: object, databaseType: .postgresql))
    }

    @Test("Duplicate is hidden for a type with no plan builder")
    func duplicateHiddenWithoutBuilder() {
        let table = TableInfo(name: "orders", type: .table, rowCount: nil)
        #expect(!SidebarContextMenuLogic.duplicateVisible(clickedTable: table, databaseType: .sqlite))
    }

    @Test("Duplicate is hidden with nothing clicked")
    func duplicateHiddenWithoutClickedTable() {
        #expect(!SidebarContextMenuLogic.duplicateVisible(clickedTable: nil, databaseType: .postgresql))
    }

    @Test("Duplicate is enabled for a single clicked table")
    func duplicateEnabledForSingleSelection() {
        let table = TableInfo(name: "orders", type: .table, rowCount: nil)
        #expect(SidebarContextMenuLogic.duplicateEnabled(clickedTable: table, selectedTables: []))
        #expect(SidebarContextMenuLogic.duplicateEnabled(clickedTable: table, selectedTables: [table]))
    }

    @Test("Duplicate is disabled for a multi-selection")
    func duplicateDisabledForMultiSelection() {
        let orders = TableInfo(name: "orders", type: .table, rowCount: nil)
        let customers = TableInfo(name: "customers", type: .table, rowCount: nil)
        #expect(
            !SidebarContextMenuLogic.duplicateEnabled(
                clickedTable: orders,
                selectedTables: [orders, customers]
            )
        )
    }

    // MARK: - Drop Database Visibility

    @Test("Drop database visible for a supported type and eligible database")
    @MainActor
    func dropDatabaseVisibleForEligibleDatabase() {
        #expect(SidebarContextMenuLogic.dropDatabaseVisible(
            databaseType: .postgresql,
            metadata: DatabaseMetadata.minimal(name: "analytics"),
            defaultDatabase: "main"
        ))
    }

    @Test("Drop database hidden for a type without drop support")
    @MainActor
    func dropDatabaseHiddenForUnsupportedType() {
        #expect(!SidebarContextMenuLogic.dropDatabaseVisible(
            databaseType: .sqlite,
            metadata: DatabaseMetadata.minimal(name: "analytics"),
            defaultDatabase: "main"
        ))
    }

    @Test("Drop database hidden for a system database")
    @MainActor
    func dropDatabaseHiddenForSystemDatabase() {
        #expect(!SidebarContextMenuLogic.dropDatabaseVisible(
            databaseType: .mysql,
            metadata: DatabaseMetadata.minimal(name: "information_schema", isSystem: true),
            defaultDatabase: "main"
        ))
    }

    @Test("Drop database hidden for the connection's default database")
    @MainActor
    func dropDatabaseHiddenForDefaultDatabase() {
        #expect(!SidebarContextMenuLogic.dropDatabaseVisible(
            databaseType: .postgresql,
            metadata: DatabaseMetadata.minimal(name: "main"),
            defaultDatabase: "main"
        ))
    }

    // MARK: - Acted-on tables

    @Test("A clicked table outside the selection acts alone")
    func clickedOutsideSelectionActsAlone() {
        let clicked = TestFixtures.makeTableRef(name: "users")
        let other = TestFixtures.makeTableRef(name: "orders")
        #expect(SidebarContextMenuLogic.tablesInScope(of: clicked, selected: [other]) == [clicked])
    }

    @Test("A clicked table inside the selection acts on the selection in its database only")
    func selectionIsLimitedToTheClickedDatabase() {
        let clicked = TestFixtures.makeTableRef(name: "users", database: "shop")
        let sameDatabase = TestFixtures.makeTableRef(name: "orders", database: "shop")
        let otherDatabase = TestFixtures.makeTableRef(name: "users", database: "reports")
        let acted = SidebarContextMenuLogic.tablesInScope(
            of: clicked,
            selected: [clicked, sameDatabase, otherDatabase]
        )
        #expect(Set(acted) == [clicked, sameDatabase])
    }
}
