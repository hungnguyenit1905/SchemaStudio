//
//  TransferChaosGateTests.swift
//  TableProTests
//
//  The resume gate that `cancel()` cannot answer. Cancelling is cooperative and
//  unwinds cleanly; a SIGKILL does not, so only a killed process proves that the
//  checkpoint on disk is enough to finish the job in a later launch.
//
//  This runs as two phases in two processes, driven by
//  scripts/transfer-chaos-gate.sh:
//
//    TRANSFER_CHAOS_PHASE=run     starts the transfer and waits to be killed
//    TRANSFER_CHAOS_PHASE=verify  resumes it and checks the target
//
//  Neither phase does anything under a plain test run.
//
import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Transfer chaos gate", .serialized)
@MainActor
struct TransferChaosGateTests {
    private static let table = "bench"
    private static let expectedRows = 1_000_000
    private static let mode = TransferMode.emptyThenTransfer

    private static var phase: String {
        TransferGateFixtures.chaosPhase
    }

    private var source: DatabaseConnection {
        TransferGateFixtures.mysqlConnection(database: "ss_gate_src")
    }

    private var target: DatabaseConnection {
        TransferGateFixtures.mysqlConnection(database: "ss_gate_dst")
    }

    private var jobId: UUID {
        TransferCheckpointStore.jobId(
            source: TransferGateFixtures.endpoint(source, schema: nil),
            target: TransferGateFixtures.endpoint(target, schema: nil),
            mode: Self.mode
        )
    }

    @Test("Phase one: start a transfer and wait to be killed")
    func chaosRunPhase() async throws {
        guard TransferGateFixtures.enabled, Self.phase == "run" else { return }
        try await connectBoth()

        var options = TransferOptions()
        // Per-chunk commits are what leaves a resumable checkpoint behind. A
        // single transaction would be rolled back by the server when the killed
        // process drops its connection, leaving nothing to resume from.
        options.useSingleTransaction = false

        let service = DataTransferService()
        print("GATE chaos: starting transfer, job \(jobId.uuidString)")
        _ = try await service.transfer(
            selections: [TransferTableSelection(table: Self.table)],
            source: TransferGateFixtures.endpoint(source, schema: nil),
            target: TransferGateFixtures.endpoint(target, schema: nil),
            mode: Self.mode,
            options: options,
            resume: false
        )
        Issue.record("The transfer finished before the process was killed; lower the kill delay")
    }

    @Test("Phase two: resume from the checkpoint the killed process left")
    func chaosVerifyPhase() async throws {
        guard TransferGateFixtures.enabled, Self.phase == "verify" else { return }
        try await connectBoth()

        // Without this the gate would be vacuous: `resume: true` with no
        // checkpoint simply copies the table again from the start and the row
        // count would match for the wrong reason.
        let checkpoint = await TransferCheckpointStore.shared.load(jobId: jobId)
        #expect(!checkpoint.isEmpty, "The killed run left no checkpoint to resume from")
        let partial = try await TransferGateFixtures.rowCount(target, table: Self.table)
        #expect(partial > 0, "The killed run committed nothing")
        #expect(partial < Self.expectedRows, "The killed run had already finished")
        print("GATE chaos: resuming from \(partial) rows, \(checkpoint.count) checkpoint entries")

        var options = TransferOptions()
        options.useSingleTransaction = false

        let service = DataTransferService()
        let report = try await service.transfer(
            selections: [TransferTableSelection(table: Self.table)],
            source: TransferGateFixtures.endpoint(source, schema: nil),
            target: TransferGateFixtures.endpoint(target, schema: nil),
            mode: Self.mode,
            options: options,
            resume: true
        )

        let result = try #require(report.results.first)
        #expect(result.errorMessage == nil)

        let total = try await TransferGateFixtures.rowCount(target, table: Self.table)
        let distinct = try await distinctKeyCount()
        #expect(total == Self.expectedRows)
        #expect(distinct == Self.expectedRows, "Resume duplicated rows the killed run had already written")
        print("GATE chaos: resumed to \(total) rows, \(distinct) distinct ids")
    }

    private func connectBoth() async throws {
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.mysqlPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.mysqlPassword)
    }

    private func distinctKeyCount() async throws -> Int {
        let result = try await TransferGateFixtures.execute(
            "SELECT COUNT(DISTINCT id) AS c FROM \(Self.table)",
            on: target
        )
        guard let text = result.rows.first?.first?.asText else { return 0 }
        return Int(text) ?? 0
    }
}
