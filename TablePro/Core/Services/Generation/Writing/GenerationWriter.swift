//
//  GenerationWriter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Buffers rows into batches and hands them to the driver. Sizing is
/// `TransferBatchSplitter`'s job and the SQL is the driver's; this type owns
/// neither.
final class GenerationWriter {
    private let driver: any GenerationDriver
    private let table: GenerationTableReference
    private let columns: [String]
    private let harvestColumns: [String]
    private let continueOnError: Bool

    private var splitter: TransferBatchSplitter
    private var pending: [[PluginCellValue]] = []

    private(set) var rowsWritten = 0
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
        continueOnError: Bool
    ) {
        self.driver = driver
        self.table = table
        self.columns = columns
        self.harvestColumns = harvestColumns
        self.continueOnError = continueOnError
        splitter = TransferBatchSplitter(
            maxBytes: max(1, (limits?.maxPacketBytes ?? TransferBatchSizing.defaultMaxBytes) - TransferBatchSizing.safetyMargin),
            maxBindParameters: limits?.maxBindParameters ?? maxBindParameters,
            columnCount: columns.count
        )
        harvestSupported = !harvestColumns.isEmpty
        harvestedRows = harvestColumns.isEmpty ? nil : []
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
            let harvested = try await driver.insert(
                table: table,
                columns: columns,
                rows: batch,
                harvestColumns: harvestSupported ? harvestColumns : []
            )
            rowsWritten += batch.count
            record(harvested)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard continueOnError else {
                throw GenerationError.writeFailed(table: table.qualifiedName, reason: error.localizedDescription)
            }
            failedBatches.append(error.localizedDescription)
        }
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
