import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("PostgreSQL transfer salvage gate", .serialized)
@MainActor
struct TransferPostgresSalvageGateTests {
    private let source = TransferGateFixtures.postgresConnection(database: "ss_gate_src")
    private let target = TransferGateFixtures.postgresConnection(database: "ss_gate_dst")
    private let table = "transfer_journal_salvage_gate"

    @Test("a rejected row is skipped and the accepted cursor survives resume")
    func rejectedRowPreservesAcceptedCursor() async throws {
        guard TransferGateFixtures.enabled else { return }
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        try await TransferGateFixtures.execute(
            "CREATE TABLE IF NOT EXISTS \(table) (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)",
            on: source
        )
        try await TransferGateFixtures.execute(
            "CREATE TABLE IF NOT EXISTS \(table) (id INTEGER PRIMARY KEY, payload TEXT NOT NULL, "
                + "CONSTRAINT reject_first_gate CHECK (id <> 1))",
            on: target
        )
        try await TransferGateFixtures.execute("TRUNCATE \(table)", on: source)
        try await TransferGateFixtures.execute("TRUNCATE \(table)", on: target)
        try await TransferGateFixtures.execute(
            "INSERT INTO \(table) (id, payload) VALUES (1, 'rejected'), (2, 'accepted')",
            on: source
        )

        let sourceEndpoint = TransferGateFixtures.endpoint(source, schema: "public")
        let targetEndpoint = TransferGateFixtures.endpoint(target, schema: "public")
        var options = TransferOptions()
        options.useSingleTransaction = false
        options.continueOnError = true
        let service = DataTransferService()
        let selections = [TransferTableSelection(table: table)]

        let first = try await service.transfer(
            selections: selections,
            source: sourceEndpoint,
            target: targetEndpoint,
            mode: .emptyThenTransfer,
            options: options
        )
        #expect(first.failedCount == 0)
        #expect(first.results.first?.errorMessage == nil)
        #expect(first.mismatchedCounts.count == 1)
        #expect(try await targetIds() == [2])

        let checkpoint = try #require(try await service.pendingResume(
            source: sourceEndpoint,
            target: targetEndpoint,
            mode: .emptyThenTransfer,
            options: options
        ))
        #expect(checkpoint.entry(table: table)?.cursor.lastKey == ["2"])

        let resumed = try await service.transfer(
            selections: selections,
            source: sourceEndpoint,
            target: targetEndpoint,
            mode: .emptyThenTransfer,
            options: options,
            resume: true
        )
        #expect(resumed.mismatchedCounts.count == 1)
        #expect(try await targetIds() == [2])
    }

    private func targetIds() async throws -> [Int] {
        let result = try await TransferGateFixtures.execute("SELECT id FROM \(table) ORDER BY id", on: target)
        return result.rows.compactMap { $0.first?.asText.flatMap(Int.init) }
    }
}
