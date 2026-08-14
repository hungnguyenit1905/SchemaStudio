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
}

struct TransferReport: Sendable {
    let results: [TransferTableResult]
    let wasCancelled: Bool

    var failedCount: Int { results.count(where: { $0.errorMessage != nil }) }
    var warningCount: Int { results.count(where: { !$0.warningMessages.isEmpty }) }
    var notRunCount: Int { results.count(where: { !$0.didRun }) }
    var totalRows: Int { results.reduce(0) { $0 + $1.rowsTransferred } }
}

struct TransferState {
    var isTransferring: Bool = false
    var isCancelling: Bool = false
    var currentTable: String = ""
    var currentTableIndex: Int = 0
    var totalTables: Int = 0
    var processedRows: Int = 0
    var totalRows: Int = 0
    var statusMessage: String = ""
    var errorMessage: String?
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
        case .preflightFailed(let failures):
            let details = failures.map { "\($0.table): \($0.message)" }.joined(separator: "\n")
            return String(
                format: String(localized: "Nothing was changed. These tables cannot be transferred:\n%@"),
                details
            )
        }
    }
}
