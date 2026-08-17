//
//  GenerationDriver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Everything the engine asks of a server, and nothing else. A narrow surface is
/// what lets the run loop be tested without a database and what keeps the
/// vendor SQL on the plugin side of the boundary.
protocol GenerationDriver: Sendable {
    /// A connection the user has locked down. Generation inserts stay allowed on
    /// one; emptying a table first does not.
    var blocksDestructiveOperations: Bool { get }

    var supportsTransactions: Bool { get }

    func serverLimits() async throws -> PluginServerLimits?

    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws

    func setForeignKeyChecks(enabled: Bool) async throws

    /// Tables that carry a foreign key pointing at `table`, which is what decides
    /// whether emptying it can use `TRUNCATE` at all.
    func hasInboundForeignKeys(table: GenerationTableReference) async throws -> Bool

    /// `allowsTruncate` is false when a foreign key points at this table, where
    /// `TRUNCATE` is refused by the server and `CASCADE` would delete rows the
    /// user never named. The driver falls back to `DELETE` there.
    func emptyTable(_ table: GenerationTableReference, allowsTruncate: Bool) async throws

    /// Inserts one batch. The returned rows are the values `harvestColumns` ended
    /// up with, in insertion order; `nil` means this driver cannot harvest and
    /// the caller has to re-read the parent instead.
    func insert(
        table: GenerationTableReference,
        columns: [String],
        rows: [[PluginCellValue]],
        harvestColumns: [String]
    ) async throws -> [[PluginCellValue]]?

    func loadDistinctValues(key: ReferenceKey, limit: Int) async throws -> [[PluginCellValue]]

    /// The second pass. `assignments` carries, per row, the values for
    /// `setColumns` followed by the values for `keyColumns`, which is how a row
    /// written with a null foreign key is found again and filled.
    func update(
        table: GenerationTableReference,
        setColumns: [String],
        keyColumns: [String],
        assignments: [[PluginCellValue]]
    ) async throws

    /// Puts a sequence back above the keys the run wrote by hand. A driver whose
    /// server has nothing to reset does nothing.
    func resetSequence(
        table: GenerationTableReference,
        column: String,
        sequenceName: String?
    ) async throws
}

extension GenerationDriver {
    var blocksDestructiveOperations: Bool { false }
    var supportsTransactions: Bool { true }

    func serverLimits() async throws -> PluginServerLimits? { nil }

    func resetSequence(
        table: GenerationTableReference,
        column: String,
        sequenceName: String?
    ) async throws {}
}
