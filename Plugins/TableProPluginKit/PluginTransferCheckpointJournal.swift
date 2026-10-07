import Foundation

public struct PluginTransferCheckpointManifest: Codable, Sendable, Hashable {
    public let sourceJobId: UUID
    public let tables: [PluginTransferCheckpointTableManifest]
    public init(sourceJobId: UUID, tables: [PluginTransferCheckpointTableManifest]) {
        self.sourceJobId = sourceJobId
        self.tables = tables
    }
}

public struct PluginTransferCheckpointTableManifest: Codable, Sendable, Hashable {
    public let table: String
    public let boundaries: [String]
    public init(table: String, boundaries: [String]) {
        self.table = table
        self.boundaries = boundaries
    }

    public var partitionCount: Int { boundaries.count + 1 }
}

public struct PluginTransferCheckpointEntry: Codable, Sendable, Hashable {
    public let table: String
    public let partition: Int
    public let lastKey: [String]?
    public let rowsDone: Int
    public let isComplete: Bool
    public init(table: String, partition: Int, lastKey: [String]?, rowsDone: Int, isComplete: Bool) {
        self.table = table
        self.partition = partition
        self.lastKey = lastKey
        self.rowsDone = rowsDone
        self.isComplete = isComplete
    }
}

public struct PluginTransferCheckpointState: Codable, Sendable, Hashable {
    public let manifest: PluginTransferCheckpointManifest
    public let entries: [PluginTransferCheckpointEntry]
    public init(manifest: PluginTransferCheckpointManifest, entries: [PluginTransferCheckpointEntry]) {
        self.manifest = manifest
        self.entries = entries
    }
}

public protocol PluginTransferCheckpointJournal: Sendable {
    func prepare(manifest: PluginTransferCheckpointManifest) async throws -> PluginTransferCheckpointManifest
    func load(jobId: UUID) async throws -> PluginTransferCheckpointState?
    func replace(jobId: UUID, entry: PluginTransferCheckpointEntry) async throws
    func clear(jobId: UUID) async throws
}

public enum PluginTransferCheckpointJournalDialect: Sendable { case mysql, postgresql, sqlite, mssql }

public final class PluginSQLTransferCheckpointJournal: PluginTransferCheckpointJournal, @unchecked Sendable {
    private let driver: any PluginDatabaseDriver
    private let dialect: PluginTransferCheckpointJournalDialect
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public init(driver: any PluginDatabaseDriver, dialect: PluginTransferCheckpointJournalDialect) {
        self.driver = driver
        self.dialect = dialect
    }

    public func prepare(manifest: PluginTransferCheckpointManifest) async throws -> PluginTransferCheckpointManifest {
        try await createTables()
        if let state = try await load(jobId: manifest.sourceJobId) { return state.manifest }
        try await query(
            "INSERT INTO __schema_studio_transfer_manifests (job_id, manifest_json) VALUES (?, ?)",
            [
                .text(manifest.sourceJobId.uuidString),
                .text(String(decoding: encoder.encode(manifest), as: UTF8.self))
            ]
        )
        return manifest
    }

    public func load(jobId: UUID) async throws -> PluginTransferCheckpointState? {
        let hasManifestTable = try await hasTable("__schema_studio_transfer_manifests")
        let hasEntriesTable = try await hasTable("__schema_studio_transfer_entries")
        if !hasManifestTable, !hasEntriesTable { return nil }
        guard hasManifestTable, hasEntriesTable else { throw JournalError.incompleteStorage }
        let manifestResult = try await query(
            "SELECT manifest_json FROM __schema_studio_transfer_manifests WHERE job_id = ?",
            [.text(jobId.uuidString)]
        )
        guard let text = manifestResult.rows.first?.first?.asText,
              let data = text.data(using: .utf8) else { return nil }
        let manifest = try decoder.decode(PluginTransferCheckpointManifest.self, from: data)
        let entries = try await query(
            "SELECT table_name, partition_index, last_key_json, rows_done, is_complete FROM __schema_studio_transfer_entries WHERE job_id = ?",
            [.text(jobId.uuidString)]
        )
        return try PluginTransferCheckpointState(manifest: manifest, entries: entries.rows.map(decode))
    }

