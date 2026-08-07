//
//  WindowSidebarStateTests.swift
//  TableProTests
//
//  Pins per-window scoping of table selection. Regression guard for #1313 where
//  selectedTables was shared across windows of the same connection, causing
//  Cmd+T to jump focus back to a sibling window. Sidebar filter text is
//  connection-scoped and lives in SharedSidebarState; see SharedSidebarStateTests.
//  Also pins per-connection persistence of database-tree expansion.
//

import Foundation
import TableProPluginKit
import Testing
@testable import SchemaStudio

@MainActor
struct WindowSidebarStateTests {
    private func makeRef(
        connectionId: UUID,
        database: String = "shop",
        schema: String? = "public",
        name: String = "users"
    ) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            connectionId: connectionId,
            database: database,
            schema: schema,
            table: TestFixtures.makeTableInfo(name: name)
        )
    }

    @Test
    func twoInstancesHoldIndependentSelection() {
        let windowA = WindowSidebarState()
        let windowB = WindowSidebarState()

        let users = makeRef(connectionId: UUID())
        windowA.selectedTables = [users]

        #expect(windowA.selectedTables == [users])
        #expect(windowB.selectedTables.isEmpty)
    }

    @Test("Two connections holding the same schema.table stay distinct in the selection")
    func selectionSeparatesConnectionsWithIdenticalTableNames() {
        let first = UUID()
        let second = UUID()
        let state = WindowSidebarState()

        let inFirst = makeRef(connectionId: first)
        let inSecond = makeRef(connectionId: second)
        state.selectedTables = [inFirst]

        #expect(state.selectedTables.contains(inFirst))
        #expect(!state.selectedTables.contains(inSecond))
        #expect(inFirst != inSecond)
    }

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "sidebar-tree-\(UUID().uuidString)"))
    }

    @Test("Tree expansion persists and restores across instances for a connection")
    func persistsAndRestores() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let database = ConnectionDatabaseKey(connectionId: connectionId, database: "shop")
        let schema = ConnectionSchemaKey(connectionId: connectionId, database: "shop", schema: "public")

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeDatabases.insert(database)
        state.expandedTreeSchemas.insert("public")
        state.expandedTreeDatabaseSchemas.insert(schema)

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeDatabases == [database])
        #expect(restored.expandedTreeSchemas == ["public"])
        #expect(restored.expandedTreeDatabaseSchemas.contains(schema))
    }

    @Test("Two connections expanding the same database name keep separate expansion keys")
    func expansionKeysCarryConnectionIdentity() throws {
        let defaults = try makeDefaults()
        let windowConnection = UUID()
        let other = UUID()
        let mine = ConnectionDatabaseKey(connectionId: windowConnection, database: "shop")
        let theirs = ConnectionDatabaseKey(connectionId: other, database: "shop")

        let state = WindowSidebarState(connectionId: windowConnection, defaults: defaults)
        state.expandedTreeDatabases.insert(mine)

        #expect(state.expandedTreeDatabases.contains(mine))
        #expect(!state.expandedTreeDatabases.contains(theirs))
    }

    @Test("Different connections keep independent expansion")
    func connectionsAreIsolated() throws {
        let defaults = try makeDefaults()
        let first = UUID()
        let second = UUID()

        WindowSidebarState(connectionId: first, defaults: defaults)
            .expandedTreeDatabases.insert(ConnectionDatabaseKey(connectionId: first, database: "a"))

        let secondState = WindowSidebarState(connectionId: second, defaults: defaults)
        #expect(secondState.expandedTreeDatabases.isEmpty)
    }

    @Test("Collapsing everything removes stored expansion")
    func clearingRemovesStorage() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeDatabases.insert(ConnectionDatabaseKey(connectionId: connectionId, database: "shop"))
        state.expandedTreeDatabases.removeAll()

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeDatabases.isEmpty)
    }

    @Test("Expanded partitioned tables persist and restore")
    func persistsExpandedPartitionedTables() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let orders = ConnectionTableKey(
            connectionId: connectionId, database: "shop", schema: "public", table: "orders"
        )

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeTables.insert(orders)

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeTables == [orders])
    }

    @Test("A schema-less table key stays distinct from a schema-qualified one")
    func partitionedTableKeysDistinguishSchema() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let qualified = ConnectionTableKey(
            connectionId: connectionId, database: "shop", schema: "public", table: "orders"
        )
        let unqualified = ConnectionTableKey(
            connectionId: connectionId, database: "shop", schema: nil, table: "orders"
        )

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeTables = [qualified, unqualified]

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeTables.count == 2)
        #expect(restored.expandedTreeTables.contains(qualified))
        #expect(restored.expandedTreeTables.contains(unqualified))
    }

    @Test("Expansion stored in the connection-less format is dropped instead of misread")
    func discardsExpansionWrittenWithoutConnectionIdentity() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let stale = """
            {"schemas":["public"],"databases":["shop"],"databaseSchemas":[{"database":"shop","schema":"public"}]}
            """
        defaults.set(Data(stale.utf8), forKey: "com.SchemaStudio.sidebar.treeExpansion.\(connectionId.uuidString)")

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeDatabases.isEmpty)
        #expect(restored.expandedTreeDatabaseSchemas.isEmpty)
        #expect(restored.expandedTreeTables.isEmpty)
    }

    @Test("Collapsing every partitioned table clears storage alongside the rest")
    func clearingPartitionedTablesRemovesStorage() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()

        let state = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        state.expandedTreeTables.insert(ConnectionTableKey(
            connectionId: connectionId, database: "shop", schema: "public", table: "orders"
        ))
        state.expandedTreeTables.removeAll()

        let restored = WindowSidebarState(connectionId: connectionId, defaults: defaults)
        #expect(restored.expandedTreeTables.isEmpty)
    }

    @Test("A window without a connection does not persist")
    func nilConnectionDoesNotPersist() throws {
        let defaults = try makeDefaults()
        let connectionId = UUID()
        let key = ConnectionDatabaseKey(connectionId: connectionId, database: "x")
        let state = WindowSidebarState(connectionId: nil, defaults: defaults)
        state.expandedTreeDatabases.insert(key)
        #expect(state.expandedTreeDatabases == [key])
    }
}
