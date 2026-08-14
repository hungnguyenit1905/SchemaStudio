//
//  MySQLPluginDriver+Chunking.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    /// Boundary values that split a numeric primary key into roughly equal
    /// ranges, so one big table can be read by several connections at once.
    /// A non-numeric key cannot be split by arithmetic and returns nil. MySQL
    /// has no way to export a snapshot across connections, so parallel reads
    /// stay per-table consistent and the report says so.
    func primaryKeyRangeBoundaries(
        table: String,
        schema: String?,
        column: String,
        partitions: Int
    ) async throws -> [String]? {
        guard partitions > 1 else { return nil }
        if let sampled = try? await percentileBoundaries(
            table: table,
            column: column,
            partitions: partitions
        ), !sampled.isEmpty {
            return sampled
        }
        return try await valueRangeBoundaries(table: table, column: column, partitions: partitions)
    }

    /// Equal-row partitions, so a key with gaps does not leave workers idle.
    /// A server without window functions has no way to ask for this, and a
    /// failure here is never fatal: the caller falls back to the value split.
    private func percentileBoundaries(
        table: String,
        column: String,
        partitions: Int
    ) async throws -> [String] {
        guard MySQLPartitionBoundarySQL.supportsWindowFunctions(
            version: serverVersion,
            isMariaDB: isMariaDBServer
        ) else { return [] }

        let result = try await execute(
            query: MySQLPartitionBoundarySQL.percentileQuery(
                table: quoteIdentifier(table),
                column: quoteIdentifier(column),
                partitions: partitions
            )
        )
        let minimums = result.rows.compactMap { $0[safe: 0]?.asText }
        return MySQLPartitionBoundarySQL.boundaries(fromBucketMinimums: minimums)
    }

    private func valueRangeBoundaries(
        table: String,
        column: String,
        partitions: Int
    ) async throws -> [String]? {
        let quotedColumn = quoteIdentifier(column)
        let result = try await execute(
            query: "SELECT MIN(\(quotedColumn)), MAX(\(quotedColumn)) FROM \(quoteIdentifier(table))"
        )
        guard let row = result.rows.first,
              let minText = row[safe: 0]?.asText,
              let maxText = row[safe: 1]?.asText,
              let minValue = Double(minText),
              let maxValue = Double(maxText),
              minValue <= maxValue else {
            return nil
        }
        return Self.splitBoundaries(min: minValue, max: maxValue, partitions: partitions)
    }

    static func splitBoundaries(min: Double, max: Double, partitions: Int) -> [String] {
        guard partitions > 1, max > min else { return [] }
        var boundaries: [String] = []
        boundaries.reserveCapacity(partitions - 1)
        for index in 1 ..< partitions {
            let value = min + (max - min) * Double(index) / Double(partitions)
            boundaries.append(boundaryText(value))
        }
        return boundaries
    }

    private static func boundaryText(_ value: Double) -> String {
        if value.rounded() == value, value.magnitude < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }
}
