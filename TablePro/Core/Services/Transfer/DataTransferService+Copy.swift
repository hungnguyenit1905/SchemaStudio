//
//  DataTransferService+Copy.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// The chunked, pipelined row copy: a reader task streams bounded chunks of a
/// source table through a gated buffer into a writer task that batches them
/// into the target, commits per chunk when asked to, and records a checkpoint
/// after every commit so a crash resumes from the last chunk.
extension DataTransferService {
    // MARK: - Row Copy

    /// One chunked, pipelined table copy. The reader and the writer run as
    /// sibling tasks with a bounded buffer between them, so a slow target
    /// throttles the source instead of letting the reader pile rows into
    /// memory. Every chunk commits on its own (unless the user asked for a
    /// single transaction), and the checkpoint is written after each commit so
    /// a crash resumes from the last chunk instead of restarting the table.
    internal func copyRows(
        plan: TransferTablePlan,
        source: TransferDriverContext,
        target: TransferDriverContext,
        options: TransferOptions,
        limits: PluginServerLimits?,
        checkpoint: TransferCheckpointStore?,
        jobId: UUID,
        resumeCursor: TransferChunkCursor?,
        partition: Int = 0,
        upperBound: String? = nil
    ) async throws -> Int {
        let generatedColumns = plan.structure.generatedColumns
        let planner = TransferChunkPlanner(
            qualifiedTable: source.qualifiedTableRef(table: plan.table),
            primaryKeyColumns: plan.structure.primaryKeyColumns,
            chunkSize: Self.chunkSize,
            comparison: source.chunkComparison,
            quoteIdentifier: source.quoteIdentifier,
            escapeStringLiteral: source.escapeStringLiteral
        )

        let gate = TransferBackpressureGate(capacity: Self.pipelineDepth)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TransferPipelineEvent.self)

        return try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { @MainActor in
                do {
                    try await self.readChunks(
                        plan: plan,
                        planner: planner,
                        source: source,
                        resumeCursor: resumeCursor,
                        upperBound: upperBound,
                        partition: partition,
                        gate: gate,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                return 0
            }
            group.addTask { @MainActor in
                try await self.writeChunks(
                    plan: plan,
                    target: target,
                    limits: limits,
                    options: options,
                    checkpoint: checkpoint,
                    jobId: jobId,
                    partition: partition,
                    stream: stream,
                    gate: gate,
                    generatedColumns: generatedColumns
                )
            }

            var total = 0
            for try await written in group {
                total += written
            }
            return total
        }
    }

    // MARK: - Reader

    private func readChunks(
        plan: TransferTablePlan,
        planner: TransferChunkPlanner,
        source: TransferDriverContext,
        resumeCursor: TransferChunkCursor?,
        upperBound: String?,
        partition: Int,
        gate: TransferBackpressureGate,
        continuation: AsyncThrowingStream<TransferPipelineEvent, Error>.Continuation
    ) async throws {
        if planner.isSequential {
            try await readSequentialChunks(
                plan: plan,
                source: source,
                gate: gate,
                continuation: continuation,
                partition: partition
            )
            return
        }

        var cursor = resumeCursor
        var previousCursor = resumeCursor
        var chunkIndex = 0
        var headerColumns: [String] = []
        var headerSent = false
        var converter = TransferRowConverter.identity

        while true {
            if shouldStop { throw CancellationError() }
            let query = planner.chunkQuery(after: cursor, upperBound: upperBound)
            let stream = source.streamRows(query: query)
            var rows: [[PluginCellValue]] = []
            var lastHeader: PluginStreamHeader?

            for try await element in stream {
                if shouldStop { throw CancellationError() }
                switch element {
                case .header(let header):
                    lastHeader = header
                    if !headerSent {
                        headerSent = true
                        headerColumns = header.columns
                        converter = TransferRowConverter(
                            table: plan.table,
                            columns: header.columns,
                            conversions: plan.structure.conversions,
                            primaryKeyColumns: plan.structure.primaryKeyColumns
                        )
                        continuation.yield(.header(TransferPipelineHeader(columns: header.columns)))
                    }
                case .rows(let rawRows):
                    for rawRow in rawRows {
                        if converter.isIdentity {
                            rows.append(rawRow)
                        } else {
                            rows.append(try converter.convert(rawRow))
                        }
                    }
                }
            }

            let isLast = rows.count < planner.chunkSize
            let chunkCursor = planner.nextCursor(
                after: rows,
                headerColumns: lastHeader?.columns ?? headerColumns,
                previous: previousCursor
            )
            previousCursor = chunkCursor
            guard await gate.acquire() else { throw CancellationError() }
            continuation.yield(.chunk(TransferPipelineChunk(
                rows: rows,
                headerColumns: headerColumns,
                cursor: chunkCursor,
                isLast: isLast,
                index: chunkIndex,
                partition: partition
            )))
            chunkIndex += 1
            if isLast { return }
            guard let chunkCursor else {
                throw TransferError.chunkCursorUnavailable(plan.table)
            }
            cursor = chunkCursor
        }
    }

