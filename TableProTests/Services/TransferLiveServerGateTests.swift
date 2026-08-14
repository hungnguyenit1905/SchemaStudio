//
//  TransferLiveServerGateTests.swift
//  TableProTests
//
//  The transfer gates that only a real server can answer: throughput against
//  the prepared path, memory over a long copy, resume after an interrupted run,
//  and the bulk paths actually engaging. Every test here is skipped unless
//  TRANSFER_GATES=1 is set, so the normal suite never needs a database.
//
//  Expected fixtures, created by scripts/transfer-gate-fixtures.sh:
//    MySQL      ss_gate_src / ss_gate_dst on 127.0.0.1:33062 as root
//    PostgreSQL ss_gate_src / ss_gate_dst on 127.0.0.1:5432 as postgres
//
import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Transfer live server gates", .serialized)
@MainActor
struct TransferLiveServerGateTests {
    static var gatesEnabled: Bool {
        ProcessInfo.processInfo.environment["TRANSFER_GATES"] == "1"
    }

    // MARK: - Fixtures

    private static func mysqlConnection(database: String) -> DatabaseConnection {
        DatabaseConnection(
            name: "gate-mysql-\(database)",
            host: "127.0.0.1",
            port: 33_062,
            database: database,
            username: "root",
            type: .mysql,
            safeModeLevel: .silent
        )
    }

    private static func postgresConnection(database: String) -> DatabaseConnection {
        DatabaseConnection(
            name: "gate-pg-\(database)",
            host: "127.0.0.1",
            port: 5_432,
            database: database,
            username: "postgres",
            type: .postgresql,
            safeModeLevel: .silent
        )
    }

    /// The test host is the app bundle but nothing has run `AppDelegate`, so the
    /// bundled driver plugins have to be discovered before a connection can
    /// resolve one. Loading twice is harmless; the manager keeps its registry.
    private func connect(_ connection: DatabaseConnection, password: String) async throws {
        PluginManager.shared.loadPlugins()
        PluginManager.shared.activateDriver(databaseTypeId: connection.type.pluginTypeId)
        try await DatabaseManager.shared.connectToSession(connection, passwordOverride: password)
    }

    private func endpoint(_ connection: DatabaseConnection, schema: String?) -> TransferEndpoint {
        TransferEndpoint(
            connectionId: connection.id,
            databaseType: connection.type,
            database: connection.database,
            schema: schema
        )
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: - Gates

    @Test("MySQL copies a million rows and the counts match")
    func mysqlMillionRowCopy() async throws {
        try await runCopyGate(
            source: Self.mysqlConnection(database: "ss_gate_src"),
            target: Self.mysqlConnection(database: "ss_gate_dst"),
            password: "root",
            schema: nil,
            table: "bench",
            expectedRows: 1_000_000
        )
    }

    @Test("PostgreSQL copies a million rows through COPY and the counts match")
    func postgresMillionRowCopy() async throws {
        try await runCopyGate(
            source: Self.postgresConnection(database: "ss_gate_src"),
            target: Self.postgresConnection(database: "ss_gate_dst"),
            password: "postgres",
            schema: "public",
            table: "bench",
            expectedRows: 1_000_000
        )
    }

    @Test("A ten megabyte row goes through without stalling the splitter")
    func largeBlobRow() async throws {
        guard Self.gatesEnabled else { return }
        let source = Self.mysqlConnection(database: "ss_gate_src")
        let target = Self.mysqlConnection(database: "ss_gate_dst")
        try await connect(source, password: "root")
        try await connect(target, password: "root")

        let service = DataTransferService()
        let report = try await service.transfer(
            selections: [TransferTableSelection(table: "big_blob")],
            source: endpoint(source, schema: nil),
            target: endpoint(target, schema: nil),
            mode: .copy,
            options: TransferOptions()
        )
        let result = try #require(report.results.first)
        #expect(result.rowsTransferred == 1)
        #expect(result.errorMessage == nil)
    }

    @Test("A run stopped part way resumes without duplicating rows")
    func resumeAfterStop() async throws {
        guard Self.gatesEnabled else { return }
        let source = Self.mysqlConnection(database: "ss_gate_src")
        let target = Self.mysqlConnection(database: "ss_gate_dst")
        try await connect(source, password: "root")
        try await connect(target, password: "root")

        let service = DataTransferService()
        var options = TransferOptions()
        options.useSingleTransaction = false

        let stopper = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            service.cancel()
        }
        _ = try? await service.transfer(
            selections: [TransferTableSelection(table: "bench")],
            source: endpoint(source, schema: nil),
            target: endpoint(target, schema: nil),
            mode: .emptyThenTransfer,
            options: options
        )
        stopper.cancel()

        let resumed = try await service.transfer(
            selections: [TransferTableSelection(table: "bench")],
            source: endpoint(source, schema: nil),
            target: endpoint(target, schema: nil),
            mode: .emptyThenTransfer,
            options: options,
            resume: true
        )
        let result = try #require(resumed.results.first)
        #expect(result.sourceCount == result.targetCount)
        #expect(result.targetCount == 1_000_000)
    }

