//
//  TransferDriverContext.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct TransferDriverContext: Sendable {
    let driver: DatabaseDriver
    let adapter: PluginDriverAdapter
    let endpoint: TransferEndpoint

    init?(driver: DatabaseDriver, endpoint: TransferEndpoint) {
        guard let adapter = driver as? PluginDriverAdapter else { return nil }
        self.driver = driver
        self.adapter = adapter
        self.endpoint = endpoint
    }

    private var pluginDriver: any PluginDatabaseDriver { adapter.schemaPluginDriver }

    var databaseType: DatabaseType { endpoint.databaseType }

    var supportsSchemas: Bool { pluginDriver.supportsSchemas }

    /// The container the driver is already pinned to. A schema-aware engine
    /// resolves a bare table name through its schema, everything else through
    /// the database it connected to.
    var schema: String? {
        guard supportsSchemas else { return nil }
        return endpoint.schema ?? pluginDriver.currentSchema
    }

    /// `PluginExportDataSource.streamRows(table:databaseName:)` reads its second
    /// argument as a schema on a schema-aware engine and as a database
    /// everywhere else, so the caller has to resolve which one it means.
    static func containerName(for endpoint: TransferEndpoint, supportsSchemas: Bool) -> String {
        guard supportsSchemas else { return endpoint.database }
        return endpoint.schema ?? ""
    }

    var containerName: String {
        Self.containerName(for: endpoint, supportsSchemas: supportsSchemas)
    }

    func fetchTableNames() async throws -> Set<String> {
        let tables = try await pluginDriver.fetchTables(schema: schema)
        return Set(tables.map(\.name))
    }

    func fetchColumns(table: String) async throws -> [PluginColumnInfo] {
        try await pluginDriver.fetchColumns(table: table, schema: schema)
    }

    func fetchIndexes(table: String) async throws -> [PluginIndexInfo] {
        try await pluginDriver.fetchIndexes(table: table, schema: schema)
    }

    func fetchForeignKeys(table: String) async throws -> [PluginForeignKeyInfo] {
        try await pluginDriver.fetchForeignKeys(table: table, schema: schema)
    }

    func fetchAllForeignKeys() async throws -> [String: [PluginForeignKeyInfo]] {
        try await pluginDriver.fetchAllForeignKeys(schema: schema)
    }

    func approximateRowCount(table: String) async throws -> Int? {
        try await pluginDriver.fetchApproximateRowCount(table: table, schema: schema)
    }

    func createTableStatement(_ definition: PluginCreateTableDefinition) -> String? {
        adapter.generateCreateTableSQL(definition: definition)
    }

    func addIndexStatement(table: String, index: PluginIndexDefinition) -> String? {
        adapter.generateAddIndexSQL(table: table, index: index)
    }

    func addForeignKeyStatement(table: String, foreignKey: PluginForeignKeyDefinition) -> String? {
        adapter.generateAddForeignKeySQL(table: table, fk: foreignKey)
    }

    func resetSequenceStatement(table: String, column: String) -> String? {
        pluginDriver.generateResetSequenceSQL(table: table, schema: schema, column: column)
    }

    func dropTableStatement(_ table: String) -> String {
        adapter.dropObjectStatement(name: table, objectType: "TABLE", schema: schema, cascade: false)
    }

    func truncateStatements(_ table: String) -> [String] {
        adapter.truncateTableStatements(table: table, schema: schema, cascade: false)
    }

    var supportsForeignKeyCheckToggle: Bool {
        adapter.foreignKeyDisableStatements() != nil
    }

    func setForeignKeyChecks(enabled: Bool) async throws {
        let statements = enabled ? adapter.foreignKeyEnableStatements() : adapter.foreignKeyDisableStatements()
        guard let statements else { return }
        for statement in statements {
            try await execute(statement)
        }
    }

    func execute(_ statement: String) async throws {
        _ = try await driver.execute(query: statement)
    }

    func applyQueryTimeout(_ seconds: Int) async {
        try? await driver.applyQueryTimeout(seconds)
    }
}
