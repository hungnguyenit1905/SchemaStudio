//
//  TransferSnapshotGateTests.swift
//  TableProTests
//
//  Proves what the report claims about consistency when several tables copy in
//  parallel. PostgreSQL exports one snapshot and every lane adopts it, so the
//  run reads a single point in time across the whole database. MySQL cannot
//  share a snapshot between connections without a server-wide write lock, which
//  the transfer deliberately does not take, so it reports the weaker level.
//
//  The discriminator is a write into the source *while* the transfer reads it.
//  Tables are copied in 10k-row chunks, so a table of 200k rows is read by 20
//  separate statements. Rows inserted after the first chunk carry ids above the
//  chunk cursor, so a later chunk would pick them up if the lane were not
//  pinned to a snapshot. The target count staying at exactly the pre-transfer
//  count is what proves the pin held.
//
import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Transfer snapshot gates", .serialized)
@MainActor
struct TransferSnapshotGateTests {
    private static let tables = ["snap_a", "snap_b"]
    private static let seededRows = 200_000
    private static let intrusionRows = 500

    @Test("PostgreSQL copies parallel tables from one shared snapshot")
    func postgresSharedSnapshot() async throws {
        guard TransferGateFixtures.enabled else { return }
        let report = try await runParallelCopyWithIntrusion(
            source: TransferGateFixtures.postgresConnection(database: "ss_gate_src"),
            target: TransferGateFixtures.postgresConnection(database: "ss_gate_dst"),
            password: TransferGateFixtures.postgresPassword,
            schema: "public"
        )

        #expect(report.consistency == .databaseWide)
        for result in report.results {
            // Rows inserted mid-run are outside the snapshot, so neither table
            // may carry them even though later chunks queried past their ids.
            #expect(result.targetCount == Self.seededRows)
            #expect(result.errorMessage == nil)
        }
    }

    @Test("MySQL copies parallel tables and reports per-table consistency only")
    func mysqlPerTableConsistency() async throws {
        guard TransferGateFixtures.enabled else { return }
        let report = try await runParallelCopyWithIntrusion(
            source: TransferGateFixtures.mysqlConnection(database: "ss_gate_src"),
            target: TransferGateFixtures.mysqlConnection(database: "ss_gate_dst"),
            password: TransferGateFixtures.mysqlPassword,
            schema: nil
        )

        // MySQL has no cross-connection snapshot, so the honest label is the
        // weaker one. The row counts are deliberately not asserted: a mid-run
        // insert may or may not land inside a lane's read, and that is exactly
        // what "per table only" is telling the user.
        #expect(report.consistency == .perTable)
        for result in report.results {
            #expect(result.errorMessage == nil)
            #expect((result.targetCount ?? 0) >= Self.seededRows)
        }
    }

    // MARK: - Shared gate body

    /// Copies both tables in parallel while a second connection inserts into
    /// both of them, then removes the inserted rows so the gate can run again.
    private func runParallelCopyWithIntrusion(
        source: DatabaseConnection,
        target: DatabaseConnection,
        password: String,
        schema: String?
    ) async throws -> TransferReport {
        try await TransferGateFixtures.connect(source, password: password)
        try await TransferGateFixtures.connect(target, password: password)
        let writer = TransferGateFixtures.writerConnection(for: source)
        try await TransferGateFixtures.connect(writer, password: password)

        try await resetIntrusion(on: writer)

        var options = TransferOptions()
        options.parallelTables = 2
        options.useSingleTransaction = false

        let service = DataTransferService()
        let intruder = Task { @MainActor in
            await self.waitForDataPhase(service)
            try? await self.insertIntrusionRows(on: writer)
        }
        defer { intruder.cancel() }

        let report = try await service.transfer(
            selections: Self.tables.map { TransferTableSelection(table: $0) },
            source: TransferGateFixtures.endpoint(source, schema: schema),
            target: TransferGateFixtures.endpoint(target, schema: schema),
            mode: .copy,
            options: options
        )
        _ = await intruder.result
        try await resetIntrusion(on: writer)

        #expect(report.results.count == Self.tables.count)
        print("GATE \(source.type.rawValue) parallel snapshot: consistency=\(report.consistency)")
        return report
    }

    /// The snapshot is exported before the first chunk is read, so any progress
    /// at all means the pin is already in place and a write now lands outside
    /// it. Waiting on progress rather than a fixed delay keeps the gate honest
    /// on a slow machine.
    private func waitForDataPhase(_ service: DataTransferService) async {
        for _ in 0 ..< 600 {
            if service.state.processedRows > 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func insertIntrusionRows(on writer: DatabaseConnection) async throws {
        for table in Self.tables {
            let values = (0 ..< Self.intrusionRows)
                .map { "('intruder-\($0)')" }
                .joined(separator: ",")
            try await TransferGateFixtures.execute(
                "INSERT INTO \(table) (tag) VALUES \(values)",
                on: writer
            )
        }
    }

    private func resetIntrusion(on writer: DatabaseConnection) async throws {
        for table in Self.tables {
            try await TransferGateFixtures.execute(
                "DELETE FROM \(table) WHERE tag LIKE 'intruder-%'",
                on: writer
            )
        }
    }
}
