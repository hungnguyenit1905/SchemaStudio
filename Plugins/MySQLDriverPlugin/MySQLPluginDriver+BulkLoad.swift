//
//  MySQLPluginDriver+BulkLoad.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// The bulk load path. It engages only when the server allows `local_infile`,
/// which the transfer probes through `serverLimits()` before it picks a
/// strategy, and it falls back to prepared batches by returning `nil` rather
/// than failing the run.
extension MySQLPluginDriver {
    /// Claiming the capability is what makes the transfer ask for a writer at
    /// all. Whether one is handed back still depends on `local_infile` at the
    /// server, which is probed per table.
    var supportsBulkLoad: Bool { true }

    func makeBulkLoadWriter(
        table: String,
        schema: String?,
        columns: [String]
    ) async throws -> PluginBulkLoadWriter? {
        guard let connection = activeConnection, !columns.isEmpty else { return nil }
        guard try await allowsLocalInfile() else {
            Self.logger.info("local_infile is off at the server, using prepared batches")
            return nil
        }

        let hexColumns = try await binaryColumnFlags(table: table, schema: schema, columns: columns)
        let statement = MySQLLoadDataStatement.statement(
            table: table,
            schema: schema,
            columns: columns,
            hexColumns: hexColumns,
            quote: quoteIdentifier
        )
        return MySQLBulkLoadWriter(
            connection: connection,
            statement: statement,
            hexColumns: hexColumns
        )
    }

    private func allowsLocalInfile() async throws -> Bool {
        let result = try await execute(query: "SELECT @@local_infile")
        return result.rows.first?[safe: 0]?.asText == "1"
    }

    /// Byte columns travel as hex and are put back together by `UNHEX` at the
    /// server, so their contents never pass through a charset conversion. The
    /// lookup is one query per table, not per row.
    private func binaryColumnFlags(
        table: String,
        schema: String?,
        columns: [String]
    ) async throws -> [Bool] {
        let database = schema ?? activeDatabaseName
        let sql = """
        SELECT COLUMN_NAME, DATA_TYPE FROM information_schema.COLUMNS \
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        """
        let result = try await executeParameterized(
            query: sql,
            parameters: [.text(database), .text(table)]
        )

        var types: [String: String] = [:]
        for row in result.rows {
            guard let name = row[safe: 0]?.asText, let type = row[safe: 1]?.asText else { continue }
            types[name.lowercased()] = type
        }
        return columns.map { column in
            guard let type = types[column.lowercased()] else { return false }
            return MySQLLoadDataStatement.isBinaryType(type)
        }
    }
}
