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

/// A bulk load stream that keeps every row it was handed, so a test can assert
/// both the path taken and the rows that travelled it.
final class FakeBulkLoadWriter: PluginBulkLoadWriter, @unchecked Sendable {
    struct WriteRejected: Error {}

    private let onRows: @Sendable ([[PluginCellValue]]) -> Void
    private let failsWrites: Bool
    private let failsWritesAfterChunks: Int?
    private let failsFinish: Bool
    private(set) var chunkCount = 0
    private(set) var rowCount = 0
    private(set) var didFinish = false
    private(set) var didAbort = false

    init(
        failsWrites: Bool = false,
        failsWritesAfterChunks: Int? = nil,
        failsFinish: Bool = false,
        onRows: @escaping @Sendable ([[PluginCellValue]]) -> Void
    ) {
        self.failsWrites = failsWrites
        self.failsWritesAfterChunks = failsWritesAfterChunks
        self.failsFinish = failsFinish
        self.onRows = onRows
    }

    func write(row: [PluginCellValue]) async throws {
        try await write(rows: [row])
    }

    func write(rows: [[PluginCellValue]]) async throws {
        guard !failsWrites else { throw WriteRejected() }
        if let failsWritesAfterChunks, chunkCount >= failsWritesAfterChunks { throw WriteRejected() }
        chunkCount += 1
        rowCount += rows.count
        onRows(rows)
    }

    func finish() async throws -> Int {
        guard !failsFinish else { throw WriteRejected() }
        didFinish = true
        return rowCount
    }

    func abort() async {
        didAbort = true
    }
}

final class FakeGenerationDriver: GenerationDriver, @unchecked Sendable {
    struct Batch: Sendable {
        let table: GenerationTableReference
        let columns: [String]
        let rows: [[PluginCellValue]]
    }

    struct ForeignKeyRestoreFailed: Error {}
    struct TriggerRestoreFailed: Error {}

    struct TriggerCheckCall: Sendable, Equatable {
        let table: String
        let enabled: Bool
    }

    let blocksDestructiveOperations: Bool
    let blocksAllWrites: Bool
    var supportsTransactions = true
    var failsForeignKeyRestore = false
    var failsSequenceReset = false
    var canDisableForeignKeyChecks = true

    /// Whether this fake can honour a trigger disable/enable request at all.
    /// Off by default, which is what MySQL and SQLite report today.
    var supportsTriggerDisable = false
    var failsTriggerEnableFor: Set<String> = []
    private(set) var triggerCheckCalls: [TriggerCheckCall] = []

    var supportsBulkLoad = false
    var requiresLocalInfile = false

    /// A driver that claims bulk load and then hands back nothing, which is the
    /// case the writer has to downgrade out of rather than drop rows in.
    var handsBackBulkWriter = true
    var failsBulkWrites = false
    var failsBulkWritesAfterChunks: Int?
    var failsBulkFinish = false
    var supportsLocalInfile: Bool?
    /// What a driver that implements no limits reporting at all looks like: the
    /// engine has to fall back to a per-vendor default rather than assuming
    /// PostgreSQL's.
    var reportsNilLimits = false
    private(set) var bulkWriters: [FakeBulkLoadWriter] = []
    private(set) var bulkWriterRequests: [GenerationTableReference] = []

    var harvestMode: GenerationHarvestMode = .unsupported
    var preloadedValues: [ReferenceKey: [[PluginCellValue]]] = [:]
    var preloadedQueryValues: [SqlQuerySource: [PluginCellValue]] = [:]
    private(set) var queriesRun: [SqlQuerySource] = []
    var inboundForeignKeyTables: Set<String> = []
    var failInsertsFor: Set<String> = []
    /// 1-based count of every `insert` call attempted, successful or not, so a
    /// test can reject one specific batch in the middle of a run without
    /// rejecting every batch for the table the way `failInsertsFor` does.
    var failInsertsOnAttempt: Set<Int> = []
    private(set) var insertAttempts = 0

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

    init(blocksDestructiveOperations: Bool = false, blocksAllWrites: Bool = false) {
        self.blocksDestructiveOperations = blocksDestructiveOperations
        self.blocksAllWrites = blocksAllWrites
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
        guard !reportsNilLimits else { return nil }
        return PluginServerLimits(
            maxPacketBytes: 1_048_576,
            maxBindParameters: 900,
            supportsLocalInfile: supportsLocalInfile
        )
    }

    func bulkLoadWriter(
        table: GenerationTableReference,
        columns: [String]
    ) async throws -> (any PluginBulkLoadWriter)? {
        bulkWriterRequests.append(table)
        guard handsBackBulkWriter else { return nil }
        let writer = FakeBulkLoadWriter(
            failsWrites: failsBulkWrites,
            failsWritesAfterChunks: failsBulkWritesAfterChunks,
            failsFinish: failsBulkFinish
        ) { [weak self] rows in
            self?.batches.append(Batch(table: table, columns: columns, rows: rows))
        }
        bulkWriters.append(writer)
        return writer
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
        if enabled, failsForeignKeyRestore {
            throw ForeignKeyRestoreFailed()
        }
    }

    func setTriggerChecks(table: GenerationTableReference, enabled: Bool) async throws -> Bool {
        guard supportsTriggerDisable else { return false }
        triggerCheckCalls.append(TriggerCheckCall(table: table.table, enabled: enabled))
        if enabled, failsTriggerEnableFor.contains(table.table) {
            throw TriggerRestoreFailed()
        }
        return true
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
        insertAttempts += 1
        if failInsertsFor.contains(table.table) || failInsertsOnAttempt.contains(insertAttempts) {
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

    struct SequenceResetFailed: Error {}

    func resetSequence(
        table: GenerationTableReference,
        column: String,
        sequenceName: String?
    ) async throws {
        callOrder.append("resetSequence")
        guard !failsSequenceReset else { throw SequenceResetFailed() }
        sequenceResets.append(
            SequenceReset(table: table.table, column: column, sequenceName: sequenceName)
        )
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
    /// An engine whose checkpoints go nowhere shared, which is what every suite
    /// wants: one suite's interrupted run must never leave a resume point that
    /// another suite's identical plan picks up.
    static func engine(
        driver: any GenerationDriver,
        registry: GeneratorRegistry = .standard,
        truncator: GenerationStringTruncator = GenerationStringTruncator(unit: .unicodeScalars),
        databaseType: DatabaseType = .postgresql,
        maxBindParameters: Int? = nil,
        options: GenerationRunOptions = GenerationRunOptions()
    ) -> GenerationEngine {
        GenerationEngine(
            driver: driver,
            registry: registry,
            truncator: truncator,
            databaseType: databaseType,
            maxBindParameters: maxBindParameters,
            options: options,
            checkpoints: checkpointStore()
        )
    }

    /// A checkpoint store of its own per engine, so one suite's interrupted run
    /// never leaves a resume point that another suite's identical plan picks up.
    static func checkpointStore() -> GenerationCheckpointStore {
        GenerationCheckpointStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("generation-checkpoints-\(UUID().uuidString)", isDirectory: true)
        )
    }

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
