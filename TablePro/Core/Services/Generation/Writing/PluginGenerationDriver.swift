//
//  PluginGenerationDriver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The engine's server side, over a live connection. Statement text comes from
/// `SQLStatementGenerator` and the plugin's own quoting, so nothing here is a
/// second SQL builder.
struct PluginGenerationDriver: GenerationDriver {
    private let driver: DatabaseDriver
    private let adapter: PluginDriverAdapter
    private let databaseType: DatabaseType
    private let schema: String?

    let blocksDestructiveOperations: Bool

    init?(
        driver: DatabaseDriver,
        databaseType: DatabaseType,
        schema: String? = nil,
        blocksDestructiveOperations: Bool = false
    ) {
        guard let adapter = driver as? PluginDriverAdapter else { return nil }
        self.driver = driver
        self.adapter = adapter
        self.databaseType = databaseType
        self.schema = schema
        self.blocksDestructiveOperations = blocksDestructiveOperations
    }

    private var pluginDriver: any PluginDatabaseDriver { adapter.schemaPluginDriver }

    var supportsTransactions: Bool { pluginDriver.supportsTransactions }

    func serverLimits() async throws -> PluginServerLimits? {
        try await pluginDriver.serverLimits()
    }

    func beginTransaction() async throws {
        try await driver.beginTransaction(mode: .readWrite)
    }

    func commitTransaction() async throws {
        try await driver.commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await driver.rollbackTransaction()
    }

    func setForeignKeyChecks(enabled: Bool) async throws {
        let statements = enabled ? adapter.foreignKeyEnableStatements() : adapter.foreignKeyDisableStatements()
        guard let statements else { return }
        for statement in statements {
            _ = try await driver.execute(query: statement)
        }
    }

    func hasInboundForeignKeys(table: GenerationTableReference) async throws -> Bool {
        let all = try await pluginDriver.fetchAllForeignKeys(schema: table.schema ?? schema)
        return all.values.contains { keys in
            keys.contains { $0.referencedTable == table.table }
        }
    }

    func emptyTable(_ table: GenerationTableReference, allowsTruncate: Bool) async throws {
        for statement in emptyStatements(table, allowsTruncate: allowsTruncate) {
            _ = try await driver.execute(query: statement)
        }
    }

    func insert(
        table: GenerationTableReference,
        columns: [String],
        rows: [[PluginCellValue]],
        harvestColumns: [String]
    ) async throws -> [[PluginCellValue]]? {
        guard !rows.isEmpty else { return harvestColumns.isEmpty ? nil : [] }
        if !harvestColumns.isEmpty {
            let harvested = try await pluginDriver.insertHarvestingKeys(
                table: table.table,
                schema: table.schema ?? schema,
                columns: columns,
                rows: rows,
                harvestColumns: harvestColumns
            )
            if let harvested { return harvested }
        }

        guard !columns.isEmpty else {
            for _ in rows {
                _ = try await driver.execute(query: defaultValuesStatement(table))
            }
            return nil
        }

        let generator = try statementGenerator(for: table, columns: columns)
        let chunkSize = max(1, generator.maxBindParameters / columns.count)
        var offset = 0
        while offset < rows.count {
            let end = min(offset + chunkSize, rows.count)
            guard let statement = generator.insertStatement(columns: columns, rows: Array(rows[offset ..< end])) else {
                throw GenerationError.writeFailed(
                    table: table.qualifiedName,
                    reason: String(
                        format: String(localized: "%d rows do not match the %d columns being written."),
                        end - offset,
                        columns.count
                    )
                )
            }
            _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
            offset = end
        }
        return nil
    }

    func update(
        table: GenerationTableReference,
        setColumns: [String],
        keyColumns: [String],
        assignments: [[PluginCellValue]]
    ) async throws {
        guard !setColumns.isEmpty, !keyColumns.isEmpty, !assignments.isEmpty else { return }
        let name = qualifiedName(table.table, schema: table.schema ?? schema)
        let assignmentList = setColumns.map { "\(adapter.quoteIdentifier($0)) = ?" }.joined(separator: ", ")
        let predicate = keyColumns.map { "\(adapter.quoteIdentifier($0)) = ?" }.joined(separator: " AND ")
        let sql = "UPDATE \(name) SET \(assignmentList) WHERE \(predicate)"
        let expected = setColumns.count + keyColumns.count
        for assignment in assignments where assignment.count == expected {
            _ = try await driver.executeParameterized(query: sql, parameters: assignment)
        }
    }

