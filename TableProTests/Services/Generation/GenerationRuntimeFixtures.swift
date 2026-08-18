//
//  GenerationRuntimeFixtures.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit

enum GenerationHarvestMode: Sendable {
    /// What every bundled driver does today: no keys come back and the engine
    /// re-reads the parent instead.
    case unsupported
    case echoesInsertedColumns
}

final class FakeGenerationDriver: GenerationDriver, @unchecked Sendable {
    struct Batch: Sendable {
        let table: GenerationTableReference
        let columns: [String]
        let rows: [[PluginCellValue]]
    }

    let blocksDestructiveOperations: Bool
    let supportsTransactions = true

    var harvestMode: GenerationHarvestMode = .unsupported
    var preloadedValues: [ReferenceKey: [[PluginCellValue]]] = [:]
    var preloadedQueryValues: [SqlQuerySource: [PluginCellValue]] = [:]
    private(set) var queriesRun: [SqlQuerySource] = []
    var inboundForeignKeyTables: Set<String> = []
    var failInsertsFor: Set<String> = []

    /// Called with the number of batches written so far, which is how a test
    /// reaches in and cancels a run at a known point.
    var onInsert: (@Sendable (Int) async -> Void)?

    struct Update: Sendable {
        let table: GenerationTableReference
        let setColumns: [String]
        let keyColumns: [String]
        let assignments: [[PluginCellValue]]
    }

    struct SequenceReset: Sendable, Hashable {
        let table: String
        let column: String
        let sequenceName: String?
    }

    private(set) var batches: [Batch] = []
    private(set) var emptied: [(table: GenerationTableReference, allowsTruncate: Bool)] = []
    private(set) var foreignKeyCheckCalls: [Bool] = []
    private(set) var transactionCalls: [String] = []
    private(set) var updates: [Update] = []
    private(set) var sequenceResets: [SequenceReset] = []

    /// Every call in the order it arrived, which is how a test asserts that a
    /// sequence reset lands after the commit rather than inside the transaction.
    private(set) var callOrder: [String] = []

    init(blocksDestructiveOperations: Bool = false) {
        self.blocksDestructiveOperations = blocksDestructiveOperations
    }

    var insertedTableOrder: [String] {
        var seen: [String] = []
        for batch in batches where !seen.contains(batch.table.qualifiedName) {
            seen.append(batch.table.qualifiedName)
        }
        return seen
    }

    func rows(for table: String) -> [[PluginCellValue]] {
        batches.filter { $0.table.table == table }.flatMap(\.rows)
    }

    func columns(for table: String) -> [String] {
        batches.first { $0.table.table == table }?.columns ?? []
    }

    func serverLimits() async throws -> PluginServerLimits? {
        PluginServerLimits(maxPacketBytes: 1_048_576, maxBindParameters: 900)
    }

    func beginTransaction() async throws {
        transactionCalls.append("begin")
        callOrder.append("begin")
    }

    func commitTransaction() async throws {
        transactionCalls.append("commit")
        callOrder.append("commit")
    }

    func rollbackTransaction() async throws {
        transactionCalls.append("rollback")
        callOrder.append("rollback")
    }

    func setForeignKeyChecks(enabled: Bool) async throws {
        foreignKeyCheckCalls.append(enabled)
    }

    func hasInboundForeignKeys(table: GenerationTableReference) async throws -> Bool {
        inboundForeignKeyTables.contains(table.table)
    }

    func emptyTable(_ table: GenerationTableReference, allowsTruncate: Bool) async throws {
        emptied.append((table, allowsTruncate))
    }

    func insert(
        table: GenerationTableReference,
        columns: [String],
        rows: [[PluginCellValue]],
        harvestColumns: [String]
    ) async throws -> [[PluginCellValue]]? {
        if failInsertsFor.contains(table.table) {
            throw GenerationError.writeFailed(table: table.qualifiedName, reason: "rejected by the fake driver")
        }
        batches.append(Batch(table: table, columns: columns, rows: rows))
        callOrder.append("insert")
        await onInsert?(batches.count)
        guard !harvestColumns.isEmpty, harvestMode == .echoesInsertedColumns else { return nil }
        let positions = harvestColumns.compactMap { columns.firstIndex(of: $0) }
        guard positions.count == harvestColumns.count else { return nil }
        return rows.map { row in positions.map { row[$0] } }
    }

    func update(
        table: GenerationTableReference,
        setColumns: [String],
        keyColumns: [String],
        assignments: [[PluginCellValue]]
    ) async throws {
        updates.append(
            Update(table: table, setColumns: setColumns, keyColumns: keyColumns, assignments: assignments)
        )
    }

    func resetSequence(
        table: GenerationTableReference,
        column: String,
        sequenceName: String?
    ) async throws {
        sequenceResets.append(
            SequenceReset(table: table.table, column: column, sequenceName: sequenceName)
        )
        callOrder.append("resetSequence")
    }

    func loadQueryValues(source: SqlQuerySource, limit: Int) async throws -> [PluginCellValue] {
        queriesRun.append(source)
        return Array((preloadedQueryValues[source] ?? []).prefix(limit))
    }

    func loadDistinctValues(key: ReferenceKey, limit: Int) async throws -> [[PluginCellValue]] {
        if let preloaded = preloadedValues[key] { return Array(preloaded.prefix(limit)) }
        let matching = batches.filter { $0.table.table == key.table }
        guard let columns = matching.first?.columns else { return [] }
        let positions = key.columns.compactMap { columns.firstIndex(of: $0) }
        guard positions.count == key.columns.count else { return [] }
        var seen: Set<[String]> = []
        var tuples: [[PluginCellValue]] = []
        for row in matching.flatMap(\.rows) {
            let tuple = positions.map { row[$0] }
            guard seen.insert(tuple.map(\.textFallback)).inserted else { continue }
            tuples.append(tuple)
            if tuples.count >= limit { break }
        }
        return tuples
    }
}

enum GenerationRuntimeFixtures {
    static func plan(
        profile: GenerationProfile,
        schema: [GenerationTable],
        canDisableConstraints: Bool = false
    ) throws -> GenerationPlan {
        try GenerationPlanCompiler(canDisableConstraints: canDisableConstraints)
            .compile(profile: profile, schema: schema)
    }

    static func collect(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    static func report(in events: [GenerationEvent]) -> GenerationReport? {
        for event in events {
            if case .finished(let report) = event { return report }
        }
        return nil
    }

    static func cancelledRowCount(in events: [GenerationEvent]) -> Int? {
        for event in events {
            if case .cancelled(let rows) = event { return rows }
        }
        return nil
    }

    static func batchFailures(in events: [GenerationEvent]) -> [String] {
        events.compactMap { event in
            guard case .batchFailed(_, let error) = event else { return nil }
            return error
        }
    }

    static func integerColumn(
        _ name: String,
        nullable: Bool = false,
        primaryKey: Bool = false
    ) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: "bigint",
            isNullable: nullable,
            isPrimaryKey: primaryKey
        )
    }

    static func textColumn(_ name: String, length: Int = 64, nullable: Bool = false) -> PluginColumnInfo {
        PluginColumnInfo(name: name, dataType: "varchar(\(length))", isNullable: nullable)
    }

    static func columnProfile(
        _ column: String,
        generator: String,
        params: JSONValue = .object([:])
    ) -> GenerationColumnProfile {
        GenerationColumnProfile(column: column, generator: generator, params: params)
    }
}
