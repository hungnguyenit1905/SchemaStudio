//
//  SidebarScopeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

@Suite("Sidebar scope")
@MainActor
struct SidebarScopeTests {
    private let connectionId = UUID()

    private func ref(database: String, schema: String?, table: String = "users") -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            connectionId: connectionId,
            database: database,
            schema: schema,
            table: TableInfo(name: table, type: .table, rowCount: nil, schema: schema)
        )
    }

    @Test("A connection node resolves to the connection alone")
    func connectionResolves() {
        let connection = TestFixtures.makeConnection(id: connectionId)
        #expect(SidebarScope.resolve(.connection(connection)) == SidebarScope(connectionId: connectionId))
    }

    @Test("A database node resolves to that database")
    func databaseResolves() {
        let metadata = DatabaseMetadata.minimal(name: "shop")
        #expect(
            SidebarScope.resolve(.database(connectionId: connectionId, metadata: metadata))
                == SidebarScope(connectionId: connectionId, database: "shop")
        )
    }

    @Test("A schema node resolves to its database and schema")
    func schemaResolves() {
        #expect(
            SidebarScope.resolve(.schema(connectionId: connectionId, database: "shop", schema: "sales"))
                == SidebarScope(connectionId: connectionId, database: "shop", schema: "sales")
        )
    }

    @Test("A table resolves to its containing scope")
    func tableResolvesToContainer() {
        let expected = SidebarScope(connectionId: connectionId, database: "shop", schema: "sales")
        #expect(SidebarScope.resolve(.table(ref(database: "shop", schema: "sales"))) == expected)
        #expect(SidebarScope.resolve(.recentTable(ref(database: "shop", schema: "sales"))) == expected)
    }

    @Test("Folder, root, status and recent-section nodes have no scope")
    func structuralNodesHaveNoScope() {
        #expect(SidebarScope.resolve(.connectionRoot) == nil)
        #expect(SidebarScope.resolve(.folder(ConnectionGroup(name: "Work"))) == nil)
        #expect(SidebarScope.resolve(.status(.loading)) == nil)
        #expect(SidebarScope.resolve(.recentSection(connectionId: connectionId)) == nil)
    }

    @Test("Same names on two connections stay distinct")
    func sameNamesOnTwoConnectionsAreDistinct() {
        let other = UUID()
        #expect(
            SidebarScope(connectionId: connectionId, database: "shop")
                != SidebarScope(connectionId: other, database: "shop")
        )
    }

    @Test("An empty database or schema normalizes to none")
    func emptyNamesNormalize() {
        let scope = SidebarScope(connectionId: connectionId, database: "", schema: "sales")
        #expect(scope.database == nil)
        #expect(scope.schema == nil)
    }

    @Test("A closed database falls back to its connection")
    func closedDatabaseFallsBack() {
        let scope = SidebarScope(connectionId: connectionId, database: "shop", schema: "sales")
        let resolved = scope.resolved(connectionExists: { _ in true }, isDatabaseOpen: { _, _ in false })
        #expect(resolved == SidebarScope(connectionId: connectionId))
    }

    @Test("An open database keeps its scope")
    func openDatabaseKeepsScope() {
        let scope = SidebarScope(connectionId: connectionId, database: "shop", schema: "sales")
        let resolved = scope.resolved(connectionExists: { _ in true }, isDatabaseOpen: { _, _ in true })
        #expect(resolved == scope)
    }

    @Test("A deleted connection clears the scope")
    func deletedConnectionClears() {
        let scope = SidebarScope(connectionId: connectionId, database: "shop")
        #expect(scope.resolved(connectionExists: { _ in false }, isDatabaseOpen: { _, _ in true }) == nil)
    }

    @Test("A connection scope uses the connection default database")
    func connectionScopeUsesDefault() {
        let scope = SidebarScope(connectionId: connectionId)
        #expect(
            scope.databaseScope(defaultDatabase: "app")
                == DatabaseScope(connectionId: connectionId, database: "app", schema: nil)
        )
    }

    @Test("Selecting a table sets only this window's scope")
    func selectingTableSetsScope() {
        let window = WindowSidebarState()
        let other = WindowSidebarState()
        let tree = DatabaseTreeOutlineCoordinator()
        tree.windowState = window

        tree.adoptSelectedScope(of: .table(ref(database: "shop", schema: "sales")))

        #expect(window.selectedScope == SidebarScope(connectionId: connectionId, database: "shop", schema: "sales"))
        #expect(other.selectedScope == nil)
    }

    @Test("A structural node leaves the previous scope in place")
    func structuralNodeKeepsPreviousScope() {
        let window = WindowSidebarState()
        let previous = SidebarScope(connectionId: connectionId, database: "shop")
        window.selectedScope = previous
        let tree = DatabaseTreeOutlineCoordinator()
        tree.windowState = window

        tree.adoptSelectedScope(of: .status(.loading))

        #expect(window.selectedScope == previous)
    }
}
