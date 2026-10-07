//
//  ScopedPendingOperationsTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private final class StubTableOpDriver: PluginDatabaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func quoteIdentifier(_ name: String) -> String { "`\(name)`" }
}

@Suite("Scoped pending operations", .serialized)
@MainActor
struct ScopedPendingOperationsTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager, DatabaseConnection) {
        let connection = TestFixtures.makeConnection(database: "a", type: .mysql)
        var session = ConnectionSession(connection: connection)
        session.driver = PluginDriverAdapter(connection: connection, pluginDriver: StubTableOpDriver())
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        return (state.coordinator, state.tabManager, connection)
    }

    private func ref(_ name: String, database: String, connectionId: UUID) -> DatabaseTreeTableRef {
        TestFixtures.makeTableRef(name: name, database: database, connectionId: connectionId)
    }

    private func tabScope(_ connection: DatabaseConnection) -> DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: "a", schema: nil)
    }

    @Test("A truncate marked on B.users runs on B even when saved from a tab on A")
    func truncateRunsOnItsOwnDatabase() throws {
        let (coordinator, tabManager, connection) = makeCoordinator()
        defer {
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        tabManager.addTab(databaseName: "a")

        let batches = try coordinator.assemblePendingBatches(
            tabScope: tabScope(connection),
            pendingTruncates: [ref("users", database: "b", connectionId: connection.id)],
            pendingDeletes: [],
            tableOperationOptions: [:]
        )

        #expect(batches.count == 1)
        #expect(batches.first?.scope == DatabaseScope(connectionId: connection.id, database: "b", schema: nil))
        #expect(batches.first?.statements.map(\.sql) == ["TRUNCATE TABLE `users`"])
    }

    @Test("Same-name tables in two databases become two batches on their own scopes")
    func sameNameTablesSplitByDatabase() throws {
        let (coordinator, tabManager, connection) = makeCoordinator()
        defer {
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        tabManager.addTab(databaseName: "a")
        let inA = ref("users", database: "a", connectionId: connection.id)

        let batches = try coordinator.assemblePendingBatches(
            tabScope: tabScope(connection),
            pendingTruncates: [inA, ref("users", database: "b", connectionId: connection.id)],
            pendingDeletes: [],
            tableOperationOptions: [:]
        )

        #expect(batches.map(\.scope.database) == ["a", "b"])
        #expect(batches.allSatisfy { $0.statements.map(\.sql) == ["TRUNCATE TABLE `users`"] })
        #expect(batches.first?.truncates == [inA])
    }

    @Test("A pending operation of another connection is never built by this coordinator")
    func foreignConnectionRefsAreIgnored() throws {
        let (coordinator, tabManager, connection) = makeCoordinator()
        defer {
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        tabManager.addTab(databaseName: "a")

        let batches = try coordinator.assemblePendingBatches(
            tabScope: tabScope(connection),
            pendingTruncates: [ref("users", database: "a", connectionId: UUID())],
            pendingDeletes: [],
            tableOperationOptions: [:]
        )

        #expect(batches.isEmpty)
    }

    @Test("Options stay with the ref they were set on")
    func optionsFollowTheirRef() throws {
        let (coordinator, tabManager, connection) = makeCoordinator()
        defer {
            coordinator.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
        }
        tabManager.addTab(databaseName: "a")
        let dropped = ref("orders", database: "b", connectionId: connection.id)

        let batches = try coordinator.assemblePendingBatches(
            tabScope: tabScope(connection),
            pendingTruncates: [ref("users", database: "a", connectionId: connection.id)],
            pendingDeletes: [dropped],
            tableOperationOptions: [dropped: TableOperationOptions(cascade: true)]
        )

        let bySQL = Dictionary(uniqueKeysWithValues: batches.map { ($0.scope.database, $0.statements.map(\.sql)) })
        #expect(bySQL["a"] == ["TRUNCATE TABLE `users`"])
        #expect(bySQL["b"]?.count == 1)
        #expect(bySQL["b"]?.first?.contains("CASCADE") == true)
    }
}
