//
//  DataTransferService+Writer.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// The writer side of the chunked pipeline: it consumes bounded chunks from the
/// reader, batches their rows into the target through the prepared or bulk
/// path, commits per chunk when the user did not ask for a single transaction,
/// and records the checkpoint after each commit so a crash resumes cleanly.
extension DataTransferService {
    internal func writeChunks(
        plan: TransferTablePlan,
        target: TransferDriverContext,
        limits: PluginServerLimits?,
        options: TransferOptions,
        checkpoint: TransferCheckpointStore?,
        jobId: UUID,
        partition: Int,
        stream: AsyncThrowingStream<TransferPipelineEvent, Error>,
        gate: TransferBackpressureGate,
        generatedColumns: Set<String>
    ) async throws -> Int {
        // The writer owns the gate's release: when it exits, whether by
        // success, error or cancellation, the reader must wake up and stop.
        defer { Task { await gate.releaseAll() } }

        var state = TransferWriterState()
        var written = 0
        var bulkRowsRecorded = 0
        let commitPerChunk = !options.useSingleTransaction
        var lastCursor: TransferChunkCursor?

        do {
            for try await event in stream {
                if shouldStop { throw CancellationError() }
                switch event {
                case .header(let header):
                    try await setupWriter(
                        plan: plan,
                        target: target,
                        limits: limits,
                        options: options,
                        header: header,
                        generatedColumns: generatedColumns,
                        state: &state
                    )
                case .chunk(let chunk):
                    let before = written
                    if commitPerChunk {
                        written += try await writeCommittedChunk(
                            chunk,
                            plan: plan,
                            target: target,
                            limits: limits,
                            options: options,
                            generatedColumns: generatedColumns,
                            checkpoint: checkpoint,
                            jobId: jobId,
                            state: &state
                        )
                    } else {
                        let rows = try await writeBufferedChunk(
                            chunk,
                            plan: plan,
                            target: target,
                            limits: limits,
                            generatedColumns: generatedColumns,
                            state: &state
                        )
                        // A buffered bulk load reports its total once, from
                        // `finish()`, so counting the chunk here as well would
                        // report every row twice.
                        if state.useBulk {
                            bulkRowsRecorded += rows
                            recordWrittenRows(rows)
                        } else {
                            written += rows
                        }
                    }
                    // A chunk is counted once here, after its retries and its
                    // trailing partial batch have settled, so a retried chunk
                    // never counts twice.
                    recordWrittenRows(written - before)
                    lastCursor = chunk.cursor
                    await gate.release()
                }
            }

            if !commitPerChunk {
                let beforeFinish = written
                let finished = try await finishBufferedTable(
                    plan: plan,
                    target: target,
                    checkpoint: checkpoint,
                    jobId: jobId,
                    partition: partition,
                    cursor: lastCursor,
                    state: &state
                )
                written = state.useBulk ? finished : written + finished
                recordWrittenRows(state.useBulk ? finished - bulkRowsRecorded : written - beforeFinish)
            }

            try await restoreWriter(target: target, state: &state)
            return written
        } catch {
            try? await abortWriter(target: target, state: &state)
            throw error
        }
    }

    private func setupWriter(
        plan: TransferTablePlan,
        target: TransferDriverContext,
        limits: PluginServerLimits?,
        options: TransferOptions,
        header: TransferPipelineHeader,
        generatedColumns: Set<String>,
        state: inout TransferWriterState
    ) async throws {
        let targetColumns = header.columns.filter { !generatedColumns.contains($0) }
        let decision = TransferLoadStrategyResolver.resolve(
            bulkWriterAvailable: target.supportsBulkLoad,
            supportsLocalInfile: limits?.supportsLocalInfile,
            localInfileRequired: target.databaseType == .mysql,
            continueOnError: options.continueOnError
        )

        if decision.strategy == .bulk {
            state.useBulk = true
            state.bulkColumns = targetColumns
            Self.logger.info("Bulk load path active for \(plan.table, privacy: .public)")
            if target.supportsForeignKeyCheckToggle {
                try await target.setForeignKeyChecks(enabled: false)
                state.foreignKeyScope = .driver
            }
        } else {
            let reason = decision.reason?.rawValue ?? TransferLoadFallbackReason.noBulkWriter.rawValue
            Self.logger.info(
                "Prepared batch path for \(plan.table, privacy: .public): \(reason, privacy: .public)"
            )
            try await usePreparedPath(
                plan: plan,
                target: target,
                limits: limits,
                headerColumns: header.columns,
                targetColumns: targetColumns,
                state: &state
            )
        }

        if options.useSingleTransaction {
            try await target.driver.beginTransaction(mode: .readWrite)
            state.transactionOpen = true
        }
    }