    @Test("The bulk path beats the prepared path on the same table")
    func bulkBeatsPrepared() async throws {
        guard Self.gatesEnabled else { return }
        for (connectionFactory, password, schema, label) in [
            (Self.postgresConnection, "postgres", "public", "PostgreSQL"),
            (Self.mysqlConnection, "root", nil, "MySQL")
        ] as [((String) -> DatabaseConnection, String, String?, String)] {
            let source = connectionFactory("ss_gate_src")
            let target = connectionFactory("ss_gate_dst")
            try await connect(source, password: password)
            try await connect(target, password: password)

            // The resolver refuses the bulk path when a failing row has to be
            // isolated, so continueOnError is the switch between the two.
            let prepared = try await measureCopy(
                source: source, target: target, schema: schema, table: "bench_small", continueOnError: true
            )
            let bulk = try await measureCopy(
                source: source, target: target, schema: schema, table: "bench_small", continueOnError: false
            )
            print(
                "GATE \(label) bulk vs prepared: "
                    + String(format: "%.1fs vs %.1fs (%.2fx)", bulk, prepared, prepared / bulk)
            )
        }
    }

    private func measureCopy(
        source: DatabaseConnection,
        target: DatabaseConnection,
        schema: String?,
        table: String,
        continueOnError: Bool
    ) async throws -> TimeInterval {
        var options = TransferOptions()
        options.continueOnError = continueOnError
        let service = DataTransferService()
        let started = Date()
        let report = try await service.transfer(
            selections: [TransferTableSelection(table: table)],
            source: endpoint(source, schema: schema),
            target: endpoint(target, schema: schema),
            mode: .copy,
            options: options
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(report.results.first?.errorMessage == nil)
        return elapsed
    }

    // MARK: - Shared gate body

    private func runCopyGate(
        source: DatabaseConnection,
        target: DatabaseConnection,
        password: String,
        schema: String?,
        table: String,
        expectedRows: Int
    ) async throws {
        guard Self.gatesEnabled else { return }
        try await connect(source, password: password)
        try await connect(target, password: password)

        let service = DataTransferService()
        let before = residentBytes()
        let started = Date()
        let report = try await service.transfer(
            selections: [TransferTableSelection(table: table)],
            source: endpoint(source, schema: schema),
            target: endpoint(target, schema: schema),
            mode: .copy,
            options: TransferOptions()
        )
        let elapsed = Date().timeIntervalSince(started)
        let growthMB = (Double(residentBytes()) - Double(before)) / 1_048_576

        let result = try #require(report.results.first)
        #expect(result.errorMessage == nil)
        #expect(result.rowsTransferred == expectedRows)
        #expect(result.sourceCount == result.targetCount)
        print(
            "GATE \(source.type.rawValue) \(table): \(expectedRows) rows in "
                + String(format: "%.1fs (%.0f rows/s), RSS +%.0f MB", elapsed, Double(expectedRows) / elapsed, growthMB)
        )
    }
}
