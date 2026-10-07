import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("PostgreSQL transfer first-run gate", .serialized)
@MainActor
struct TransferPostgresFirstRunGateTests {
    private let source = DatabaseConnection(
        id: UUID(uuidString: "5EA7E000-0000-4000-8000-000000009101") ?? UUID(),
        name: "VortexDev transfer gate",
        host: "127.0.0.1",
        port: 5_432,
        database: "vortex",
        username: "postgres",
        type: .postgresql,
        safeModeLevel: .silent
    )

    private let target = DatabaseConnection(
        id: UUID(uuidString: "5EA7E000-0000-4000-8000-000000009102") ?? UUID(),
        name: "PostgresLocal transfer gate",
        host: "127.0.0.1",
        port: 5_432,
        database: "dbg_dst",
        username: "postgres",
        type: .postgresql,
        safeModeLevel: .silent
    )

    @Test("copy preserves PostgreSQL function and typed null defaults")
    func copyPreservesDefaultExpressions() async throws {
        guard TransferGateFixtures.enabled else { return }
        let source = TransferGateFixtures.postgresConnection(database: "ss_gate_src")
        let target = TransferGateFixtures.postgresConnection(database: "ss_gate_dst")
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        let report = try await DataTransferService().transfer(
            selections: [TransferTableSelection(table: "transfer_default_expression_gate")],
            source: TransferGateFixtures.endpoint(source, schema: "public"),
            target: TransferGateFixtures.endpoint(target, schema: "public"),
            mode: .copy,
            options: TransferOptions()
        )

        let result = try #require(report.results.first)
        #expect(result.errorMessage == nil)
        #expect(result.rowsTransferred == 1)
        let defaults = try await TransferGateFixtures.execute(
            "SELECT column_name, column_default FROM information_schema.columns "
                + "WHERE table_schema = 'public' AND table_name = 'transfer_default_expression_gate'",
            on: target
        )
        let values = Dictionary(defaults.rows.compactMap { row -> (String, String)? in
            guard row.count >= 2 else { return nil }
            return (row[0].textFallback, row[1].textFallback)
        }, uniquingKeysWith: { first, _ in first })
        #expect(values["id"] == "gen_random_uuid()")
        #expect(values["code"]?.contains("gen_random_uuid()") == true)
        #expect(values["optional_label"] == "")
    }

    @Test("copy preserves a named PostgreSQL enum column")
    func copyPreservesNamedEnum() async throws {
        guard TransferGateFixtures.enabled else { return }
        let source = TransferGateFixtures.postgresConnection(database: "ss_gate_src")
        let target = TransferGateFixtures.postgresConnection(database: "ss_gate_dst")
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        let report = try await DataTransferService().transfer(
            selections: [TransferTableSelection(table: "transfer_enum_gate")],
            source: TransferGateFixtures.endpoint(source, schema: "public"),
            target: TransferGateFixtures.endpoint(target, schema: "public"),
            mode: .copy,
            options: TransferOptions()
        )

        let result = try #require(report.results.first)
        #expect(result.errorMessage == nil)
        #expect(result.rowsTransferred == 1)
        let copied = try await TransferGateFixtures.execute(
            "SELECT state::text FROM public.transfer_enum_gate WHERE id = 1",
            on: target
        )
        #expect(copied.rows.first?.first?.textFallback == "closed")
    }

    @Test("copy completes a table with no rows")
    func copyEmptyTable() async throws {
        guard TransferGateFixtures.enabled else { return }
        let source = TransferGateFixtures.postgresConnection(database: "ss_gate_src")
        let target = TransferGateFixtures.postgresConnection(database: "ss_gate_dst")
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        let report = try await DataTransferService().transfer(
            selections: [TransferTableSelection(table: "transfer_empty_gate")],
            source: TransferGateFixtures.endpoint(source, schema: "public"),
            target: TransferGateFixtures.endpoint(target, schema: "public"),
            mode: .copy,
            options: TransferOptions()
        )

        let result = try #require(report.results.first)
        #expect(report.failedCount == 0)
        #expect(result.errorMessage == nil)
        #expect(result.rowsTransferred == 0)
        #expect(result.sourceCount == 0)
        #expect(result.targetCount == 0)
    }

    @Test("copy preserves a PostgreSQL index operator class")
    func copyIndexOperatorClass() async throws {
        guard TransferGateFixtures.enabled else { return }
        let source = TransferGateFixtures.postgresConnection(database: "ss_gate_src")
        let target = TransferGateFixtures.postgresConnection(database: "ss_gate_dst")
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        let report = try await DataTransferService().transfer(
            selections: [TransferTableSelection(table: "transfer_index_gate")],
            source: TransferGateFixtures.endpoint(source, schema: "public"),
            target: TransferGateFixtures.endpoint(target, schema: "public"),
            mode: .copy,
            options: TransferOptions()
        )

        #expect(report.failedCount == 0)
        #expect(report.warningCount == 0)
        let indexes = try await TransferGateFixtures.execute(
            "SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' "
                + "AND indexname = 'transfer_index_gate_label_gin'",
            on: target
        )
        #expect(indexes.rows.first?.first?.textFallback.contains("gin_trgm_ops") == true)
    }

    @Test("first per-chunk transfer creates its journal and copies schema_migrations")
    func firstRunCopiesSelectedTable() async throws {
        guard TransferGateFixtures.enabled else { return }
        try await TransferGateFixtures.connect(source, password: TransferGateFixtures.postgresPassword)
        try await TransferGateFixtures.connect(target, password: TransferGateFixtures.postgresPassword)

        let targetTables = try await TransferGateFixtures.execute(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' "
                + "AND table_name IN ('schema_migrations', '__schema_studio_transfer_manifests', "
                + "'__schema_studio_transfer_entries')",
            on: target
        )
        try #require(targetTables.rows.first?.first?.textFallback == "0")

        var options = TransferOptions()
        options.createTargetIfNotExists = true
        options.useSingleTransaction = false

        let report = try await DataTransferService().transfer(
            selections: [TransferTableSelection(table: "schema_migrations")],
            source: TransferGateFixtures.endpoint(source, schema: "public"),
            target: TransferGateFixtures.endpoint(target, schema: "public"),
            mode: .emptyThenTransfer,
            options: options
        )

        let sourceCount = try await TransferGateFixtures.rowCount(source, table: "public.schema_migrations")
        let targetCount = try await TransferGateFixtures.rowCount(target, table: "public.schema_migrations")
        let result = try #require(report.results.first)
        #expect(report.failedCount == 0)
        #expect(report.warningCount == 0)
        #expect(!report.wasCancelled)
        #expect(result.errorMessage == nil)
        #expect(sourceCount > 0)
        #expect(targetCount == sourceCount)
        #expect(result.sourceCount == sourceCount)
        #expect(result.targetCount == targetCount)
    }
}
