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

    var isSequential: Bool { primaryKeyColumns.isEmpty }

    func chunkQuery(after cursor: TransferChunkCursor?, upperBound: String? = nil) -> String {
        guard !isSequential else { return "SELECT * FROM \(qualifiedTable)" }
        var sql = "SELECT * FROM \(qualifiedTable)"
        let predicates = predicates(after: cursor, upperBound: upperBound)
        if !predicates.isEmpty {
            sql += " WHERE \(predicates.joined(separator: " AND "))"
        }
        sql += " \(orderByClause()) LIMIT \(chunkSize)"
        return sql
    }

    private func predicates(after cursor: TransferChunkCursor?, upperBound: String?) -> [String] {
        var result: [String] = []
        if let lastKey = cursor?.lastKey, !lastKey.isEmpty {
            result.append(whereClause(for: lastKey))
        }
        if let upperBound, primaryKeyColumns.count == 1 {
            let column = quoteIdentifier(primaryKeyColumns[0])
            result.append("\(column) <= \(literal(upperBound))")
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
        let values = lastKey.map(literal)
        switch comparison {
        case .rowConstructor:
            let row = "(\(columns.joined(separator: ", ")))"
            let tuple = "(\(values.joined(separator: ", ")))"
            return "\(row) > \(tuple)"
        case .tupleOr:
            return "(\(tupleOrConditions(columns: columns, values: values).joined(separator: ") OR (")))"
        }
    }

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

    private func orderByClause() -> String {
        let parts = primaryKeyColumns.map { "\(quoteIdentifier($0)) ASC" }
        return "ORDER BY \(parts.joined(separator: ", "))"
    }

    private func literal(_ value: String) -> String {
        guard PluginNumericLiteral.isValid(value) else { return escapeStringLiteral(value) }
        return value
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
