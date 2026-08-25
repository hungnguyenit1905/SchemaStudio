//
//  DuplicateIndexFidelityGateTests.swift
//  TableProTests
//
//  Spec tests 4 and 5 against a real PostgreSQL. The harvest, drop and replay
//  around the copy is the newest mechanism in this feature, and a unit test can
//  only prove a fixture passes through it. Whether a partial predicate, an
//  expression index and a GIN opclass survive the round trip is a question only
//  the server answers.
//
//  Skipped unless DUPLICATE_GATES=1 or the marker file exists.
//
import Foundation
@testable import SchemaStudio
import Testing

@Suite("Duplicate index fidelity gates", .serialized)
@MainActor
struct DuplicateIndexFidelityGateTests {
    private let schema = DuplicateGateFixtures.postgresSchema

    @Test("Spec test 4: a partial, an expression and a GIN index all survive the copy")
    func threeIndexKindsSurvive() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = DuplicateGateFixtures.postgresConnection()
        try await DuplicateGateFixtures.connect(connection, password: DuplicateGateFixtures.postgresPassword)
        await DuplicateGateFixtures.dropTables(
            ["dup_gate_idx", "dup_gate_idx_copy"],
            on: connection,
            schema: schema
        )

        try await DuplicateGateFixtures.execute(
            """
            CREATE TABLE dup_gate_idx (
                id bigserial PRIMARY KEY,
                source text NOT NULL,
                email text NOT NULL,
                tags jsonb NOT NULL DEFAULT '{}'::jsonb
            )
            """,
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "CREATE INDEX dup_gate_idx_partial ON dup_gate_idx (id) WHERE source = 'orders'",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "CREATE INDEX dup_gate_idx_lower_email ON dup_gate_idx (lower(email))",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "CREATE INDEX dup_gate_idx_tags ON dup_gate_idx USING gin (tags jsonb_path_ops)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            """
            INSERT INTO dup_gate_idx (source, email, tags)
            SELECT CASE WHEN g % 2 = 0 THEN 'orders' ELSE 'invoices' END,
                   'User' || g || '@Example.com',
                   jsonb_build_object('n', g)
            FROM generate_series(1, 500) AS g
            """,
            on: connection
        )

        let result = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: DuplicateGateFixtures.request(
                schema: schema,
                source: "dup_gate_idx",
                target: "dup_gate_idx_copy"
            )
        )
        #expect(result.target.name == "dup_gate_idx_copy")

        let definitions = try await indexDefinitions("dup_gate_idx_copy", on: connection)
        #expect(definitions.count == 3)

        let partial = try #require(definitions.first { $0.contains("WHERE") })
        #expect(partial.contains("'orders'"))
        #expect(definitions.contains { $0.contains("lower(email)") })
        #expect(definitions.contains { $0.contains("USING gin") && $0.contains("jsonb_path_ops") })

        let copied = try await DuplicateGateFixtures.scalar(
            "SELECT COUNT(*) FROM dup_gate_idx_copy",
            on: connection
        )
        #expect(copied == "500")

        await DuplicateGateFixtures.dropTables(
            ["dup_gate_idx", "dup_gate_idx_copy"],
            on: connection,
            schema: schema
        )
    }

    @Test("Spec test 5: a table named order keeps every index name intact")
    func reservedTableNameKeepsIndexNames() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = DuplicateGateFixtures.postgresConnection()
        try await DuplicateGateFixtures.connect(connection, password: DuplicateGateFixtures.postgresPassword)
        await DuplicateGateFixtures.dropTables(["order", "order_copy"], on: connection, schema: schema)

        try await DuplicateGateFixtures.execute(
            """
            CREATE TABLE "order" (
                id bigserial PRIMARY KEY,
                orders_id bigint NOT NULL
            )
            """,
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "CREATE INDEX idx_order_orders_id ON \"order\" (orders_id)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "INSERT INTO \"order\" (orders_id) SELECT g FROM generate_series(1, 50) AS g",
            on: connection
        )

        _ = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: DuplicateGateFixtures.request(schema: schema, source: "order", target: "order_copy")
        )

        let names = try await indexNames("order_copy", on: connection)
        #expect(names.count == 2)
        // The server names the copy's indexes, so the assertion is that nothing is truncated or
        // mangled, not that a name matches the source's.
        #expect(names.allSatisfy { !$0.isEmpty && $0.allSatisfy { character in character != "\"" } })
        #expect(names.contains { $0.contains("orders_id") })

        let copied = try await DuplicateGateFixtures.scalar("SELECT COUNT(*) FROM order_copy", on: connection)
        #expect(copied == "50")

        await DuplicateGateFixtures.dropTables(["order", "order_copy"], on: connection, schema: schema)
    }

    // MARK: - Reads

    private func indexDefinitions(_ table: String, on connection: DatabaseConnection) async throws -> [String] {
        let rows = try await DuplicateGateFixtures.rows(
            """
            SELECT pg_get_indexdef(i.indexrelid)
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(schema)'
              AND c.relname = '\(table)'
              AND NOT i.indisprimary
            """,
            on: connection
        )
        return rows.compactMap { $0.first ?? nil }
    }

    private func indexNames(_ table: String, on connection: DatabaseConnection) async throws -> [String] {
        let rows = try await DuplicateGateFixtures.rows(
            """
            SELECT ic.relname
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_class ic ON ic.oid = i.indexrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = '\(schema)'
              AND c.relname = '\(table)'
            """,
            on: connection
        )
        return rows.compactMap { $0.first ?? nil }
    }
}