    /// A table without a primary key cannot be chunked, so it streams in one
    /// pass, still batched into bounded chunks for the writer. There is no
    /// cursor to resume from; the checkpoint records the table as complete
    /// only.
    private func readSequentialChunks(
        plan: TransferTablePlan,
        source: TransferDriverContext,
        gate: TransferBackpressureGate,
        continuation: AsyncThrowingStream<TransferPipelineEvent, Error>.Continuation,
        partition: Int
    ) async throws {
        let query = "SELECT * FROM \(source.qualifiedTableRef(table: plan.table))"
        let stream = source.streamRows(query: query)
        var rows: [[PluginCellValue]] = []
        var chunkIndex = 0
        var headerColumns: [String] = []
        var headerSent = false
        var converter = TransferRowConverter.identity

        for try await element in stream {
            if shouldStop { throw CancellationError() }
            switch element {
            case .header(let header):
                if !headerSent {
                    headerSent = true
                    headerColumns = header.columns
                    converter = TransferRowConverter(
                        table: plan.table,
                        columns: header.columns,
                        conversions: plan.structure.conversions,
                        primaryKeyColumns: plan.structure.primaryKeyColumns
                    )
                    continuation.yield(.header(TransferPipelineHeader(columns: header.columns)))
                }
            case .rows(let rawRows):
                for rawRow in rawRows {
                    if converter.isIdentity {
                        rows.append(rawRow)
                    } else {
                        rows.append(try converter.convert(rawRow))
                    }
                }
                while rows.count >= Self.chunkSize {
                    let batch = Array(rows.prefix(Self.chunkSize))
                    rows.removeFirst(Self.chunkSize)
                    try await yieldChunk(
                        batch,
                        headerColumns: headerColumns,
                        isLast: false,
                        cursor: nil,
                        chunkIndex: &chunkIndex,
                        partition: partition,
                        gate: gate,
                        continuation: continuation
                    )
                }
            }
        }
        if !rows.isEmpty {
            try await yieldChunk(
                rows,
                headerColumns: headerColumns,
                isLast: true,
                cursor: nil,
                chunkIndex: &chunkIndex,
                partition: partition,
                gate: gate,
                continuation: continuation
            )
        }
    }

    private func yieldChunk(
        _ rows: [[PluginCellValue]],
        headerColumns: [String],
        isLast: Bool,
        cursor: TransferChunkCursor?,
        chunkIndex: inout Int,
        partition: Int,
        gate: TransferBackpressureGate,
        continuation: AsyncThrowingStream<TransferPipelineEvent, Error>.Continuation
    ) async throws {
        guard await gate.acquire() else { throw CancellationError() }
        continuation.yield(.chunk(TransferPipelineChunk(
            rows: rows,
            headerColumns: headerColumns,
            cursor: cursor,
            isLast: isLast,
            index: chunkIndex,
            partition: partition
        )))
        chunkIndex += 1
    }
}
