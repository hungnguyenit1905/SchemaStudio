import Foundation
@testable import SchemaStudio
@testable import TableProPluginKit
import Testing

private enum JournalDriverError: LocalizedError {
    case missingTable
    case rejectedStatement

    var errorDescription: String? {
        switch self {
        case .missingTable: "ERROR: relation \"__schema_studio_transfer_manifests\" does not exist"
        case .rejectedStatement: "Journal statement rejected"
        }
    }
}

private final class JournalRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    struct Statement {
        let sql: String
        let parameters: [PluginCellValue]
    }

    let parameterStyle: ParameterStyle
    private(set) var statements: [Statement] = []
    private(set) var hasManifestTable = false
    private(set) var hasEntryTable = false
    private(set) var manifests: [String: String] = [:]
    private(set) var entries: [String: [PluginTransferCheckpointEntry]] = [:]
    var rejectCreate = false
    var rejectRead = false

    init(parameterStyle: ParameterStyle) {
        self.parameterStyle = parameterStyle
    }

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { true }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}

    func execute(query: String) async throws -> PluginQueryResult {
        statements.append(Statement(sql: query, parameters: []))
        let checksTable = query.hasPrefix("SELECT COUNT") || query.hasPrefix("SELECT CASE")
        if checksTable, rejectRead { throw JournalDriverError.rejectedStatement }
        if checksTable, query.contains("__schema_studio_transfer_manifests") {
            return result(rows: [[.int(hasManifestTable ? 1 : 0)]])
        }
        if checksTable, query.contains("__schema_studio_transfer_entries") {
            return result(rows: [[.int(hasEntryTable ? 1 : 0)]])
        }
        if rejectCreate { throw JournalDriverError.rejectedStatement }
        if query.contains("CREATE TABLE"), query.contains("__schema_studio_transfer_manifests") {
            hasManifestTable = true
        }
        if query.contains("CREATE TABLE"), query.contains("__schema_studio_transfer_entries") {
            hasEntryTable = true
        }
        return .empty
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        statements.append(Statement(sql: query, parameters: parameters))
        if rejectRead, query.hasPrefix("SELECT") { throw JournalDriverError.rejectedStatement }
        if query.contains("__schema_studio_transfer_manifests"), !hasManifestTable {
            throw JournalDriverError.missingTable
        }
        if query.contains("__schema_studio_transfer_entries"), !hasEntryTable {
            throw JournalDriverError.missingTable
        }
        let jobId = parameters.first?.asText ?? ""
        if query.hasPrefix("SELECT manifest_json") {
            let rows = manifests[jobId].map { [[PluginCellValue.text($0)]] } ?? []
            return result(rows: rows)
        }
        if query.hasPrefix("SELECT table_name") {
            let rows = (entries[jobId] ?? []).map { entry in
                [
                    PluginCellValue.text(entry.table),
                    .int(Int64(entry.partition)),
                    .text(String(
                        bytes: (try? JSONEncoder().encode(entry.lastKey)) ?? Data("null".utf8),
                        encoding: .utf8
                    ) ?? "null"),
                    .int(Int64(entry.rowsDone)),
                    .int(entry.isComplete ? 1 : 0)
                ]
            }
            return result(rows: rows)
        }
        if query.hasPrefix("INSERT INTO __schema_studio_transfer_manifests") {
            manifests[jobId] = parameters[1].asText
        }
        if query.hasPrefix("DELETE FROM __schema_studio_transfer_manifests") {
            manifests.removeValue(forKey: jobId)
        }
        if query.hasPrefix("DELETE FROM __schema_studio_transfer_entries") {
            guard parameters.count > 1 else {
                entries.removeValue(forKey: jobId)
                return .empty
            }
            entries[jobId]?.removeAll {
                $0.table == parameters[1].asText && $0.partition == Int(parameters[2].textFallback)
            }
        }
        if query.hasPrefix("INSERT INTO __schema_studio_transfer_entries") {
            let lastKey = try JSONDecoder().decode([String]?.self, from: Data((parameters[3].asText ?? "null").utf8))
            entries[jobId, default: []].append(PluginTransferCheckpointEntry(
                table: parameters[1].asText ?? "",
                partition: Int(parameters[2].textFallback) ?? 0,
                lastKey: lastKey,
                rowsDone: Int(parameters[4].textFallback) ?? 0,
                isComplete: parameters[5].textFallback == "1"
            ))
        }
        return .empty
    }

    private func result(rows: [[PluginCellValue]]) -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: rows, rowsAffected: 0, executionTime: 0)
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

