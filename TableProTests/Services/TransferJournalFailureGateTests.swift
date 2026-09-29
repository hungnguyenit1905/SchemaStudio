import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Transfer journal failure gate", .serialized)
@MainActor
struct TransferJournalFailureGateTests {
    private let source = TransferGateFixtures.postgresConnection(database: "ss_gate_src")
    private let target = TransferGateFixtures.postgresConnection(database: "ss_gate_dst")
    private let table = "transfer_journal_failure_gate"

    @Test("a rejected journal entry rolls back its chunk rows")
    func failedJournalWriteRollsBackRows() async throws {
        guard TransferGateFixtures.enabled else { return }
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        let tableDefinition = "CREATE TABLE IF NOT EXISTS \(table) (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)"
        try await TransferGateFixtures.execute(tableDefinition, on: source)
        try await TransferGateFixtures.execute(tableDefinition, on: target)
        try await TransferGateFixtures.execute("TRUNCATE \(table)", on: source)
        try await TransferGateFixtures.execute("TRUNCATE \(table)", on: target)
        try await TransferGateFixtures.execute(
            "INSERT INTO \(table) (id, payload) VALUES (1, 'one')",
            on: source
        )
        try await TransferGateFixtures.execute(
            "CREATE TABLE IF NOT EXISTS __schema_studio_transfer_entries ("
                + "job_id VARCHAR(36) NOT NULL, table_name VARCHAR(512) NOT NULL, "
                + "partition_index INTEGER NOT NULL, last_key_json TEXT NOT NULL, "
                + "rows_done BIGINT NOT NULL, is_complete INTEGER NOT NULL, "
                + "PRIMARY KEY (job_id, table_name, partition_index))",
            on: target
        )
        try await TransferGateFixtures.execute(
            "CREATE OR REPLACE FUNCTION reject_transfer_journal_failure_gate() RETURNS trigger "
                + "LANGUAGE plpgsql AS $$ BEGIN IF NEW.table_name = '\(table)' THEN "
                + "RAISE EXCEPTION 'journal write rejected'; END IF; RETURN NEW; END $$",
            on: target
        )
        try await TransferGateFixtures.execute(
            "DROP TRIGGER IF EXISTS reject_transfer_journal_failure_gate ON __schema_studio_transfer_entries",
            on: target
        )
        try await TransferGateFixtures.execute(
            "CREATE TRIGGER reject_transfer_journal_failure_gate BEFORE INSERT "
                + "ON __schema_studio_transfer_entries FOR EACH ROW "
                + "EXECUTE FUNCTION reject_transfer_journal_failure_gate()",
            on: target
        )
        try await TransferGateFixtures.execute(
            "ALTER TABLE __schema_studio_transfer_entries ENABLE ALWAYS TRIGGER reject_transfer_journal_failure_gate",
            on: target
        )

        var options = TransferOptions()
        options.useSingleTransaction = false
        let report = try await DataTransferService().transfer(
            selections: [TransferTableSelection(table: table)],
            source: TransferGateFixtures.endpoint(source, schema: "public"),
            target: TransferGateFixtures.endpoint(target, schema: "public"),
            mode: .emptyThenTransfer,
            options: options
        )
        #expect(report.failedCount == 1)
        #expect(try await TransferGateFixtures.rowCount(target, table: table) == 0)

        let entries = try await TransferGateFixtures.execute(
            "SELECT COUNT(*) FROM __schema_studio_transfer_entries WHERE table_name = '\(table)'",
            on: target
        )
        #expect(entries.rows.first?.first?.textFallback == "0")
        try await TransferGateFixtures.execute(
            "DROP TRIGGER reject_transfer_journal_failure_gate ON __schema_studio_transfer_entries",
            on: target
        )
        try await TransferGateFixtures.execute(
            "DROP FUNCTION reject_transfer_journal_failure_gate()",
            on: target
        )
    }
}