    /// The statement is the vendor's, and the value is computed on the server: a
    /// round trip to read `MAX` and a second one to set the sequence leaves a
    /// window where another connection's insert lands in between.
    func resetSequence(
        table: GenerationTableReference,
        column: String,
        sequenceName: String?
    ) async throws {
        let name = qualifiedName(table.table, schema: table.schema ?? schema)
        let quotedColumn = adapter.quoteIdentifier(column)
        switch databaseType {
        case .postgresql:
            let sequence = sequenceName.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                ?? "pg_get_serial_sequence('\(name.replacingOccurrences(of: "'", with: "''"))', '\(column.replacingOccurrences(of: "'", with: "''"))')"
            _ = try await driver.execute(
                query: """
                SELECT setval(\(sequence), (SELECT COALESCE(MAX(\(quotedColumn)), 0) + 1 FROM \(name)), false)
                """
            )
        case .mysql:
            let result = try await driver.execute(
                query: "SELECT COALESCE(MAX(\(quotedColumn)), 0) + 1 FROM \(name)"
            )
            guard let next = result.rows.first?.first?.textFallback, let value = Int64(next) else { return }
            _ = try await driver.execute(query: "ALTER TABLE \(name) AUTO_INCREMENT = \(value)")
        case .sqlite:
            _ = try? await driver.execute(
                query: """
                UPDATE sqlite_sequence SET seq = (SELECT COALESCE(MAX(\(quotedColumn)), 0) FROM \(name)) \
                WHERE name = '\(table.table.replacingOccurrences(of: "'", with: "''"))'
                """
            )
        default:
            return
        }
    }

    func loadDistinctValues(key: ReferenceKey, limit: Int) async throws -> [[PluginCellValue]] {
        let columnList = key.columns.map(adapter.quoteIdentifier).joined(separator: ", ")
        let table = qualifiedName(key.table, schema: key.schema ?? schema)
        let notNull = key.columns
            .map { "\(adapter.quoteIdentifier($0)) IS NOT NULL" }
            .joined(separator: " AND ")
        let query = "SELECT DISTINCT \(columnList) FROM \(table) WHERE \(notNull) LIMIT \(limit)"
        let result = try await driver.execute(query: query)
        return result.rows
    }

    private func statementGenerator(
        for table: GenerationTableReference,
        columns: [String]
    ) throws -> SQLStatementGenerator {
        let qualified = qualifiedName(table.table, schema: table.schema ?? schema)
        return try SQLStatementGenerator(
            tableName: qualified,
            columns: columns,
            primaryKeyColumns: [],
            databaseType: databaseType,
            quoteIdentifier: { name in
                name == qualified ? qualified : adapter.quoteIdentifier(name)
            }
        )
    }

    /// PostgreSQL leaves the identity sequence where it was after a plain
    /// `TRUNCATE`, so the next generated run starts above the keys it just
    /// removed. `CASCADE` is never used: it would delete rows in tables the user
    /// did not name.
    private func emptyStatements(_ table: GenerationTableReference, allowsTruncate: Bool) -> [String] {
        let name = qualifiedName(table.table, schema: table.schema ?? schema)
        guard allowsTruncate else { return ["DELETE FROM \(name)"] }
        switch databaseType {
        case .postgresql:
            return ["TRUNCATE TABLE \(name) RESTART IDENTITY"]
        default:
            return adapter.truncateTableStatements(table: table.table, schema: table.schema ?? schema, cascade: false)
        }
    }

    private func defaultValuesStatement(_ table: GenerationTableReference) -> String {
        let name = qualifiedName(table.table, schema: table.schema ?? schema)
        switch databaseType {
        case .mysql:
            return "INSERT INTO \(name) () VALUES ()"
        default:
            return "INSERT INTO \(name) DEFAULT VALUES"
        }
    }

    private func qualifiedName(_ table: String, schema: String?) -> String {
        guard let schema, !schema.isEmpty else { return adapter.quoteIdentifier(table) }
        return "\(adapter.quoteIdentifier(schema)).\(adapter.quoteIdentifier(table))"
    }
}
