//
//  TableOperationSQLBuilderTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private final class StubDropDriver: PluginDatabaseDriver {
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
}

@Suite("TableOperationSQLBuilder")
@MainActor
struct TableOperationSQLBuilderTests {
    private let connectionId = UUID()

    private func makeBuilder() -> TableOperationSQLBuilder {
        let connection = DatabaseConnection(name: "Test", type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: StubDropDriver())
        return TableOperationSQLBuilder(
            connectionId: connectionId,
            databaseType: .postgresql,
            adapterProvider: { adapter }
        )
    }

    private func ref(
        _ name: String,
        type: TableInfo.TableType = .table,
        schema: String? = nil,
        database: String = "app"
    ) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            connectionId: connectionId,
            database: database,
            schema: nil,
            table: TableInfo(name: name, type: type, rowCount: nil, schema: schema)
        )
    }

    private func drop(_ target: DatabaseTreeTableRef) -> [String] {
        makeBuilder().generate(truncates: [], deletes: [target], options: [:], includeFKHandling: false)
    }

    @Test("Materialized view drops with DROP MATERIALIZED VIEW")
    func dropsMaterializedView() {
        #expect(drop(ref("daily_sales", type: .materializedView, schema: "public"))
            == ["DROP MATERIALIZED VIEW \"public\".\"daily_sales\""])
    }

    @Test("View drops with DROP VIEW")
    func dropsView() {
        #expect(drop(ref("active_users", type: .view)) == ["DROP VIEW \"active_users\""])
    }

    @Test("Foreign table drops with DROP FOREIGN TABLE")
    func dropsForeignTable() {
        #expect(drop(ref("remote_orders", type: .foreignTable)) == ["DROP FOREIGN TABLE \"remote_orders\""])
    }

    @Test("External table drops with DROP TABLE")
    func dropsExternalTable() {
        #expect(drop(ref("customers", type: .externalTable)) == ["DROP TABLE \"customers\""])
    }

    @Test("Plain table drops with DROP TABLE")
    func dropsTable() {
        #expect(drop(ref("orders")) == ["DROP TABLE \"orders\""])
    }

    @Test("System table drops with DROP TABLE")
    func dropsSystemTable() {
        #expect(drop(ref("pg_stats", type: .systemTable)) == ["DROP TABLE \"pg_stats\""])
    }

    @Test("The tree's schema wins over the table's own schema")
    func refSchemaWins() {
        let target = DatabaseTreeTableRef(
            connectionId: connectionId,
            database: "app",
            schema: "sales",
            table: TableInfo(name: "orders", type: .table, rowCount: nil, schema: nil)
        )
        #expect(drop(target) == ["DROP TABLE \"sales\".\"orders\""])
    }

    @Test("Cascade applies to materialized view drops")
    func cascadeAppliesToMaterializedView() {
        let target = ref("daily_sales", type: .materializedView)
        let stmts = makeBuilder().generate(
            truncates: [],
            deletes: [target],
            options: [target: TableOperationOptions(cascade: true)],
            includeFKHandling: false
        )
        #expect(stmts == ["DROP MATERIALIZED VIEW \"daily_sales\" CASCADE"])
    }

    @Test("Drop qualifies schema when TableInfo carries one")
    func qualifiesSchema() {
        #expect(drop(ref("orders", schema: "sales")) == ["DROP TABLE \"sales\".\"orders\""])
    }

    @Test("Truncate qualifies schema when TableInfo carries one")
    func truncateQualifiesSchema() {
        let stmts = makeBuilder().generate(
            truncates: [ref("orders", schema: "sales")],
            deletes: [],
            options: [:],
            includeFKHandling: false
        )
        #expect(stmts == ["TRUNCATE TABLE \"sales\".\"orders\""])
    }

    @Test("Options apply only to the ref they were set on")
    func optionsAreKeyedByRef() {
        let inApp = ref("users", database: "app")
        let inReports = ref("users", database: "reports")
        let stmts = makeBuilder().generate(
            truncates: [],
            deletes: [inApp, inReports],
            options: [inReports: TableOperationOptions(cascade: true)],
            includeFKHandling: false
        )
        #expect(stmts.sorted() == ["DROP TABLE \"users\"", "DROP TABLE \"users\" CASCADE"])
    }
}
