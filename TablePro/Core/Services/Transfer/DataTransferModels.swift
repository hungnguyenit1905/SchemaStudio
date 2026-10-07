//
//  DataTransferModels.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum TransferMode: String, CaseIterable, Sendable, Identifiable {
    case copy
    case emptyThenTransfer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .copy:
            return String(localized: "Copy (drop and recreate target)")
        case .emptyThenTransfer:
            return String(localized: "Empty target then transfer")
        }
    }
}

struct TransferOptions: Sendable, Hashable {
    var createTargetIfNotExists: Bool = true
    var useSingleTransaction: Bool = true
    var continueOnError: Bool = false
    var parallelTables: Int = 1
    var inTableParallelism: Int = 2
}

struct TransferEndpoint: Sendable, Hashable {
    let connectionId: UUID
    let databaseType: DatabaseType
    let database: String
    let schema: String?

    init(connectionId: UUID, databaseType: DatabaseType, database: String, schema: String?) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.database = database
        self.schema = schema.flatMap { $0.isEmpty ? nil : $0 }
    }

    var scope: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: database, schema: schema)
    }
}

struct TransferTableSelection: Identifiable, Hashable, Sendable {
    let id: UUID
    let table: String

    init(id: UUID = UUID(), table: String) {
        self.id = id
        self.table = table
    }
}

enum TransferTableOutcome: Sendable, Hashable {
    case succeeded
    case warned([String])
    case failed(String)
    case notRun
}

struct TransferTableResult: Sendable, Identifiable, Hashable {
    let table: String
    let rowsTransferred: Int
    let duration: TimeInterval
    let outcome: TransferTableOutcome
    let sourceCount: Int?
    let targetCount: Int?

    var id: String { table }

    var errorMessage: String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    var warningMessages: [String] {
        if case .warned(let messages) = outcome { return messages }
        return []
    }

    var didRun: Bool { outcome != .notRun }

    var countsMatch: Bool? {
        guard let sourceCount, let targetCount else { return nil }
        return sourceCount == targetCount
    }
}

/// How consistent the source reads were. A PostgreSQL run pins one snapshot
/// and every connection reads it, which is `databaseWide`. Without a shared
/// snapshot (MySQL, SQLite, SQL Server), each table is read at its own point
/// in time and the report says `perTable` rather than implying more.
enum TransferConsistency: Sendable, Hashable {
    case databaseWide
    case perTable

    var displayName: String {
        switch self {
        case .databaseWide:
            return String(localized: "Consistent across the whole database")
        case .perTable:
            return String(
                localized: "Consistent per table only, not across the whole database"
            )
        }
    }
}

struct TransferReport: Sendable {
    let results: [TransferTableResult]
    let wasCancelled: Bool
    let consistency: TransferConsistency

    init(results: [TransferTableResult], wasCancelled: Bool, consistency: TransferConsistency = .perTable) {
        self.results = results
        self.wasCancelled = wasCancelled
        self.consistency = consistency
    }

    var failedCount: Int { results.count(where: { $0.errorMessage != nil }) }
    var warningCount: Int { results.count(where: { !$0.warningMessages.isEmpty }) }
    var notRunCount: Int { results.count(where: { !$0.didRun }) }
    var totalRows: Int { results.reduce(0) { $0 + $1.rowsTransferred } }
    var mismatchedCounts: [TransferTableResult] {
        results.filter { $0.countsMatch == false }
    }
}

/// Where a previous run of the same source/target/mode left off, loaded from
/// the checkpoint store before the run starts.
struct TransferResumeState: Sendable {
    let manifest: PluginTransferCheckpointManifest
    let entries: [TransferCheckpointStore.Entry]

    func entry(table: String, partition: Int = 0) -> TransferCheckpointStore.Entry? {
        entries.first { $0.table == table && $0.partition == partition }
    }

    /// A table whose every partition recorded its final chunk is fully copied.
    func isComplete(table: String) -> Bool {
        guard let tableManifest = manifest.tables.first(where: { $0.table == table }) else { return false }
        return (0 ..< tableManifest.partitionCount).allSatisfy { partition in
            entry(table: table, partition: partition)?.isComplete == true
        }
    }

    /// Any recorded progress at all, which means the target already holds
    /// committed rows for this table and must not be dropped or truncated.
    func hasProgress(table: String) -> Bool {
        entries.contains { $0.table == table }
    }

    func rowsDone(table: String) -> Int {
        entries.filter { $0.table == table }.reduce(0) { $0 + $1.cursor.rowsDone }
    }

    func boundaries(table: String) -> [String]? {
        manifest.tables.first(where: { $0.table == table })?.boundaries
    }
}