    /// The prepared-statement sink, used both when the resolver picks it up
    /// front and when a driver that claimed bulk load hands back no writer.
    /// The foreign key checks are left alone when they are already off through
    /// the driver, so a downgrade never toggles them twice.
    private func usePreparedPath(
        plan: TransferTablePlan,
        target: TransferDriverContext,
        limits: PluginServerLimits?,
        headerColumns: [String],
        targetColumns: [String],
        state: inout TransferWriterState
    ) async throws {
        state.useBulk = false
        state.bulkWriter = nil
        state.targetColumns = targetColumns
        state.sink = try makeSink(
            plan: plan,
            header: PluginStreamHeader(columns: headerColumns, columnTypeNames: []),
            target: target
        )
        state.splitter = TransferBatchSplitter(
            maxBytes: Self.batchMaxBytes(from: limits),
            maxBindParameters: TransferBindParameterLimits.maxBindParameters(for: target.databaseType, limits: limits),
            columnCount: max(targetColumns.count, 1)
        )
        guard state.foreignKeyScope == .none else { return }
        try await state.sink?.disableForeignKeyChecks()
        state.foreignKeyScope = .sink
    }

    /// One chunk inside its own transaction: begin, write, commit, then
    /// checkpoint. A retryable failure rolls back and retries the whole chunk
    /// with backoff; a constraint violation salvages the good rows one by one.
    private func writeCommittedChunk(
        _ chunk: TransferPipelineChunk,
        plan: TransferTablePlan,
        target: TransferDriverContext,
        limits: PluginServerLimits?,
        options: TransferOptions,
        generatedColumns: Set<String>,
        checkpoint: TransferCheckpointStore?,
        jobId: UUID,
        state: inout TransferWriterState
    ) async throws -> Int {
        try await TransferErrorClassifier.withRetry {
            var written = 0
            try await target.driver.beginTransaction(mode: .readWrite)
            do {
                written = try await writeChunkRows(
                    chunk,
                    plan: plan,
                    target: target,
                    limits: limits,
                    generatedColumns: generatedColumns,
                    state: &state
                )
                // The splitter can hold a partial batch when the chunk ends;
                // it must land inside this chunk's transaction or a crash
                // between the commit and the next chunk loses it silently.
                if let sink = state.sink, !state.pending.isEmpty {
                    written += try await flush(&state.pending, into: sink, columns: state.targetColumns)
                }
                if state.useBulk, let writer = state.bulkWriter {
                    written = try await writer.finish()
                    state.bulkWriter = nil
                }
                try await target.driver.commitTransaction()
            } catch {
                try? await target.driver.rollbackTransaction()
                await state.bulkWriter?.abort()
                state.bulkWriter = nil
                guard TransferErrorClassifier.classify(error) == .constraintViolation,
                      options.continueOnError else {
                    throw error
                }
                written = try await salvageChunk(
                    chunk,
                    plan: plan,
                    target: target,
                    limits: limits,
                    generatedColumns: generatedColumns,
                    state: &state
                )
            }
            // Only keyset chunks carry a cursor to resume from; a table without
            // a primary key records nothing until its final chunk marks it
            // complete, so a crash re-runs it instead of duplicating rows.
            if chunk.cursor != nil || chunk.isLast {
                await checkpoint?.record(
                    jobId: jobId,
                    mode: .emptyThenTransfer,
                    entry: TransferCheckpointStore.Entry(
                        table: plan.table,
                        partition: chunk.partition,
                        cursor: chunk.cursor ?? TransferChunkCursor.start,
                        isComplete: chunk.isLast
                    )
                )
            }
            return written
        }
    }

