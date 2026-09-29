import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Transfer modes without a journal", .serialized)
@MainActor
struct TransferNoJournalGateTests {
    private let source = TransferGateFixtures.postgresConnection(database: "ss_gate_src")
    private let target = DatabaseConnection(
        id: UUID(uuidString: "5EA7E000-0000-4000-8000-000000009103") ?? UUID(),
        name: "No journal transfer gate",
        host: "127.0.0.1",
        port: 5_432,
        database: "ss_gate_no_journal",
        username: "postgres",
        type: .postgresql,
        safeModeLevel: .silent
    )

    @Test("copy and single-transaction runs leave journal storage absent")
    func modesDoNotCreateJournal() async throws {
        guard TransferGateFixtures.enabled else { return }
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        let sourceEndpoint = TransferGateFixtures.endpoint(source, schema: "public")
        let targetEndpoint = TransferGateFixtures.endpoint(target, schema: "public")
        let service = DataTransferService()
        let selections = [TransferTableSelection(table: "gapped")]
        try #require(try await journalTableCount() == 0)
        var copyOptions = TransferOptions()
        copyOptions.useSingleTransaction = false

        let copy = try await service.transfer(
            selections: selections,
            source: sourceEndpoint,
            target: targetEndpoint,
            mode: .copy,
            options: copyOptions
        )
        #expect(copy.failedCount == 0)
        #expect(try await journalTableCount() == 0)

        let singleTransaction = try await service.transfer(
            selections: selections,
            source: sourceEndpoint,
            target: targetEndpoint,
            mode: .emptyThenTransfer,
            options: TransferOptions()
        )
        #expect(singleTransaction.failedCount == 0)
        #expect(try await journalTableCount() == 0)
        let sourceCount = try await TransferGateFixtures.rowCount(source, table: "public.gapped")
        let targetCount = try await TransferGateFixtures.rowCount(target, table: "public.gapped")
        #expect(sourceCount == targetCount)
    }

    private func journalTableCount() async throws -> Int {
        let result = try await TransferGateFixtures.execute(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' "
                + "AND table_name IN ('__schema_studio_transfer_manifests', '__schema_studio_transfer_entries')",
            on: target
        )
        return Int(result.rows.first?.first?.textFallback ?? "") ?? -1
    }
}
