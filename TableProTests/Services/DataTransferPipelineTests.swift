//
//  DataTransferPipelineTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// Streams a fixed number of rows for any query, in batches, so the reader
/// walks a table larger than the pipeline's buffer.
private final class StreamingSourceDriver: PluginDatabaseDriver, @unchecked Sendable {
    let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let total = rowCount
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["id", "name"], columnTypeNames: ["int", "text"])))
            var sent = 0
            while sent < total {
                let size = min(1_000, total - sent)
                let rows: [PluginRow] = (0 ..< size).map { offset in
                    [.text("\(sent + offset)"), .text("name")]
                }
                continuation.yield(.rows(rows))
                sent += size
            }
            continuation.finish()
        }
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

private final class CountingBulkLoadWriter: PluginBulkLoadWriter, @unchecked Sendable {
    private(set) var rows = 0
    private(set) var aborted = false

    func write(row: [PluginCellValue]) async throws {
        rows += 1
    }

    func finish() async throws -> Int { rows }

    func abort() async {
        aborted = true
    }
}

/// Counts the rows that actually reach the target, whichever path wrote them.
private final class CountingTargetDriver: PluginDatabaseDriver, @unchecked Sendable {
    enum BulkLoad {
        case unsupported
        case claimedButUnavailable
        case available
    }

    let bulkLoad: BulkLoad
    private(set) var preparedRows = 0
    private(set) var bulkWriters: [CountingBulkLoadWriter] = []

    init(bulkLoad: BulkLoad) {
        self.bulkLoad = bulkLoad
    }

    var bulkRows: Int { bulkWriters.reduce(0) { $0 + $1.rows } }
    var rowsWritten: Int { preparedRows + bulkRows }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var supportsBulkLoad: Bool { bulkLoad != .unsupported }

    func bulkLoadWriter(table: String, schema: String?, columns: [String]) async throws -> PluginBulkLoadWriter? {
        guard bulkLoad == .available else { return nil }
        let writer = CountingBulkLoadWriter()
        bulkWriters.append(writer)
        return writer
    }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        preparedRows += parameters.count / 2
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@MainActor
@Suite("DataTransfer chunked pipeline")
struct DataTransferPipelineTests {
    /// More rows than the reader may hold in flight, so the reader has to be
    /// handed permits back by the writer to finish the table.
    private static let rowsPastPipelineBuffer = DataTransferService.chunkSize * DataTransferService.pipelineDepth + 5_000

    private func context(
        driver: PluginDatabaseDriver,
        name: String,
        databaseType: DatabaseType
    ) -> TransferDriverContext {
        let connection = DatabaseConnection(name: name, type: databaseType)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        let endpoint = TransferEndpoint(
            connectionId: connection.id,
            databaseType: databaseType,
            database: "shop",
            schema: nil
        )
        guard let context = TransferDriverContext(driver: adapter, endpoint: endpoint) else {
            fatalError("PluginDriverAdapter is always a valid transfer context")
        }
        return context
    }

    /// No primary key, so the reader streams the table in one pass and batches
    /// it into chunks. That is the shortest path through the same gate.
    private func plan() -> TransferTablePlan {
        let structure = TransferStructureBuilder.build(
            table: "orders",
            columns: [
                PluginColumnInfo(name: "id", dataType: "int", isNullable: false),
                PluginColumnInfo(name: "name", dataType: "varchar(64)")
            ],
            indexes: [],
            foreignKeys: [],
            targetSchema: nil
        )
        return TransferTablePlan(
            table: "orders",
            structure: structure,
            targetExists: true,
            steps: [.transferRows],
            extraTargetColumns: []
        )
    }

    private func copy(
        rows: Int,
        target targetDriver: CountingTargetDriver,
        options: TransferOptions = TransferOptions(),
        databaseType: DatabaseType = .postgresql,
        limits: PluginServerLimits? = nil
    ) async throws -> (written: Int, service: DataTransferService) {
        let service = DataTransferService()
        let written = try await service.copyRows(
            plan: plan(),
            source: context(
                driver: StreamingSourceDriver(rowCount: rows),
                name: "Source",
                databaseType: databaseType
            ),
            target: context(driver: targetDriver, name: "Target", databaseType: databaseType),
            options: options,
            limits: limits,
            checkpoint: nil,
            jobId: UUID(),
            resumeCursor: nil
        )
        return (written, service)
    }

    @Test(
        "a table larger than the pipeline buffer copies every row",
        .timeLimit(.minutes(1))
    )
    func tableLargerThanPipelineBufferCompletes() async throws {
        let target = CountingTargetDriver(bulkLoad: .unsupported)
        let result = try await copy(rows: Self.rowsPastPipelineBuffer, target: target)

        #expect(result.written == Self.rowsPastPipelineBuffer)
        #expect(target.rowsWritten == Self.rowsPastPipelineBuffer)
        #expect(result.service.state.processedRows == Self.rowsPastPipelineBuffer)
    }

    /// MySQL with `local_infile` on is the case that used to drop every row:
    /// the resolver picked the bulk path and the driver has no writer.
    @Test(
        "a target that reports bulk load but hands back no writer still writes every row",
        .timeLimit(.minutes(1))
    )
    func missingBulkWriterFallsBackToPreparedBatches() async throws {
        let target = CountingTargetDriver(bulkLoad: .claimedButUnavailable)
        let result = try await copy(
            rows: 12_000,
            target: target,
            databaseType: .mysql,
            limits: PluginServerLimits(maxPacketBytes: nil, maxBindParameters: nil, supportsLocalInfile: true)
        )

        #expect(result.written == 12_000)
        #expect(target.preparedRows == 12_000)
    }

    @Test("a target with no bulk load never takes the bulk path")
    func unsupportedBulkLoadUsesPreparedBatches() async throws {
        let target = CountingTargetDriver(bulkLoad: .unsupported)
        let result = try await copy(rows: 5_000, target: target)

        #expect(result.written == 5_000)
        #expect(target.bulkWriters.isEmpty)
    }

    @Test(
        "a bulk load reports its rows once, not once per chunk and again at the end",
        .timeLimit(.minutes(1))
    )
    func bulkLoadCountsEveryRowOnce() async throws {
        let target = CountingTargetDriver(bulkLoad: .available)
        let result = try await copy(rows: Self.rowsPastPipelineBuffer, target: target)

        #expect(result.written == Self.rowsPastPipelineBuffer)
        #expect(target.bulkRows == Self.rowsPastPipelineBuffer)
        #expect(result.service.state.processedRows == Self.rowsPastPipelineBuffer)
    }

    @Test(
        "a bulk load committing per chunk also counts every row once",
        .timeLimit(.minutes(1))
    )
    func bulkLoadPerChunkCountsEveryRowOnce() async throws {
        var options = TransferOptions()
        options.useSingleTransaction = false
        let target = CountingTargetDriver(bulkLoad: .available)
        let result = try await copy(rows: 25_000, target: target, options: options)

        #expect(result.written == 25_000)
        #expect(target.bulkRows == 25_000)
    }
}