    private func writeBufferedChunk(
        _ chunk: TransferPipelineChunk,
        plan: TransferTablePlan,
        target: TransferDriverContext,
        limits: PluginServerLimits?,
        generatedColumns: Set<String>,
        state: inout TransferWriterState
    ) async throws -> Int {
        try await writeChunkRows(
            chunk,
            plan: plan,
            target: target,
            limits: limits,
            generatedColumns: generatedColumns,
            state: &state
        )
    }

    private func finishBufferedTable(
        plan: TransferTablePlan,
        target: TransferDriverContext,
        checkpoint: TransferCheckpointStore?,
        jobId: UUID,
        partition: Int,
        cursor: TransferChunkCursor?,
        state: inout TransferWriterState
    ) async throws -> Int {
        var written = 0
        if state.useBulk, let writer = state.bulkWriter {
            written = try await writer.finish()
            state.bulkWriter = nil
        } else if let sink = state.sink, !state.pending.isEmpty {
            written = try await flush(&state.pending, into: sink, columns: state.targetColumns)
        }
        if state.transactionOpen {
            try await target.driver.commitTransaction()
            state.transactionOpen = false
        }
        await checkpoint?.record(
            jobId: jobId,
            mode: .emptyThenTransfer,
            entry: TransferCheckpointStore.Entry(
                table: plan.table,
                partition: partition,
                cursor: cursor ?? TransferChunkCursor.start,
                isComplete: true
            )
        )
        return written
    }

    private func writeChunkRows(
        _ chunk: TransferPipelineChunk,
        plan: TransferTablePlan,
        target: TransferDriverContext,
        limits: PluginServerLimits?,
        generatedColumns: Set<String>,
        state: inout TransferWriterState
    ) async throws -> Int {
        if state.useBulk {
            if state.bulkWriter == nil {
                state.bulkWriter = try await target.bulkLoadWriter(table: plan.table, columns: state.bulkColumns)
            }
            // A driver that reports bulk load but hands back no writer would
            // otherwise drop the chunk and still mark the table complete.
            guard let writer = state.bulkWriter else {
                Self.logger.warning(
                    "No bulk writer for \(plan.table, privacy: .public), falling back to prepared batches"
                )
                try await usePreparedPath(
                    plan: plan,
                    target: target,
                    limits: limits,
                    headerColumns: chunk.headerColumns,
                    targetColumns: chunk.headerColumns.filter { !generatedColumns.contains($0) },
                    state: &state
                )
                return try await writeChunkRows(
                    chunk,
                    plan: plan,
                    target: target,
                    limits: limits,
                    generatedColumns: generatedColumns,
                    state: &state
                )
            }
            try await writer.write(rows: chunk.rows)
            return chunk.rows.count
        }
        guard let sink = state.sink, let currentSplitter = state.splitter else {
            throw TransferError.structureUnavailable(plan.table)
        }
        let result = try await appendRowsToPrepared(
            chunk.rows,
            headerColumns: chunk.headerColumns,
            generatedColumns: generatedColumns,
            converter: .identity,
            sink: sink,
            splitter: currentSplitter,
            targetColumns: state.targetColumns,
            pending: &state.pending
        )
        state.splitter = result.splitter
        return result.written
    }