@Suite("Transfer checkpoint journal")
@MainActor
struct TransferCheckpointJournalTests {
    private func manifest(jobId: UUID, table: String = "orders") -> PluginTransferCheckpointManifest {
        PluginTransferCheckpointManifest(
            sourceJobId: jobId,
            tables: [PluginTransferCheckpointTableManifest(table: table, boundaries: ["50"])]
        )
    }

    @Test("only per-chunk empty-then-transfer uses a target journal")
    func journalEligibility() {
        var chunked = TransferOptions()
        chunked.useSingleTransaction = false
        var singleTransaction = chunked
        singleTransaction.useSingleTransaction = true

        #expect(DataTransferService.shouldUseCheckpointJournal(mode: .emptyThenTransfer, options: chunked))
        #expect(!DataTransferService.shouldUseCheckpointJournal(mode: .emptyThenTransfer, options: singleTransaction))
        #expect(!DataTransferService.shouldUseCheckpointJournal(mode: .copy, options: chunked))
        #expect(!DataTransferService.shouldUseCheckpointJournal(mode: .copy, options: singleTransaction))
    }

    @Test("resume requires the same job and selected tables")
    func resumeManifestMatchesSelection() throws {
        let jobId = UUID()
        let state = PluginTransferCheckpointState(
            manifest: PluginTransferCheckpointManifest(sourceJobId: jobId, tables: [
                PluginTransferCheckpointTableManifest(table: "orders", boundaries: [])
            ]),
            entries: []
        )
        _ = try DataTransferService.validateResumeState(state, jobId: jobId, selectedTables: ["orders"])
        #expect(throws: TransferError.self) {
            _ = try DataTransferService.validateResumeState(state, jobId: UUID(), selectedTables: ["orders"])
        }
        #expect(throws: TransferError.self) {
            _ = try DataTransferService.validateResumeState(state, jobId: jobId, selectedTables: ["customers"])
        }
    }

    @Test("only a complete matching report clears the journal")
    func checkpointCleanup() {
        func result(_ outcome: TransferTableOutcome, sourceCount: Int = 10, targetCount: Int = 10)
            -> TransferTableResult {
            TransferTableResult(
                table: "orders", rowsTransferred: 10, duration: 0, outcome: outcome,
                sourceCount: sourceCount, targetCount: targetCount
            )
        }

        #expect(DataTransferService.shouldClearCheckpoint(after: TransferReport(
            results: [result(.succeeded)],
            wasCancelled: false
        )))
        #expect(!DataTransferService.shouldClearCheckpoint(after: TransferReport(
            results: [result(.succeeded)],
            wasCancelled: true
        )))
        #expect(!DataTransferService.shouldClearCheckpoint(after: TransferReport(
            results: [result(.failed("write"))],
            wasCancelled: false
        )))
        #expect(!DataTransferService.shouldClearCheckpoint(after: TransferReport(
            results: [result(.notRun)],
            wasCancelled: false
        )))
        #expect(!DataTransferService.shouldClearCheckpoint(after: TransferReport(results: [
            result(.succeeded, sourceCount: 10, targetCount: 9)
        ], wasCancelled: false)))
    }

    @Test("missing journal storage reads as no previous run without creating tables")
    func absentStorageIsReadOnly() async throws {
        let driver = JournalRecordingDriver(parameterStyle: .dollar)
        let journal = PluginSQLTransferCheckpointJournal(driver: driver, dialect: .postgresql)

        #expect(try await journal.load(jobId: UUID()) == nil)
        #expect(driver.statements.allSatisfy { !$0.sql.contains("CREATE TABLE") })
        #expect(!driver.hasManifestTable)
        #expect(!driver.hasEntryTable)
    }

    @Test("a transient read error is propagated")
    func readErrorPropagates() async throws {
        let driver = JournalRecordingDriver(parameterStyle: .dollar)
        driver.rejectRead = true
        let journal = PluginSQLTransferCheckpointJournal(driver: driver, dialect: .postgresql)

        await #expect(throws: JournalDriverError.self) {
            _ = try await journal.load(jobId: UUID())
        }
    }

    @Test("starting over creates storage and clears only the matching job", arguments: [
        PluginTransferCheckpointJournalDialect.mysql,
        .postgresql,
        .sqlite,
        .mssql
    ])
    func clearIsScopedToJob(dialect: PluginTransferCheckpointJournalDialect) async throws {
        let driver = JournalRecordingDriver(parameterStyle: dialect == .postgresql ? .dollar : .questionMark)
        let journal = PluginSQLTransferCheckpointJournal(driver: driver, dialect: dialect)
        let clearedJob = UUID()
        let retainedJob = UUID()
        let retainedManifest = manifest(jobId: retainedJob)
        let entry = PluginTransferCheckpointEntry(
            table: "orders", partition: 0, lastKey: ["25"], rowsDone: 25, isComplete: false
        )

        try await journal.clear(jobId: clearedJob)
        #expect(driver.hasManifestTable)
        #expect(driver.hasEntryTable)
        _ = try await journal.prepare(manifest: manifest(jobId: clearedJob))
        _ = try await journal.prepare(manifest: retainedManifest)
        try await journal.replace(jobId: clearedJob, entry: entry)
        try await journal.replace(jobId: retainedJob, entry: entry)
        try await journal.clear(jobId: clearedJob)

        #expect(try await journal.load(jobId: clearedJob) == nil)
        let retained = try #require(try await journal.load(jobId: retainedJob))
        #expect(retained.manifest == retainedManifest)
        #expect(retained.entries == [entry])
    }

    @Test("a failed storage setup prevents journal mutation")
    func createFailureStopsClear() async throws {
        let driver = JournalRecordingDriver(parameterStyle: .dollar)
        driver.rejectCreate = true
        let journal = PluginSQLTransferCheckpointJournal(driver: driver, dialect: .postgresql)

        await #expect(throws: JournalDriverError.self) {
            try await journal.clear(jobId: UUID())
        }
        #expect(driver.statements.count == 1)
        #expect(driver.statements.allSatisfy { !$0.sql.hasPrefix("DELETE") })
    }

    @Test("PostgreSQL journal statements number each bind argument")
    func postgresBindOrder() async throws {
        let driver = JournalRecordingDriver(parameterStyle: .dollar)
        let journal = PluginSQLTransferCheckpointJournal(driver: driver, dialect: .postgresql)
        let jobId = UUID()
        try await journal.clear(jobId: jobId)
        _ = try await journal.prepare(manifest: manifest(jobId: jobId))
        try await journal.replace(jobId: jobId, entry: PluginTransferCheckpointEntry(
            table: "orders", partition: 0, lastKey: ["10"], rowsDone: 10, isComplete: false
        ))

        let statements = driver.statements.filter { !$0.parameters.isEmpty }
        #expect(statements.contains { $0.parameters.count == 1 && $0.sql.contains("$1") })
        #expect(statements.contains { $0.parameters.count == 2 && $0.sql.contains("VALUES ($1, $2)") })
        #expect(statements
            .contains {
                $0.parameters.count == 3 && $0.sql.contains("job_id = $1 AND table_name = $2 AND partition_index = $3")
            })
        #expect(statements.contains { $0.parameters.count == 6 && $0.sql.contains("VALUES ($1, $2, $3, $4, $5, $6)") })
        #expect(statements.allSatisfy { !$0.sql.contains("?") })
    }

    @Test("PostgreSQL bind rendering preserves quoted question marks")
    func quotedQuestionMarks() {
        let sql = "SELECT '?', \"?\", ? FROM names WHERE label = 'it''s ?' AND id = ?"
        #expect(PluginSQLTransferCheckpointJournal.numberedPostgreSQLParameters(sql)
            == "SELECT '?', \"?\", $1 FROM names WHERE label = 'it''s ?' AND id = $2")
    }
}