    public func replace(jobId: UUID, entry: PluginTransferCheckpointEntry) async throws {
        try await query(
            "DELETE FROM __schema_studio_transfer_entries WHERE job_id = ? AND table_name = ? AND partition_index = ?",
            [.text(jobId.uuidString), .text(entry.table), .int(Int64(entry.partition))]
        )
        try await query(
            "INSERT INTO __schema_studio_transfer_entries (job_id, table_name, partition_index, last_key_json, rows_done, is_complete) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(jobId.uuidString),
                .text(entry.table),
                .int(Int64(entry.partition)),
                .text(String(decoding: encoder.encode(entry.lastKey), as: UTF8.self)),
                .int(Int64(entry.rowsDone)),
                .int(entry.isComplete ? 1 : 0)
            ]
        )
    }

    public func clear(jobId: UUID) async throws {
        try await createTables()
        try await query("DELETE FROM __schema_studio_transfer_entries WHERE job_id = ?", [.text(jobId.uuidString)])
        try await query("DELETE FROM __schema_studio_transfer_manifests WHERE job_id = ?", [.text(jobId.uuidString)])
    }

    private enum JournalError: LocalizedError {
        case incompleteStorage
        case invalidEntry

        var errorDescription: String? {
            switch self {
            case .incompleteStorage:
                String(localized: "Transfer checkpoint journal storage is incomplete.")
            case .invalidEntry:
                String(localized: "Transfer checkpoint journal contains an invalid entry.")
            }
        }
    }

    private func hasTable(_ name: String) async throws -> Bool {
        let statement: String
        switch dialect {
        case .mysql:
            statement = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '\(name)'"
        case .postgresql:
            statement = "SELECT COUNT(*) FROM pg_class WHERE oid = to_regclass('\(name)')"
        case .sqlite:
            statement = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(name)'"
        case .mssql:
            statement = "SELECT CASE WHEN OBJECT_ID(N'\(name)', N'U') IS NULL THEN 0 ELSE 1 END"
        }
        let result = try await driver.execute(query: statement)
        guard let value = result.rows.first?.first, let count = Int(value.textFallback) else {
            throw JournalError.incompleteStorage
        }
        return count > 0
    }

    private func createTables() async throws {
        let manifestName = "__schema_studio_transfer_manifests"
        let entryName = "__schema_studio_transfer_entries"
        let jsonType = dialect == .mssql ? "VARCHAR(MAX)" : "TEXT"
        let integerType = dialect == .mssql ? "INT" : "INTEGER"
        let manifestColumns = "job_id VARCHAR(36) NOT NULL PRIMARY KEY, manifest_json \(jsonType) NOT NULL"
        let entryColumns = "job_id VARCHAR(36) NOT NULL, table_name VARCHAR(512) NOT NULL, "
            + "partition_index \(integerType) NOT NULL, last_key_json \(jsonType) NOT NULL, "
            + "rows_done BIGINT NOT NULL, is_complete \(integerType) NOT NULL, "
            + "PRIMARY KEY (job_id, table_name, partition_index)"
        try await driver.execute(query: createTableStatement(name: manifestName, columns: manifestColumns))
        try await driver.execute(query: createTableStatement(name: entryName, columns: entryColumns))
    }

    private func createTableStatement(name: String, columns: String) -> String {
        if dialect == .mssql {
            return "IF OBJECT_ID(N'\(name)', N'U') IS NULL CREATE TABLE \(name) (\(columns))"
        }
        return "CREATE TABLE IF NOT EXISTS \(name) (\(columns))"
    }

    private func query(_ sql: String, _ parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        let statement = driver.parameterStyle == .dollar ? Self.numberedPostgreSQLParameters(sql) : sql
        return try await driver.executeParameterized(query: statement, parameters: parameters)
    }

    static func numberedPostgreSQLParameters(_ sql: String) -> String {
        var statement = ""
        var parameter = 0
        var quote: Character?
        var characters = sql.makeIterator()
        while let character = characters.next() {
            if let activeQuote = quote {
                statement.append(character)
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
                statement.append(character)
            } else if character == "?" {
                parameter += 1
                statement += "$\(parameter)"
            } else {
                statement.append(character)
            }
        }
        return statement
    }

    private func decode(_ row: [PluginCellValue]) throws -> PluginTransferCheckpointEntry {
        guard row.count == 5,
              let table = row[0].asText,
              let partition = Int(row[1].textFallback),
              let lastKeyJson = row[2].asText,
              let rowsDone = Int(row[3].textFallback),
              let isComplete = Int(row[4].textFallback) else {
            throw JournalError.invalidEntry
        }
        return try PluginTransferCheckpointEntry(
            table: table,
            partition: partition,
            lastKey: decoder.decode([String]?.self, from: Data(lastKeyJson.utf8)),
            rowsDone: rowsDone,
            isComplete: isComplete != 0
        )
    }
}
