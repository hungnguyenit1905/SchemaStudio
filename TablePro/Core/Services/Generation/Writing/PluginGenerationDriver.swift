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
    let blocksAllWrites: Bool

    init?(
        driver: DatabaseDriver,
        databaseType: DatabaseType,
        schema: String? = nil,
        blocksDestructiveOperations: Bool = false,
        blocksAllWrites: Bool = false
    ) {
        guard let adapter = driver as? PluginDriverAdapter else { return nil }
        self.driver = driver
        self.adapter = adapter
        self.databaseType = databaseType
        self.schema = schema
        self.blocksDestructiveOperations = blocksDestructiveOperations
        self.blocksAllWrites = blocksAllWrites
    }

    private var pluginDriver: any PluginDatabaseDriver { adapter.schemaPluginDriver }

    private var forwardsTypedCells: Bool {
        pluginDriver.capabilities.contains(.typedCellValues)
    }

    private func gated(_ cells: [PluginCellValue]) -> [PluginCellValue] {
        forwardsTypedCells ? cells : cells.downgradedToLegacyCases
    }

    private func gated(_ rows: [[PluginCellValue]]) -> [[PluginCellValue]] {
        forwardsTypedCells ? rows : rows.downgradedToLegacyCases
    }

    var supportsTransactions: Bool { pluginDriver.supportsTransactions }

    var supportsBulkLoad: Bool { pluginDriver.supportsBulkLoad }

    var requiresLocalInfile: Bool { databaseType == .mysql }

    func serverLimits() async throws -> PluginServerLimits? {
        try await pluginDriver.serverLimits()
    }

    func bulkLoadWriter(
        table: GenerationTableReference,
        columns: [String]
    ) async throws -> (any PluginBulkLoadWriter)? {
        guard let writer = try await pluginDriver.bulkLoadWriter(
            table: table.table,
            schema: table.schema ?? schema,
            columns: columns
        ) else { return nil }
        guard forwardsTypedCells else { return LegacyCellBulkLoadWriter(wrapping: writer) }
        return writer
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

    var canDisableForeignKeyChecks: Bool {
        adapter.foreignKeyDisableStatements() != nil
    }

    func setTriggerChecks(table: GenerationTableReference, enabled: Bool) async throws -> Bool {
        let statements = enabled
            ? adapter.triggerEnableStatements(table: table.table, schema: table.schema ?? schema)
            : adapter.triggerDisableStatements(table: table.table, schema: table.schema ?? schema)
        guard let statements else { return false }
        for statement in statements {
            _ = try await driver.execute(query: statement)
        }
        return true
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
                rows: gated(rows),
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
            _ = try await driver.executeParameterized(
                query: sql,
                parameters: assignment.map(\.asAny)
            )
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
        let result = try await driver.execute(
            query: Self.limitedDistinctSelect(
                columns: columnList,
                from: table,
                where: notNull,
                limit: limit,
                style: PluginManager.autoLimitStyle(for: databaseType)
            )
        )
        return result.rows
    }

    /// `LIMIT` is not universal: SQL Server spells it `TOP` before the column
    /// list and Oracle spells it `FETCH FIRST` after the predicate. This type
    /// serves every driver, so the clause comes from the dialect.
    private static func limitedDistinctSelect(
        columns: String,
        from table: String,
        where predicate: String,
        limit: Int,
        style: AutoLimitStyle
    ) -> String {
        switch style {
        case .top:
            return "SELECT DISTINCT TOP \(limit) \(columns) FROM \(table) WHERE \(predicate)"
        case .fetchFirst:
            return "SELECT DISTINCT \(columns) FROM \(table) WHERE \(predicate) FETCH FIRST \(limit) ROWS ONLY"
        case .none:
            return "SELECT DISTINCT \(columns) FROM \(table) WHERE \(predicate)"
        default:
            return "SELECT DISTINCT \(columns) FROM \(table) WHERE \(predicate) LIMIT \(limit)"
        }
    }

    func loadQueryValues(source: SqlQuerySource, limit: Int) async throws -> [PluginCellValue] {
        let result = try await driver.execute(query: source.query)
        let position: Int
        if let wanted = source.column {
            guard let found = result.columns.firstIndex(of: wanted) else {
                throw GenerationError.invalidParameters(
                    generator: SqlQueryGenerator.identifier,
                    reason: "the query returns no column named \(wanted)"
                )
            }
            position = found
        } else {
            position = 0
        }
        return result.rows.prefix(limit).compactMap { row in
            guard position < row.count else { return nil }
            return row[position]
        }
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