    /// The failed batch's rows are probed one by one so the offending rows are
    /// dropped and logged instead of taking the whole chunk down.
    private func salvageChunk(
        _ chunk: TransferPipelineChunk,
        plan: TransferTablePlan,
        target: TransferDriverContext,
        limits: PluginServerLimits?,
        generatedColumns: Set<String>,
        state: inout TransferWriterState
    ) async throws -> Int {
        try await target.driver.beginTransaction(mode: .readWrite)
        var written = 0
        do {
            if state.useBulk {
                try await usePreparedPath(
                    plan: plan,
                    target: target,
                    limits: limits,
                    headerColumns: chunk.headerColumns,
                    targetColumns: chunk.headerColumns.filter { !generatedColumns.contains($0) },
                    state: &state
                )
            }
            guard let sink = state.sink else { throw TransferError.structureUnavailable(plan.table) }
            for row in chunk.rows {
                let dictionary = Self.rowDictionary(row, columns: chunk.headerColumns)
                do {
                    try await sink.insertRows([dictionary])
                    written += 1
                } catch {
                    let keys = plan.structure.primaryKeyColumns
                        .compactMap { dictionary[$0].flatMap(TransferChunkPlanner.keyText) }
                    Self.logger.warning(
                        "Dropped row \(keys.joined(separator: ","), privacy: .public) in \(plan.table, privacy: .public) chunk \(chunk.index, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            try await target.driver.commitTransaction()
            return written
        } catch {
            try? await target.driver.rollbackTransaction()
            throw error
        }
    }

    private func restoreWriter(target: TransferDriverContext, state: inout TransferWriterState) async throws {
        if state.transactionOpen {
            try await target.driver.commitTransaction()
            state.transactionOpen = false
        }
        switch state.foreignKeyScope {
        case .driver:
            try await target.setForeignKeyChecks(enabled: true)
        case .sink:
            try await state.sink?.enableForeignKeyChecks()
        case .none:
            break
        }
        state.foreignKeyScope = .none
    }

    private func abortWriter(target: TransferDriverContext, state: inout TransferWriterState) async {
        await state.bulkWriter?.abort()
        state.bulkWriter = nil
        if state.transactionOpen {
            try? await target.driver.rollbackTransaction()
            state.transactionOpen = false
        }
        switch state.foreignKeyScope {
        case .driver:
            try? await target.setForeignKeyChecks(enabled: true)
        case .sink:
            try? await state.sink?.enableForeignKeyChecks()
        case .none:
            break
        }
        state.foreignKeyScope = .none
    }

    // MARK: - Verify

    internal func verifyCounts(
        plans: [TransferTablePlan],
        source: TransferDriverContext,
        target: TransferDriverContext
    ) async -> [String: (source: Int, target: Int)] {
        var counts: [String: (source: Int, target: Int)] = [:]
        for plan in plans where plan.steps.contains(.transferRows) {
            if shouldStop { break }
            guard let sourceCount = try? await source.countRows(table: plan.table),
                  let targetCount = try? await target.countRows(table: plan.table) else { continue }
            counts[plan.table] = (sourceCount, targetCount)
        }
        return counts
    }

    private func appendRowsToPrepared(
        _ rows: [[PluginCellValue]],
        headerColumns: [String],
        generatedColumns: Set<String>,
        converter: TransferRowConverter,
        sink: ImportDataSinkAdapter,
        splitter: TransferBatchSplitter,
        targetColumns: [String],
        pending: inout [[PluginCellValue]]
    ) async throws -> (written: Int, splitter: TransferBatchSplitter) {
        var splitter = splitter
        var written = 0

        for rawRow in rows {
            let row = converter.isIdentity ? rawRow : try converter.convert(rawRow)
            let values = Self.orderedValues(
                row,
                headerColumns: headerColumns,
                generatedColumns: generatedColumns
            )
            let bytes = TransferBatchSplitter.estimatedBytes(for: values)
            let action = splitter.append(values, estimatedBytes: bytes)

            switch action {
            case .buffered:
                pending.append(values)
            case .flushBefore:
                written += try await flush(&pending, into: sink, columns: targetColumns)
                splitter.reset()
                _ = splitter.append(values, estimatedBytes: bytes)
                pending.append(values)
            case .sendAlone:
                if !pending.isEmpty {
                    written += try await flush(&pending, into: sink, columns: targetColumns)
                }
                splitter.reset()
                var single = [values]
                written += try await flush(&single, into: sink, columns: targetColumns)
            }
        }

        return (written, splitter)
    }

    static func orderedValues(
        _ row: [PluginCellValue],
        headerColumns: [String],
        generatedColumns: Set<String>
    ) -> [PluginCellValue] {
        guard row.count == headerColumns.count else { return row }
        var values: [PluginCellValue] = []
        values.reserveCapacity(headerColumns.count)
        for (column, value) in zip(headerColumns, row) where !generatedColumns.contains(column) {
            values.append(value)
        }
        return values
    }

    static func batchMaxBytes(from limits: PluginServerLimits?) -> Int {
        let ceiling = limits?.maxPacketBytes ?? TransferBatchSizing.defaultMaxBytes
        return max(1, ceiling - TransferBatchSizing.safetyMargin)
    }

    /// The run total and the current table's numerator move together, so the
    /// progress bar and the row count can never disagree about the same write.
    private func recordWrittenRows(_ count: Int) {
        guard count > 0 else { return }
        state.processedRows += count
        state.currentTableProcessedRows += count
    }

    private func flush(
        _ pending: inout [[PluginCellValue]],
        into sink: ImportDataSinkAdapter,
        columns: [String]
    ) async throws -> Int {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        try await sink.insertRows(columns: columns, rows: batch)
        return batch.count
    }

    private func makeSink(
        plan: TransferTablePlan,
        header: PluginStreamHeader,
        target: TransferDriverContext
    ) throws -> ImportDataSinkAdapter {
        let generated = plan.structure.generatedColumns
        let mapping = Self.identityColumnMapping(headerColumns: header.columns, generatedColumns: generated)
        try Self.validateColumnMapping(
            table: plan.table,
            headerColumns: header.columns,
            generatedColumns: generated,
            mapping: mapping
        )

        let generator = try SQLStatementGenerator(
            tableName: plan.table,
            columns: header.columns.filter { !generated.contains($0) },
            primaryKeyColumns: plan.structure.primaryKeyColumns,
            databaseType: target.databaseType,
            generatedColumns: generated,
            quoteIdentifier: target.driver.quoteIdentifier
        )

        return ImportDataSinkAdapter(
            driver: target.driver,
            databaseType: target.databaseType,
            targetTable: plan.table,
            columnMapping: mapping,
            rowGenerator: generator
        )
    }

    static func rowDictionary(_ row: PluginRow, columns: [String]) -> [String: PluginCellValue] {
        var values: [String: PluginCellValue] = [:]
        for (index, column) in columns.enumerated() where index < row.count {
            values[column] = row[index]
        }
        return values
    }

    /// Source and target share a table definition here, so every column maps
    /// onto itself. Server-computed columns are left out: they reject a
    /// written value.
    static func identityColumnMapping(
        headerColumns: [String],
        generatedColumns: Set<String>
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        for column in headerColumns where !generatedColumns.contains(column) {
            mapping[column] = column
        }
        return mapping
    }

    /// A sink with an empty mapping drops every row and reports success, so an
    /// incomplete mapping has to stop the run rather than write silence.
    static func validateColumnMapping(
        table: String,
        headerColumns: [String],
        generatedColumns: Set<String>,
        mapping: [String: String]
    ) throws {
        guard !mapping.isEmpty else { throw TransferError.emptyColumnMapping(table) }
        let expected = headerColumns.filter { !generatedColumns.contains($0) }
        guard mapping.count == Set(expected).count else {
            throw TransferError.columnMappingIncomplete(table)
        }
    }

    internal static let chunkSize = 10_000
    internal static let pipelineDepth = 4
    internal static let inTableParallelThreshold = 1_000_000
}

/// Which side turned the target's foreign key checks off, so the same side
/// turns them back on after a mid-table downgrade from bulk to prepared.
private enum TransferForeignKeyScope {
    case none
    case driver
    case sink
}

/// All mutable writer state for one table, held by the writer task.
private struct TransferWriterState {
    var sink: ImportDataSinkAdapter?
    var bulkWriter: (any PluginBulkLoadWriter)?
    var splitter: TransferBatchSplitter?
    var pending: [[PluginCellValue]] = []
    var targetColumns: [String] = []
    var useBulk = false
    var bulkColumns: [String] = []
    var transactionOpen = false
    var foreignKeyScope = TransferForeignKeyScope.none
}
