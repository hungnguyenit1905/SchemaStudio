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

    /// Whether `bulkLoadWriter` can hand one back. Asking has to be possible
    /// without opening a load, because opening one commits the connection to it.
    var supportsBulkLoad: Bool { get }

    /// Whether the vendor's bulk path needs a client-side local infile, which
    /// most hosting disables. MySQL's `LOAD DATA LOCAL INFILE` does; `COPY` does
    /// not.
    var requiresLocalInfile: Bool { get }

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

    /// Opens the vendor's bulk load path for one table. Returning nil is not an
    /// error: the caller writes prepared batches instead.
    func bulkLoadWriter(
        table: GenerationTableReference,
        columns: [String]
    ) async throws -> (any PluginBulkLoadWriter)?

    func loadDistinctValues(key: ReferenceKey, limit: Int) async throws -> [[PluginCellValue]]

    /// Runs a user-written `SELECT` once, before any row is built, and returns
    /// the values of the column it names. `limit` caps how many are kept, so a
    /// query that forgets its own `LIMIT` cannot pull a whole table into memory.
    func loadQueryValues(source: SqlQuerySource, limit: Int) async throws -> [PluginCellValue]

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
    var supportsBulkLoad: Bool { false }
    var requiresLocalInfile: Bool { false }

    func serverLimits() async throws -> PluginServerLimits? { nil }

    func bulkLoadWriter(
        table: GenerationTableReference,
        columns: [String]
    ) async throws -> (any PluginBulkLoadWriter)? { nil }

    func loadQueryValues(source: SqlQuerySource, limit: Int) async throws -> [PluginCellValue] { [] }

    func resetSequence(
        table: GenerationTableReference,
        column: String,
        sequenceName: String?
    ) async throws {}
}
