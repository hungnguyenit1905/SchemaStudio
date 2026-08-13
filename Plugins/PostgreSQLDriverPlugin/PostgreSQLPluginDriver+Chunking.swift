//
//  PostgreSQLPluginDriver+Chunking.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension LibPQBackedDriver {
    /// Opens a `REPEATABLE READ` transaction and exports its snapshot id so
    /// other connections can read the same point in time, the way `pg_dump -j`
    /// fans a dump out over several connections. The transaction stays open
    /// until the caller rolls it back.
    func exportSnapshotToken() async throws -> String? {
        do {
            _ = try await execute(query: "BEGIN ISOLATION LEVEL REPEATABLE READ")
            let result = try await execute(query: "SELECT pg_export_snapshot()")
            guard let token = result.rows.first?[safe: 0]?.asText, !token.isEmpty else {
                _ = try? await execute(query: "ROLLBACK")
                return nil
            }
            return token
        } catch {
            _ = try? await execute(query: "ROLLBACK")
            throw error
        }
    }

    /// Adopts a snapshot another connection exported. The adopting connection
    /// must not have read anything yet in its transaction, so this runs as the
    /// first command after `BEGIN`. A failure rolls the transaction back and
    /// reports false; the caller then reads without a shared snapshot and the
    /// report downgrades to per-table consistency.
    func adoptSnapshotToken(_ token: String) async throws -> Bool {
        let escaped = token.replacingOccurrences(of: "'", with: "''")
        do {
            _ = try await execute(query: "BEGIN")
            _ = try await execute(query: "SET TRANSACTION SNAPSHOT '\(escaped)'")
            return true
        } catch {
            _ = try? await execute(query: "ROLLBACK")
            return false
        }
    }

    /// Boundary values that split a numeric primary key into roughly equal
    /// ranges. Only a numeric key can be split by arithmetic: a UUID or text
    /// key returns nil and the caller keeps sequential keyset chunks. The
    /// boundaries are the split points, one fewer than the partition count.
    func primaryKeyRangeBoundaries(
        table: String,
        schema: String?,
        column: String,
        partitions: Int
    ) async throws -> [String]? {
        guard partitions > 1 else { return nil }
        let schemaName = schema ?? core.currentSchema
        let qualified = "\(quoteIdentifier(schemaName)).\(quoteIdentifier(table))"
        let quotedColumn = quoteIdentifier(column)
        let result = try await execute(
            query: "SELECT MIN(\(quotedColumn)), MAX(\(quotedColumn)) FROM \(qualified)"
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