extension TransferCheckpointStore.State {
    init(_ state: PluginTransferCheckpointState) {
        self.init(
            manifest: state.manifest,
            entries: state.entries.map {
                TransferCheckpointStore.Entry(
                    table: $0.table,
                    partition: $0.partition,
                    cursor: TransferChunkCursor(lastKey: $0.lastKey, rowsDone: $0.rowsDone),
                    isComplete: $0.isComplete
                )
            }
        )
    }
}

extension TransferResumeState {
    init(_ state: PluginTransferCheckpointState) {
        self.init(manifest: state.manifest, entries: TransferCheckpointStore.State(state).entries)
    }
}

struct TransferState {
    var isTransferring: Bool = false
    var isCancelling: Bool = false
    var currentTable: String = ""
    var currentTableIndex: Int = 0
    var totalTables: Int = 0
    var processedRows: Int = 0
    var currentTableProcessedRows: Int = 0
    var currentTableEstimatedRows: Int = 0
    var statusMessage: String = ""
    var errorMessage: String?
}

extension TransferState {
    /// Progress is measured in tables, which is exact, with the table currently
    /// copying contributing its own fraction. An approximate row count is only
    /// ever that one fraction, so it can no longer push the bar past 100%.
    /// `nil` means there is nothing to measure against, so show an
    /// indeterminate bar.
    var progressFraction: Double? {
        guard totalTables > 0 else { return nil }
        let completedTables = Double(max(0, currentTableIndex - 1))
        return min(1, (completedTables + currentTableFraction) / Double(totalTables))
    }

    private var currentTableFraction: Double {
        guard currentTableEstimatedRows > 0 else { return 0 }
        return min(1, Double(currentTableProcessedRows) / Double(currentTableEstimatedRows))
    }
}

enum TransferError: LocalizedError, Equatable {
    case noTablesSelected
    case differentDatabaseTypes(source: String, target: String)
    case sameEndpoint
    case targetIsReadOnly
    case noPluginDriver
    case structureUnavailable(String)
    case createTableUnsupported(String)
    case missingTargetTable(String)
    case targetColumnsMissing(table: String, columns: [String])
    case blockingForeignKeys(table: String, references: [String])
    case emptyColumnMapping(String)
    case columnMappingIncomplete(String)
    case chunkCursorUnavailable(String)
    case resumeUnsupported(String)
    case resumeStateUnavailable
    case commitOutcomeUnknown
    case preflightFailed([TransferPreflightFailure])

    var errorDescription: String? {
        switch self {
        case .noTablesSelected:
            return String(localized: "No tables selected for transfer")
        case .differentDatabaseTypes(let source, let target):
            return String(
                format: String(
                    localized: "Data Transfer needs both connections to use the same database type (%@ and %@)."
                ),
                source,
                target
            )
        case .sameEndpoint:
            return String(localized: "Source and target point at the same database. Pick a different target.")
        case .targetIsReadOnly:
            return String(
                localized: "The target connection blocks writes. Change its safe mode level to transfer into it."
            )
        case .noPluginDriver:
            return String(localized: "This database type has no driver that can read or write table structure.")
        case .structureUnavailable(let table):
            return String(format: String(localized: "Could not read the structure of '%@'."), table)
        case .createTableUnsupported(let table):
            return String(format: String(localized: "This database type cannot create table '%@'."), table)
        case .missingTargetTable(let table):
            return String(
                format: String(localized: "Table '%@' does not exist at the target and 'Create target table' is off."),
                table
            )
        case .targetColumnsMissing(let table, let columns):
            return String(
                format: String(localized: "Target table '%@' is missing these columns: %@"),
                table,
                columns.joined(separator: ", ")
            )
        case .blockingForeignKeys(let table, let references):
            return String(
                format: String(localized: "Table '%@' cannot be dropped, it is referenced by: %@"),
                table,
                references.joined(separator: ", ")
            )
        case .emptyColumnMapping(let table):
            return String(
                format: String(
                    localized: "No column of '%@' could be matched at the target, so no row would be written."
                ),
                table
            )
        case .columnMappingIncomplete(let table):
            return String(
                format: String(localized: "Some columns of '%@' have no match at the target, so rows would lose data."),
                table
            )
        case .chunkCursorUnavailable(let table):
            return String(
                format: String(
                    localized: "Table '%@' has a primary key that never appears in its rows, so chunked transfer cannot continue."
                ),
                table
            )
        case .resumeUnsupported(let database):
            return String(
                format: String(localized: "%@ cannot safely resume per-chunk transfers."),
                database
            )
        case .resumeStateUnavailable:
            return String(localized: "The target checkpoint does not match this transfer. Start over to continue.")
        case .commitOutcomeUnknown:
            return String(localized: "The target did not confirm the last commit. Check its rows before retrying.")
        case .preflightFailed(let failures):
            let details = failures.map { "\($0.table): \($0.message)" }.joined(separator: "\n")
            return String(
                format: String(localized: "Nothing was changed. These tables cannot be transferred:\n%@"),
                details
            )
        }
    }
}
