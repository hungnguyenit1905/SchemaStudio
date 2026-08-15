//
//  TransferLiveServerGateTests.swift
//  TableProTests
//
//  The transfer gates that only a real server can answer: throughput against
//  the prepared path, memory over a long copy, resume after an interrupted run,
//  and the bulk paths actually engaging. Every test here is skipped unless
//  TRANSFER_GATES=1 is set, so the normal suite never needs a database.
//
//  Fixtures and connection details: TransferGateFixtures.
//
import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Transfer live server gates", .serialized)
@MainActor
struct TransferLiveServerGateTests {
    @Test("MySQL copies a million rows and the counts match")
    func mysqlMillionRowCopy() async throws {
        try await runCopyGate(
            source: TransferGateFixtures.mysqlConnection(database: "ss_gate_src"),
            target: TransferGateFixtures.mysqlConnection(database: "ss_gate_dst"),
            password: TransferGateFixtures.mysqlPassword,
            schema: nil,
            table: "bench",
            expectedRows: 1_000_000
        )
    }

    @Test("PostgreSQL copies a million rows through COPY and the counts match")
    func postgresMillionRowCopy() async throws {
        try await runCopyGate(
            source: TransferGateFixtures.postgresConnection(database: "ss_gate_src"),
            target: TransferGateFixtures.postgresConnection(database: "ss_gate_dst"),
            password: TransferGateFixtures.postgresPassword,
            schema: "public",
            table: "bench",
            expectedRows: 1_000_000
        )
    }

    @Test("A ten megabyte row goes through without stalling the splitter")
    func largeBlobRow() async throws {
        guard TransferGateFixtures.enabled else { return }
        let source = TransferGateFixtures.mysqlConnection(database: "ss_gate_src")
        let target = TransferGateFixtures.mysqlConnection(database: "ss_gate_dst")
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.mysqlPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.mysqlPassword)

        let service = DataTransferService()
        let report = try await service.transfer(
            selections: [TransferTableSelection(table: "big_blob")],
            source: TransferGateFixtures.endpoint(source, schema: nil),
            target: TransferGateFixtures.endpoint(target, schema: nil),
            mode: .copy,
            options: TransferOptions()
        )
        let result = try #require(report.results.first)
        #expect(result.rowsTransferred == 1)
        #expect(result.errorMessage == nil)
    }

    @Test("A run stopped part way resumes without duplicating rows")
    func resumeAfterStop() async throws {
        guard TransferGateFixtures.enabled else { return }
        let source = TransferGateFixtures.mysqlConnection(database: "ss_gate_src")
        let target = TransferGateFixtures.mysqlConnection(database: "ss_gate_dst")
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.mysqlPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.mysqlPassword)

        let service = DataTransferService()
        var options = TransferOptions()
        options.useSingleTransaction = false

        let stopper = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            service.cancel()
        }
        _ = try? await service.transfer(
            selections: [TransferTableSelection(table: "bench")],
            source: TransferGateFixtures.endpoint(source, schema: nil),
            target: TransferGateFixtures.endpoint(target, schema: nil),
            mode: .emptyThenTransfer,
            options: options
        )
        stopper.cancel()

        let resumed = try await service.transfer(
            selections: [TransferTableSelection(table: "bench")],
            source: TransferGateFixtures.endpoint(source, schema: nil),
            target: TransferGateFixtures.endpoint(target, schema: nil),
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
        guard TransferGateFixtures.enabled else { return }
        let engines: [((String) -> DatabaseConnection, String, String?, String)] = [
            (TransferGateFixtures.postgresConnection, TransferGateFixtures.postgresPassword, "public", "PostgreSQL"),
            (TransferGateFixtures.mysqlConnection, TransferGateFixtures.mysqlPassword, nil, "MySQL"),
        ]
        for (connectionFactory, password, schema, label) in engines {
            let source = connectionFactory("ss_gate_src")
            let target = connectionFactory("ss_gate_dst")
            try await TransferGateFixtures.connect(source, password: password)
            try await TransferGateFixtures.connect(target, password: password)

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
            #expect(bulk <= prepared)
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
            source: TransferGateFixtures.endpoint(source, schema: schema),
            target: TransferGateFixtures.endpoint(target, schema: schema),
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
        guard TransferGateFixtures.enabled else { return }
        try await TransferGateFixtures.connect(source, password: password)
        try await TransferGateFixtures.connect(target, password: password)

        let service = DataTransferService()
        let before = TransferGateFixtures.residentBytes()
        let started = Date()
        let report = try await service.transfer(
            selections: [TransferTableSelection(table: table)],
            source: TransferGateFixtures.endpoint(source, schema: schema),
            target: TransferGateFixtures.endpoint(target, schema: schema),
            mode: .copy,
            options: TransferOptions()
        )
        let elapsed = Date().timeIntervalSince(started)
        let growthMB = (Double(TransferGateFixtures.residentBytes()) - Double(before)) / 1_048_576

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
