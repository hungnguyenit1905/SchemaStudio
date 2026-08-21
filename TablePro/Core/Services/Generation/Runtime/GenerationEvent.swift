//
//  GenerationEvent.swift
//  TablePro
//

import Foundation

struct GenerationTableReport: Sendable, Hashable {
    let table: String
    let rowsRequested: Int
    let rowsWritten: Int
    let failedBatches: Int
    let duration: TimeInterval
}

struct GenerationReport: Sendable, Hashable {
    let tables: [GenerationTableReport]
    let warnings: [GenerationWarning]
    let duration: TimeInterval
    let wasCancelled: Bool

    var totalRowsWritten: Int {
        tables.reduce(0) { $0 + $1.rowsWritten }
    }

    var totalFailedBatches: Int {
        tables.reduce(0) { $0 + $1.failedBatches }
    }
}

enum GenerationEvent: Sendable {
    case started(totalTables: Int, totalRows: Int)
    case tableStarted(table: String, rowCount: Int)
    case progress(table: String, rowsWritten: Int, totalRows: Int)
    case tableFinished(table: String, rowsWritten: Int, duration: TimeInterval)

    /// The `UPDATE` pass that fills the foreign keys pass one had to leave empty.
    case secondPassFinished(table: String, columns: [String], rowsUpdated: Int)
    case warning(String)
    case batchFailed(table: String, error: String)
    case finished(report: GenerationReport)
    case cancelled(rowsWritten: Int)
}
