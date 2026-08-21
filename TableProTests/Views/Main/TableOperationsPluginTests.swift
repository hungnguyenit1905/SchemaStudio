//
//  TableOperationsPluginTests.swift
//  TableProTests
//
//  Table operation SQL is plugin-first: the app orchestrates the statement order and
//  asks the connected driver for every piece of vendor SQL. It never guesses vendor
//  syntax from DatabaseType, so a coordinator with no driver attached emits nothing.
//

import Foundation
import TableProPluginKit
import Testing

@testable import SchemaStudio

private final class StubTableOperationDriver: PluginDatabaseDriver {
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

    func quoteIdentifier(_ name: String) -> String {
        "`\(name.replacingOccurrences(of: "`", with: "``"))`"
    }

    func foreignKeyDisableStatements() -> [String]? { ["SET FOREIGN_KEY_CHECKS=0"] }
    func foreignKeyEnableStatements() -> [String]? { ["SET FOREIGN_KEY_CHECKS=1"] }
}

@Suite("TableOperations Plugin-First SQL")
@MainActor
struct TableOperationsPluginTests {
    private func makeBuilder(tables: [TableInfo] = []) -> TableOperationSQLBuilder {
        let connection = DatabaseConnection(name: "Test", type: .mysql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: StubTableOperationDriver())
        return TableOperationSQLBuilder(
            connectionId: connection.id,
            databaseType: .mysql,
            tableInfoProvider: { Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) }) },
            adapterProvider: { adapter }
        )
    }

    private func makeCoordinator(type: DatabaseType = .mysql) -> MainContentCoordinator {
        let connection = TestFixtures.makeConnection(database: "testdb", type: type)
        let tabManager = QueryTabManager()
        let changeManager = DataChangeManager()
        let toolbarState = ConnectionToolbarState()

        return MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: changeManager,
            toolbarState: toolbarState
        )
    }

    // MARK: - Statements come from the connected driver

    @Test("FK disable statements come from the driver")
    func fkDisableUsesDriver() {
        #expect(makeBuilder().foreignKeyDisableStatements() == ["SET FOREIGN_KEY_CHECKS=0"])
    }

    @Test("FK enable statements come from the driver")
    func fkEnableUsesDriver() {
        #expect(makeBuilder().foreignKeyEnableStatements() == ["SET FOREIGN_KEY_CHECKS=1"])
    }

    @Test("Truncate quotes the table with the driver's identifier quoting")
    func truncateUsesDriverQuoting() {
        let stmts = makeBuilder().generate(
            truncates: ["users"], deletes: [], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE `users`"])
    }

    @Test("Truncate appends CASCADE when the option is set")
    func truncateCascade() {
        let stmts = makeBuilder().generate(
            truncates: ["orders"],
            deletes: [],
            options: ["orders": TableOperationOptions(ignoreForeignKeys: false, cascade: true)],
            includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE `orders` CASCADE"])
    }

    @Test("Drop quotes the table with the driver's identifier quoting")
    func dropUsesDriverQuoting() {
        let stmts = makeBuilder().generate(
            truncates: [], deletes: ["users"], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE `users`"])
    }

    @Test("Drop appends CASCADE when the option is set")
    func dropCascade() {
        let stmts = makeBuilder().generate(
            truncates: [],
            deletes: ["orders"],
            options: ["orders": TableOperationOptions(ignoreForeignKeys: false, cascade: true)],
            includeFKHandling: false
        )
        #expect(stmts == ["DROP TABLE `orders` CASCADE"])
    }

    // MARK: - Orchestration owned by the app

    @Test("FK handling wraps the whole batch")
    func combinedWithFKHandling() {
        let stmts = makeBuilder().generate(
            truncates: ["alpha"],
            deletes: ["beta"],
            options: [
                "alpha": TableOperationOptions(ignoreForeignKeys: true, cascade: false),
                "beta": TableOperationOptions(ignoreForeignKeys: true, cascade: false)
            ],
            includeFKHandling: true
        )
        #expect(stmts == [
            "SET FOREIGN_KEY_CHECKS=0",
            "TRUNCATE TABLE `alpha`",
            "DROP TABLE `beta`",
            "SET FOREIGN_KEY_CHECKS=1"
        ])
    }

    @Test("FK handling is skipped when no table asks to ignore foreign keys")
    func noFKHandlingWithoutOptIn() {
        let stmts = makeBuilder().generate(
            truncates: ["alpha"], deletes: [], options: [:], includeFKHandling: true
        )
        #expect(stmts == ["TRUNCATE TABLE `alpha`"])
    }

    @Test("Tables are sorted for consistent execution order")
    func sortedOrder() {
        let stmts = makeBuilder().generate(
            truncates: ["zebra", "apple"], deletes: [], options: [:], includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE `apple`", "TRUNCATE TABLE `zebra`"])
    }

    // MARK: - No driver means no guessed vendor SQL

    @Test("FK disable yields nothing without a connected driver")
    func fkDisableWithoutDriver() {
        let coordinator = makeCoordinator(type: .mysql)
        defer { coordinator.teardown() }

        #expect(coordinator.fkDisableStatements(for: .mysql).isEmpty)
    }

    @Test("FK enable yields nothing without a connected driver")
    func fkEnableWithoutDriver() {
        let coordinator = makeCoordinator(type: .sqlite)
        defer { coordinator.teardown() }

        #expect(coordinator.fkEnableStatements(for: .sqlite).isEmpty)
    }

    @Test("Truncate and drop yield nothing without a connected driver")
    func tableOperationsWithoutDriver() {
        let coordinator = makeCoordinator(type: .postgresql)
        defer { coordinator.teardown() }

        let stmts = coordinator.generateTableOperationSQL(
            truncates: ["users"],
            deletes: ["orders"],
            options: [:],
            includeFKHandling: true
        )
        #expect(stmts.isEmpty)
    }
}
