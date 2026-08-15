//
//  TransferGateFixtures.swift
//  TableProTests
//
//  Shared setup for the transfer gates that need a real server. Every gate is
//  skipped unless TRANSFER_GATES=1 is set, so the normal suite never needs a
//  database.
//
//  Expected fixtures, created by scripts/transfer-gate-fixtures.sh:
//    MySQL      ss_gate_src / ss_gate_dst on 127.0.0.1:33062 as root
//    PostgreSQL ss_gate_src / ss_gate_dst on 127.0.0.1:5432  as postgres
//
import Foundation
@testable import SchemaStudio
import TableProPluginKit

enum TransferGateError: Error, LocalizedError {
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let name): return "No driver for \(name)"
        }
    }
}

enum TransferGateFixtures {
    /// The scheme's test action runs with `shouldUseLaunchSchemeArgsEnv`, which
    /// replaces the environment xcodebuild was invoked with, so a `TRANSFER_GATES=1`
    /// or `TEST_RUNNER_TRANSFER_GATES=1` argument never reaches this process: the
    /// gates would skip while still reporting as passed. A marker file on disk
    /// is read the same way from every runner, so `scripts/transfer-gates.sh`
    /// touches it and the environment variable stays supported for anyone who
    /// sets it in their own scheme.
    static let markerPath = "/tmp/schemastudio-transfer-gates"

    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["TRANSFER_GATES"] == "1" { return true }
        return FileManager.default.fileExists(atPath: markerPath)
    }

    /// The phase marker for the chaos gate, carried in the same file so both
    /// processes agree without depending on the environment.
    static var chaosPhase: String {
        if let phase = ProcessInfo.processInfo.environment["TRANSFER_CHAOS_PHASE"], !phase.isEmpty {
            return phase
        }
        return (try? String(contentsOfFile: markerPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static let mysqlPassword = "root"
    static let postgresPassword = "postgres"

    /// The checkpoint job id is derived from the connection id, so a gate that
    /// resumes in a later process needs the same id in both. A freshly
    /// generated UUID would make the second process look for a checkpoint file
    /// that the first one never wrote.
    private static func stableId(_ suffix: String) -> UUID {
        UUID(uuidString: "5EA7E000-0000-4000-8000-00000000\(suffix)") ?? UUID()
    }

    static func mysqlConnection(database: String) -> DatabaseConnection {
        DatabaseConnection(
            id: stableId(database == "ss_gate_src" ? "0001" : "0002"),
            name: "gate-mysql-\(database)",
            host: "127.0.0.1",
            port: 33_062,
            database: database,
            username: "root",
            type: .mysql,
            safeModeLevel: .silent
        )
    }

    static func postgresConnection(database: String) -> DatabaseConnection {
        DatabaseConnection(
            id: stableId(database == "ss_gate_src" ? "0003" : "0004"),
            name: "gate-pg-\(database)",
            host: "127.0.0.1",
            port: 5_432,
            database: database,
            username: "postgres",
            type: .postgresql,
            safeModeLevel: .silent
        )
    }

    /// A second connection to the source, used by the snapshot gates to write
    /// into the source while a transfer is reading it. It carries its own id so
    /// it never collides with the connection the transfer holds.
    static func writerConnection(for connection: DatabaseConnection) -> DatabaseConnection {
        DatabaseConnection(
            id: stableId(connection.type == .mysql ? "0005" : "0006"),
            name: "gate-writer-\(connection.database)",
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            safeModeLevel: .silent
        )
    }

    /// The test host is the app bundle but nothing has run `AppDelegate`, so the
    /// bundled driver plugins have to be discovered before a connection can
    /// resolve one. Loading twice is harmless; the manager keeps its registry.
    @MainActor
    static func connect(_ connection: DatabaseConnection, password: String) async throws {
        PluginManager.shared.loadPlugins()
        PluginManager.shared.activateDriver(databaseTypeId: connection.type.pluginTypeId)
        try await DatabaseManager.shared.connectToSession(connection, passwordOverride: password)
    }

    static func endpoint(_ connection: DatabaseConnection, schema: String?) -> TransferEndpoint {
        TransferEndpoint(
            connectionId: connection.id,
            databaseType: connection.type,
            database: connection.database,
            schema: schema
        )
    }

    @MainActor
    static func rowCount(_ connection: DatabaseConnection, table: String) async throws -> Int {
        let result = try await execute("SELECT COUNT(*) AS c FROM \(table)", on: connection)
        guard let first = result.rows.first?.first, let text = first.asText else { return 0 }
        return Int(text) ?? 0
    }

    @MainActor
    @discardableResult
    static func execute(_ sql: String, on connection: DatabaseConnection) async throws -> QueryResult {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw TransferGateError.notConnected(connection.name)
        }
        return try await driver.execute(query: sql)
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
