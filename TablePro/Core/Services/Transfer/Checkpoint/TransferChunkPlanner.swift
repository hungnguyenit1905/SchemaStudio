//
//  TransferChunkPlanner.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Where the next chunk starts. `lastKey` is the last primary key read, as
/// text, so a checkpoint survives a JSON round trip and still compares
/// cleanly after a reload: decimals for numbers, the driver's own rendering
/// for dates, quoted back as literals in the next chunk query.
struct TransferChunkCursor: Sendable, Codable, Hashable {
    let lastKey: [String]?
    let rowsDone: Int

    static let start = TransferChunkCursor(lastKey: nil, rowsDone: 0)

    var isStart: Bool { lastKey == nil || lastKey?.isEmpty == true }
}

/// How a key value is written into a chunk predicate. A value's own shape
/// cannot decide this: "123" out of a VARCHAR key has to stay quoted, or the
/// engine compares it as a number against a column it orders as text, and the
/// chunk then skips rows (MySQL), fails outright (PostgreSQL) or re-reads rows
/// it already copied (SQLite). A column whose type says nothing useful, such as
/// an undeclared SQLite column, keeps the value-shape fallback.
enum TransferKeyLiteralKind: String, Sendable, Hashable {
    case textual
    case numeric
}

/// Builds the keyset queries that move through a table one bounded chunk at a
/// time. Keyset pagination never rescans what it already read, unlike OFFSET,
/// which is O(n) per page and makes chunk 1000 a thousand times slower than
/// chunk 1. A table without a primary key falls back to one sequential read
/// with no chunk-level resume.
struct TransferChunkPlanner: Sendable {
    enum Comparison: Sendable, Equatable {
        /// `(a, b) > (?, ?)`. MySQL and PostgreSQL support row constructors.
        case rowConstructor
        /// `(a > ?) OR (a = ? AND b > ?)`. SQLite and SQL Server compare one
        /// row value at a time only, so a composite key is spelled out.
        case tupleOr
    }

    let qualifiedTable: String
    let primaryKeyColumns: [String]
    let chunkSize: Int
    let comparison: Comparison
    let quoteIdentifier: @Sendable (String) -> String
    let escapeStringLiteral: @Sendable (String) -> String
    var keyLiteralKinds: [String: TransferKeyLiteralKind] = [:]

    var isSequential: Bool { primaryKeyColumns.isEmpty }

    func chunkQuery(after cursor: TransferChunkCursor?, upperBound: String? = nil) -> String {
        guard !isSequential else { return "SELECT * FROM \(qualifiedTable)" }
        var sql = "SELECT * FROM \(qualifiedTable)"
        if let boundary = boundaryPredicate(after: cursor, upperBound: upperBound) {
            sql += " WHERE \(boundary)"
        }
        sql += " \(orderByClause()) LIMIT \(chunkSize)"
        return sql
    }

    /// The keyset boundary on its own, so a feature that builds a different statement around it
    /// still gets the same predicate. Duplicate's chunked copy is an `INSERT … SELECT` with an
    /// explicit column list, which `chunkQuery`'s `SELECT *` cannot express.
    func boundaryPredicate(after cursor: TransferChunkCursor?, upperBound: String? = nil) -> String? {
        let predicates = predicates(after: cursor, upperBound: upperBound)
        guard !predicates.isEmpty else { return nil }
        return predicates.joined(separator: " AND ")
    }

    func orderByClause() -> String {
        let parts = primaryKeyColumns.map { "\(quoteIdentifier($0)) ASC" }
        return "ORDER BY \(parts.joined(separator: ", "))"
    }

    private func predicates(after cursor: TransferChunkCursor?, upperBound: String?) -> [String] {
        var result: [String] = []
        if let lastKey = cursor?.lastKey, !lastKey.isEmpty {
            result.append(whereClause(for: lastKey))
        }
        if let upperBound, primaryKeyColumns.count == 1, let keyColumn = primaryKeyColumns.first {
            let column = quoteIdentifier(keyColumn)
            result.append("\(column) <= \(literal(upperBound, column: keyColumn))")
        }
        return result
    }

