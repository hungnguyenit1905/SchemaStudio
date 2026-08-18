//
//  GenerationWriter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Buffers rows into batches and hands them to the driver, through the vendor's
/// bulk load path where the route picked one and prepared batches otherwise.
/// Sizing is `TransferBatchSplitter`'s job and the SQL is the driver's; this type
/// owns neither.
final class GenerationWriter {
    private static let logger = Logger(subsystem: "com.SchemaStudio", category: "GenerationWriter")

    private let driver: any GenerationDriver
    private let table: GenerationTableReference
    private let columns: [String]
    private let harvestColumns: [String]
    private let continueOnError: Bool
    private let onBatchWritten: (@Sendable (Int) async -> Void)?

    private var splitter: TransferBatchSplitter
    private var pending: [[PluginCellValue]] = []
    private var usesBulkLoad: Bool
    private var bulkWriter: (any PluginBulkLoadWriter)?

    private(set) var rowsWritten: Int
    private(set) var failedBatches: [String] = []
    private(set) var harvestedRows: [[PluginCellValue]]?
    private(set) var harvestSupported: Bool

    init(
        driver: any GenerationDriver,
        table: GenerationTableReference,
        columns: [String],
        harvestColumns: [String],
        limits: PluginServerLimits?,
        maxBindParameters: Int,
        continueOnError: Bool,
        strategy: TransferLoadStrategy = .preparedBatch,
        rowsAlreadyWritten: Int = 0,
        onBatchWritten: (@Sendable (Int) async -> Void)? = nil
    ) {
        self.driver = driver
        self.table = table
        self.columns = columns
        self.harvestColumns = harvestColumns
        self.continueOnError = continueOnError
        self.onBatchWritten = onBatchWritten
        usesBulkLoad = strategy == .bulk
        rowsWritten = rowsAlreadyWritten
        splitter = Self.splitter(
            limits: limits,
            maxBindParameters: maxBindParameters,
            columnCount: columns.count,
            strategy: strategy
        )
        harvestSupported = !harvestColumns.isEmpty
        harvestedRows = harvestColumns.isEmpty ? nil : []
    }

    /// A bulk stream is cut by bytes alone: it carries no bind parameters, so the
    /// parameter ceiling that shapes a prepared batch does not apply to it.
    private static func splitter(
        limits: PluginServerLimits?,
        maxBindParameters: Int,
        columnCount: Int,
        strategy: TransferLoadStrategy
    ) -> TransferBatchSplitter {
        let maxBytes = max(
            1,
            (limits?.maxPacketBytes ?? TransferBatchSizing.defaultMaxBytes) - TransferBatchSizing.safetyMargin
        )
        return TransferBatchSplitter(
            maxBytes: maxBytes,
            maxBindParameters: strategy == .bulk ? .max : (limits?.maxBindParameters ?? maxBindParameters),
            columnCount: columnCount
        )
    }

    func append(_ row: [PluginCellValue]) async throws {
        switch splitter.append(row, estimatedBytes: TransferBatchSplitter.estimatedBytes(for: row)) {
        case .buffered:
            pending.append(row)
        case .flushBefore:
            try await flush()
            _ = splitter.append(row, estimatedBytes: TransferBatchSplitter.estimatedBytes(for: row))
            pending.append(row)
        case .sendAlone:
            try await flush()
            pending.append(row)
            try await flush()
        }
    }

    func flush() async throws {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        splitter.reset()

        do {
            try await write(batch)
            rowsWritten += batch.count
            await reportProgress()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard continueOnError else {
                throw GenerationError.writeFailed(table: table.qualifiedName, reason: error.localizedDescription)
            }
            failedBatches.append(error.localizedDescription)
        }
    }

    /// Ends the table. A bulk stream reports what the server accepted, which is
    /// the number the report carries from then on: the per-batch count is only an
    /// estimate while the stream is still open.
    ///
    /// The writer is kept until the stream has actually ended, because `finish` is
    /// where a bulk load fails most often (a constraint violation surfaces at
    /// commit, not at write) and a caller's `abort` has to still reach the stream.
    func finish() async throws {
        try await flush()
        guard let writer = bulkWriter else { return }
        do {
            let accepted = try await writer.finish()
            bulkWriter = nil
            if accepted > 0 {
                rowsWritten = accepted
            }
            await reportProgress()
        } catch {
            bulkWriter = nil
            await writer.abort()
            throw error
        }
    }

    /// Tears a half-open bulk stream down so the connection never stays in a
    /// loading state. Safe to call after `finish` and safe to call twice.
    func abort() async {
        await bulkWriter?.abort()
        bulkWriter = nil
        pending.removeAll(keepingCapacity: false)
    }

    /// A prepared batch is its own statement, so a flush that returned means the
    /// server holds those rows and progress can be recorded. A bulk chunk is not:
    /// `COPY` and `LOAD DATA` buffer and commit as one unit at `finish`, and an
    /// abort discards every chunk already streamed. Reporting per chunk would tell
    /// a resumed run that rows exist which the abort threw away, and it would skip
    /// them. A bulk table therefore reports once, after the stream ended.
    private func reportProgress() async {
        guard !usesBulkLoad || bulkWriter == nil else { return }
        await onBatchWritten?(rowsWritten)
    }

    private func write(_ batch: [[PluginCellValue]]) async throws {
        guard usesBulkLoad else {
            record(
                try await driver.insert(
                    table: table,
                    columns: columns,
                    rows: batch,
                    harvestColumns: harvestSupported ? harvestColumns : []
                )
            )
            return
        }
        guard let writer = try await bulkLoadWriter() else {
            usesBulkLoad = false
            Self.logger.warning(
                """
                No bulk writer for \(self.table.qualifiedName, privacy: .public), \
                falling back to prepared batches
                """
            )
            try await write(batch)
            return
        }
        try await writer.write(rows: batch)
    }

    private func bulkLoadWriter() async throws -> (any PluginBulkLoadWriter)? {
        if let bulkWriter { return bulkWriter }
        bulkWriter = try await driver.bulkLoadWriter(table: table, columns: columns)
        return bulkWriter
    }

    /// A driver that hands back no keys is not an error: the caller re-reads the
    /// parent table instead, which is the path every bundled driver takes today.
    private func record(_ harvested: [[PluginCellValue]]?) {
        guard harvestSupported else { return }
        guard let harvested else {
            harvestSupported = false
            harvestedRows = nil
            return
        }
        harvestedRows?.append(contentsOf: harvested)
    }
}
