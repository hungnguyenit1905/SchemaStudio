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

    func createEnumTypeStatement(_ type: TransferEnumType) -> String? {
        pluginDriver.generateCreateEnumTypeSQL(name: type.name, schema: schema, values: type.values)
    }

    func dropEnumTypeStatement(_ type: TransferEnumType) -> String? {
        pluginDriver.generateDropEnumTypeSQL(name: type.name, schema: schema)
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

    func bulkLoadWriter(
        table: String,
        columns: [String]
    ) async throws -> PluginBulkLoadWriter? {
        try await pluginDriver.bulkLoadWriter(table: table, schema: schema, columns: columns)
    }

    func serverLimits() async throws -> PluginServerLimits? {
        try await pluginDriver.serverLimits()
    }

    func constraintDisableCapability() async -> PluginConstraintDisableCapability {
        await pluginDriver.constraintDisableCapability()
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

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        pluginDriver.streamRows(query: query)
    }

    var quoteIdentifier: (String) -> String {
        { pluginDriver.quoteIdentifier($0) }
    }

    var escapeStringLiteral: (String) -> String {
        { pluginDriver.escapeStringLiteral($0) }
    }

    /// Row constructors exist on MySQL and PostgreSQL; SQLite and SQL Server
    /// spell a composite key out as an OR chain instead.
    var chunkComparison: TransferChunkPlanner.Comparison {
        switch databaseType {
        case .mysql, .postgresql:
            return .rowConstructor
        default:
            return .tupleOr
        }
    }

    func qualifiedTableRef(table: String) -> String {
        let quoted = pluginDriver.quoteIdentifier(table)
        guard !containerName.isEmpty else { return quoted }
        return "\(pluginDriver.quoteIdentifier(containerName)).\(quoted)"
    }

    func countRows(table: String) async throws -> Int {
        let result = try await driver.execute(query: "SELECT COUNT(*) FROM \(qualifiedTableRef(table: table))")
        guard let value = result.rows.first?.first else { return 0 }
        if case .text(let text) = value, let count = Int(text) { return count }
        return 0
    }

    func exportSnapshotToken() async throws -> String? {
        try await pluginDriver.exportSnapshotToken()
    }

    func adoptSnapshotToken(_ token: String) async throws -> Bool {
        try await pluginDriver.adoptSnapshotToken(token)
    }

    func primaryKeyRangeBoundaries(
        table: String,
        column: String,
        partitions: Int
    ) async throws -> [String]? {
        try await pluginDriver.primaryKeyRangeBoundaries(
            table: table,
            schema: schema,
            column: column,
            partitions: partitions
        )
    }

    func applyQueryTimeout(_ seconds: Int) async {
        try? await driver.applyQueryTimeout(seconds)
    }
}
