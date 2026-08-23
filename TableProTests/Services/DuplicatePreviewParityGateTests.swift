//
//  DuplicatePreviewParityGateTests.swift
//  TableProTests
//
//  The Preview SQL tab claims to show the script the run sends. This gate holds
//  it to that: every statement the preview spells out has to reach the server
//  byte for byte, and every block the preview labels as deferred has to expand
//  into the number of statements it said it would.
//
//  Skipped unless DUPLICATE_GATES=1 or the marker file exists.
//
import Foundation
@testable import SchemaStudio
import Testing

@Suite("Duplicate preview parity gates", .serialized)
@MainActor
struct DuplicatePreviewParityGateTests {
    private let schema = DuplicateGateFixtures.postgresSchema

    @Test("Every previewed statement reaches the server unchanged, in order")
    func previewMatchesTheExecutedScript() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = DuplicateGateFixtures.postgresConnection()
        try await DuplicateGateFixtures.connect(connection, password: DuplicateGateFixtures.postgresPassword)
        await DuplicateGateFixtures.dropTables(
            ["dup_gate_preview", "dup_gate_preview_copy"],
            on: connection,
            schema: schema
        )

        try await DuplicateGateFixtures.execute(
            """
            CREATE TABLE dup_gate_preview (
                id bigserial PRIMARY KEY,
                label text NOT NULL,
                amount numeric(12, 2) NOT NULL DEFAULT 0
            )
            """,
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "CREATE INDEX dup_gate_preview_label ON dup_gate_preview (label)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "CREATE INDEX dup_gate_preview_amount ON dup_gate_preview (amount)",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            "COMMENT ON TABLE dup_gate_preview IS 'Preview parity gate'",
            on: connection
        )
        try await DuplicateGateFixtures.execute(
            """
            INSERT INTO dup_gate_preview (label, amount)
            SELECT 'row ' || g, g FROM generate_series(1, 200) AS g
            """,
            on: connection
        )

        let request = DuplicateGateFixtures.request(
            schema: schema,
            source: "dup_gate_preview",
            target: "dup_gate_preview_copy"
        )
        let planned = try await DuplicateGateFixtures.plan(on: connection, schema: schema, request: request)
        let previewed = planned.plan.statements.compactMap { statement -> String? in
            guard statement.kind != .validateRowFilter, case .sql(let sql) = statement.body else { return nil }
            return sql
        }
        let deferredBlocks = planned.plan.statements.filter { statement in
            if case .deferred = statement.body { return true }
            return false
        }
        #expect(!deferredBlocks.isEmpty)

        let result = try await DuplicateGateFixtures.duplicate(
            on: connection,
            schema: schema,
            request: request
        )

        var remaining = result.executedStatements[...]
        for statement in previewed {
            guard let index = remaining.firstIndex(of: statement) else {
                Issue.record("The run never sent a previewed statement: \(statement)")
                return
            }
            remaining = remaining[remaining.index(after: index)...]
        }

        let expanded = result.executedStatements.count - previewed.count
        let indexCount = DuplicatePlanPreview.estimatedHarvestedIndexCount(planned.introspection.indexes)
        #expect(indexCount == 2)
        #expect(expanded == deferredBlocks.count * indexCount)

        await DuplicateGateFixtures.dropTables(
            ["dup_gate_preview", "dup_gate_preview_copy"],
            on: connection,
            schema: schema
        )
    }

    @Test("The rendered preview holds the same statements the plan carries")
    func renderedPreviewCoversThePlan() async throws {
        guard DuplicateGateFixtures.enabled else { return }
        let connection = DuplicateGateFixtures.postgresConnection()
        try await DuplicateGateFixtures.connect(connection, password: DuplicateGateFixtures.postgresPassword)
        await DuplicateGateFixtures.dropTables(["dup_gate_render"], on: connection, schema: schema)

        try await DuplicateGateFixtures.execute(
            "CREATE TABLE dup_gate_render (id bigserial PRIMARY KEY, note text)",
            on: connection
        )

        let request = DuplicateGateFixtures.request(
            schema: schema,
            source: "dup_gate_render",
            target: "dup_gate_render_copy"
        )
        let planned = try await DuplicateGateFixtures.plan(on: connection, schema: schema, request: request)
        let script = DuplicatePlanPreview.script(
            plan: planned.plan,
            harvestedIndexCount: DuplicatePlanPreview.estimatedHarvestedIndexCount(planned.introspection.indexes),
            quoting: planned.quoting
        )

        for statement in planned.plan.statements {
            guard case .sql(let sql) = statement.body else { continue }
            #expect(script.contains(sql))
        }

        await DuplicateGateFixtures.dropTables(["dup_gate_render"], on: connection, schema: schema)
    }
}
