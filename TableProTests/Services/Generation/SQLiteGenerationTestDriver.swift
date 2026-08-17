//
//  SQLiteGenerationTestDriver.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import SQLite3
import TableProPluginKit

/// A real SQLite database behind the engine's driver surface, so the integration
/// tests assert in SQL instead of against a recording. In-memory, which is what
/// keeps the suite runnable in CI without a server.
final class SQLiteGenerationTestDriver: GenerationDriver, @unchecked Sendable {
    struct SQLiteError: Error {
        let message: String
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?

    let blocksDestructiveOperations = false
    let supportsTransactions = true

    init() throws {
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK else {
            throw SQLiteError(message: "could not open an in-memory database")
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw SQLiteError(message: "\(text) while running \(sql)")
        }
    }

    func query(_ sql: String) throws -> [[PluginCellValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: "\(lastErrorMessage) while preparing \(sql)")
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[PluginCellValue]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_count(statement))
            rows.append((0 ..< count).map { Self.value(statement, at: Int32($0)) })
        }
        return rows
    }

    func scalar(_ sql: String) throws -> Int {
        guard let first = try query(sql).first?.first else { return 0 }
        return Int(first.textFallback) ?? 0
    }

    func serverLimits() async throws -> PluginServerLimits? {
        PluginServerLimits(maxPacketBytes: 1_048_576, maxBindParameters: 32_766)
    }

    func beginTransaction() async throws { try execute("BEGIN") }
    func commitTransaction() async throws { try execute("COMMIT") }
    func rollbackTransaction() async throws { try execute("ROLLBACK") }

    func setForeignKeyChecks(enabled: Bool) async throws {
        try execute("PRAGMA foreign_keys = \(enabled ? "ON" : "OFF")")
    }

    func hasInboundForeignKeys(table: GenerationTableReference) async throws -> Bool {
        let names = try query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap(\.first?.asText)
        for name in names {
            let keys = try query("PRAGMA foreign_key_list(\(Self.quote(name)))")
            if keys.contains(where: { $0.count > 2 && $0[2].textFallback == table.table }) { return true }
        }
        return false
    }

    func emptyTable(_ table: GenerationTableReference, allowsTruncate: Bool) async throws {
        try execute("DELETE FROM \(Self.quote(table.table))")
    }

    func insert(
        table: GenerationTableReference,
        columns: [String],
        rows: [[PluginCellValue]],
        harvestColumns: [String]
    ) async throws -> [[PluginCellValue]]? {
        guard !rows.isEmpty else { return nil }
        guard !columns.isEmpty else {
            for _ in rows {
                try execute("INSERT INTO \(Self.quote(table.table)) DEFAULT VALUES")
            }
            return nil
        }

        let columnList = columns.map(Self.quote).joined(separator: ", ")
        let tuple = "(\(columns.map { _ in "?" }.joined(separator: ", ")))"
        let values = rows.map { _ in tuple }.joined(separator: ", ")
        let sql = "INSERT INTO \(Self.quote(table.table)) (\(columnList)) VALUES \(values)"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: "\(lastErrorMessage) while preparing an insert into \(table.table)")
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        for row in rows {
            for value in row {
                bind(value, to: statement, at: index)
                index += 1
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError(message: "\(lastErrorMessage) while inserting into \(table.table)")
        }
        return nil
    }

    func update(
        table: GenerationTableReference,
        setColumns: [String],
        keyColumns: [String],
        assignments: [[PluginCellValue]]
    ) async throws {
        guard !setColumns.isEmpty, !keyColumns.isEmpty else { return }
        let assignmentList = setColumns.map { "\(Self.quote($0)) = ?" }.joined(separator: ", ")
        let predicate = keyColumns.map { "\(Self.quote($0)) = ?" }.joined(separator: " AND ")
        let sql = "UPDATE \(Self.quote(table.table)) SET \(assignmentList) WHERE \(predicate)"
        let expected = setColumns.count + keyColumns.count

        for assignment in assignments where assignment.count == expected {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SQLiteError(message: "\(lastErrorMessage) while preparing an update of \(table.table)")
            }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in assignment.enumerated() {
                bind(value, to: statement, at: Int32(offset + 1))
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteError(message: "\(lastErrorMessage) while updating \(table.table)")
            }
        }
    }

    /// SQLite hands out `max(rowid) + 1` on its own for a plain
    /// `INTEGER PRIMARY KEY`, so only an `AUTOINCREMENT` table keeps a counter
    /// that can fall behind, and only that table has a `sqlite_sequence` row.
    func resetSequence(
        table: GenerationTableReference,
        column: String,
        sequenceName: String?
    ) async throws {
        let names = try query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'")
        guard !names.isEmpty else { return }
        try execute(
            """
            UPDATE sqlite_sequence SET seq = \
            (SELECT COALESCE(MAX(\(Self.quote(column))), 0) FROM \(Self.quote(table.table))) \
            WHERE name = '\(table.table.replacingOccurrences(of: "'", with: "''"))'
            """
        )
    }

    func loadDistinctValues(key: ReferenceKey, limit: Int) async throws -> [[PluginCellValue]] {
        let columnList = key.columns.map(Self.quote).joined(separator: ", ")
        let notNull = key.columns.map { "\(Self.quote($0)) IS NOT NULL" }.joined(separator: " AND ")
        return try query(
            "SELECT DISTINCT \(columnList) FROM \(Self.quote(key.table)) WHERE \(notNull) LIMIT \(limit)"
        )
    }

    private var lastErrorMessage: String {
        sqlite3_errmsg(handle).map { String(cString: $0) } ?? "unknown error"
    }

    private func bind(_ value: PluginCellValue, to statement: OpaquePointer?, at index: Int32) {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case .int(let number):
            sqlite3_bind_int64(statement, index, number)
        case .double(let number):
            sqlite3_bind_double(statement, index, number)
        case .bool(let flag):
            sqlite3_bind_int64(statement, index, flag ? 1 : 0)
        case .bytes(let data):
            _ = data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
            }
        default:
            sqlite3_bind_text(statement, index, value.textFallback, -1, Self.transient)
        }
    }

    private static func value(_ statement: OpaquePointer?, at index: Int32) -> PluginCellValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, index) else { return .bytes(Data()) }
            return .bytes(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
        default:
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: text))
        }
    }

    private static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