    /// The cursor for the next chunk, taken from the last row just read. An
    /// empty chunk has no cursor: there is nothing after it to resume from.
    func nextCursor(
        after rows: [[PluginCellValue]],
        headerColumns: [String],
        previous: TransferChunkCursor?
    ) -> TransferChunkCursor? {
        guard !isSequential, let last = rows.last else { return nil }
        var keys: [String] = []
        keys.reserveCapacity(primaryKeyColumns.count)
        for column in primaryKeyColumns {
            guard let index = headerColumns.firstIndex(of: column) else { return nil }
            keys.append(Self.keyText(last[index]))
        }
        return TransferChunkCursor(
            lastKey: keys,
            rowsDone: (previous?.rowsDone ?? 0) + rows.count
        )
    }

    private func whereClause(for lastKey: [String]) -> String {
        let columns = primaryKeyColumns.map(quoteIdentifier)
        let values = zip(primaryKeyColumns, lastKey).map { literal($1, column: $0) }
        guard columns.count > 1, let column = columns.first, let value = values.first else {
            return "\(columns.joined()) > \(values.joined())"
        }
        switch comparison {
        case .rowConstructor:
            let row = "(\(columns.joined(separator: ", ")))"
            let tuple = "(\(values.joined(separator: ", ")))"
            return "\(row) > \(tuple)"
        case .tupleOr:
            let rest = tupleOrConditions(columns: columns, values: values)
                .dropFirst()
                .map { "(\($0))" }
            return "(\(([("\(column) > \(value)")] + rest).joined(separator: " OR ")))"
        }
    }

    /// The whole OR chain is one parenthesised group: an upper bound is ANDed
    /// onto it, and `a OR b AND bound` would bind the AND to the last branch
    /// only and read rows past the partition's end.
    private func tupleOrConditions(columns: [String], values: [String]) -> [String] {
        var conditions: [String] = []
        for index in columns.indices {
            var condition = ""
            for prior in 0 ..< index {
                condition += "\(columns[prior]) = \(values[prior]) AND "
            }
            condition += "\(columns[index]) > \(values[index])"
            conditions.append(condition)
        }
        return conditions
    }

    private func literal(_ value: String, column: String) -> String {
        switch keyLiteralKinds[column] {
        case .textual:
            return escapeStringLiteral(value)
        case .numeric, nil:
            guard PluginNumericLiteral.isValid(value) else { return escapeStringLiteral(value) }
            return value
        }
    }

    /// Reads each key column's declared type through the source vendor's own
    /// parser. A type the parser cannot place, including an SQLite column with
    /// no declared type, is left out so the value-shape fallback still applies.
    static func keyLiteralKinds(
        columns: [PluginColumnInfo],
        primaryKeyColumns: [String],
        databaseType: DatabaseType
    ) -> [String: TransferKeyLiteralKind] {
        guard let parser = NativeTypeParserRegistry.parser(for: databaseType) else { return [:] }
        let keys = Set(primaryKeyColumns)
        var kinds: [String: TransferKeyLiteralKind] = [:]
        for column in columns where keys.contains(column.name) {
            let base = parser.parse(column.dataType, allowedValues: column.allowedValues).base
            guard let kind = literalKind(for: base) else { continue }
            kinds[column.name] = kind
        }
        return kinds
    }

    private static func literalKind(for base: TransferBaseType) -> TransferKeyLiteralKind? {
        switch base {
        case .string, .text, .uuid, .enumeration, .set, .json:
            return .textual
        case .bool, .int8, .int16, .int32, .int64, .decimal, .float32, .float64:
            return .numeric
        case .bytes, .date, .time, .timestamp, .timestampTZ, .interval, .geometry, .unknown:
            return nil
        }
    }

    static func keyText(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return ""
        case .text(let text):
            return text
        case .bytes(let data):
            var hex = ""
            hex.reserveCapacity(data.count * 2)
            for byte in data {
                hex += String(format: "%02X", byte)
            }
            return hex
        case .int, .double, .decimalText, .bool, .date, .time, .timestamp, .uuid, .array:
            return value.textFallback
        @unknown default:
            return value.textFallback
        }
    }
}

/// Gates parallel reads inside one table. `EstRows` is an estimate off by up
/// to ±50%, and PostgreSQL reports `-1` (or `0` on old servers) for a table
/// it never analyzed. Those mean "unknown", never "empty", so they keep
/// parallel reads off: precomputing boundaries costs a full index scan, which
/// only pays off on a table that is genuinely large.
enum TransferParallelism {
    static func shouldParallelize(estimatedRows: Int?, threshold: Int) -> Bool {
        guard let estimatedRows, estimatedRows > 0 else { return false }
        return estimatedRows >= threshold
    }
}
