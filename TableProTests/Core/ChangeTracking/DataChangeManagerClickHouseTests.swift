//
//  DataChangeManagerClickHouseTests.swift
//  TableProTests
//
//  Tests for ClickHouse-specific UPDATE statement validation in DataChangeManager.
//  ClickHouse uses ALTER TABLE ... UPDATE syntax instead of standard UPDATE.
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private final class ClickHouseStubDriver: PluginDatabaseDriver {
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

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        ClickHouseStatementGenerator(
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            keyIsUnique: false
        ).generateStatements(
            changes: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }
}

@MainActor
@Suite("DataChangeManager ClickHouse UPDATE Validation")
struct DataChangeManagerClickHouseTests {
    @Test("ClickHouse ALTER TABLE UPDATE is counted as an update statement")
    func alterTableUpdateCounted() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .clickhouse
        )
        manager.pluginDriver = ClickHouseStubDriver()

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob",
            originalRow: ["1", "Alice"]
        )

        #expect(manager.hasChanges)

        let statements = try manager.generateSQL()
        #expect(!statements.isEmpty)

        // ClickHouse generates ALTER TABLE ... UPDATE instead of UPDATE
        let hasAlterTableUpdate = statements.contains { $0.sql.hasPrefix("ALTER TABLE") }
        #expect(hasAlterTableUpdate)
    }

    @Test("ClickHouse ALTER TABLE UPDATE passes validation without throwing")
    func alterTableUpdatePassesValidation() {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "events",
            columns: ["id", "status"],
            primaryKeyColumns: ["id"],
            databaseType: .clickhouse
        )
        manager.pluginDriver = ClickHouseStubDriver()

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "status",
            oldValue: "pending",
            newValue: "completed",
            originalRow: ["42", "pending"]
        )

        // Should not throw — ALTER TABLE UPDATE must be recognized as valid
        #expect(throws: Never.self) {
            _ = try manager.generateSQL()
        }
    }

    @Test("Standard UPDATE prefix is still detected for non-ClickHouse databases")
    func standardUpdatePrefixDetected() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "users",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql
        )

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "name",
            oldValue: "Alice",
            newValue: "Bob",
            originalRow: ["1", "Alice"]
        )

        let statements = try manager.generateSQL()
        #expect(!statements.isEmpty)

        let hasStandardUpdate = statements.contains { $0.sql.hasPrefix("UPDATE") }
        #expect(hasStandardUpdate)
    }

    @Test("ClickHouse UPDATE without primary key uses all columns in WHERE clause")
    func clickhouseUpdateWithoutPrimaryKey() throws {
        let manager = DataChangeManager()
        manager.configureForTable(
            tableName: "logs",
            columns: ["timestamp", "message"],
            primaryKeyColumns: [],
            databaseType: .clickhouse
        )
        manager.pluginDriver = ClickHouseStubDriver()

        manager.recordCellChange(
            rowIndex: 0,
            columnIndex: 1,
            columnName: "message",
            oldValue: "old log",
            newValue: "new log",
            originalRow: ["2024-01-01", "old log"]
        )

        let statements = try manager.generateSQL()
        #expect(!statements.isEmpty)

        let alterStatement = statements.first { $0.sql.hasPrefix("ALTER TABLE") }
        #expect(alterStatement != nil)
        #expect(alterStatement?.sql.contains("UPDATE") == true)
        #expect(alterStatement?.sql.contains("WHERE") == true)
    }
}
