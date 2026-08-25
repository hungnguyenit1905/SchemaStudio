//
//  DuplicateChunkedPlanTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The chunked path end to end: what the PostgreSQL builder emits, what the preview shows for it,
/// and what the service does when it fails after rows are already committed.
@Suite("Duplicate chunked plan")
struct DuplicateChunkedPlanTests {
    private let builder = PostgreSqlDuplicatePlanBuilder()

    private func table(rows: Int64?) -> DuplicateTableIntrospection {
        DuplicateTableIntrospection(
            columns: [
                DuplicateFixtures.column("id", "bigint", primaryKey: true),
                DuplicateFixtures.column("total", "numeric(10,2)")
            ],
            estimatedRowCount: rows
        )
    }

    private func plan(rows: Int64?, limit: Int64? = nil) -> DuplicatePlan {
        var options = DuplicateOptions()
        options.limit = limit
        return builder.plan(
            request: DuplicateFixtures.request(mode: .structureAndData, options: options),
            introspection: table(rows: rows),
            quoting: DuplicateFixtures.quoting
        )
    }

    private func copyBody(_ plan: DuplicatePlan) -> DuplicateStatement.Body? {
        plan.statements.first { $0.kind == .copyData }?.body
    }

    // MARK: - Builder

    @Test("An unknown row estimate produces a chunked copy statement")
    func unknownEstimateProducesChunkedBody() throws {
        let plan = plan(rows: nil)
        #expect(plan.copyMode == .chunked)
        guard case .chunked(let spec) = copyBody(plan) else {
            Issue.record("expected a chunked copy body")
            return
        }
        #expect(spec.keyColumn == "id")
        #expect(spec.strategy == .insertReturning)
        #expect(spec.batchSize == 10_000)
    }

    @Test("A small table keeps the single INSERT … SELECT")
    func smallTableStaysAtomic() throws {
        let plan = plan(rows: 42)
        #expect(plan.copyMode == .atomic)
        guard case .sql(let sql) = copyBody(plan) else {
            Issue.record("expected a plain SQL copy body")
            return
        }
        #expect(sql.hasPrefix("INSERT INTO \"public\".\"orders_copy\""))
    }

    /// Spec test 22: a hundred rows out of a million is a small copy however the source is sized.
    @Test("A small LIMIT on a huge table keeps the single statement")
    func smallLimitStaysAtomic() throws {
        let plan = plan(rows: 1_000_000, limit: 100)
        #expect(plan.copyMode == .atomic)
        guard case .sql(let sql) = copyBody(plan) else {
            Issue.record("expected a plain SQL copy body")
            return
        }
        #expect(sql.contains("LIMIT 100"))
    }

    @Test("The columns copied in chunked mode are the same explicit list as atomic mode")
    func chunkedListsColumnsExplicitly() throws {
        let introspection = DuplicateTableIntrospection(
            columns: [
                DuplicateFixtures.column("id", "bigint", primaryKey: true),
                DuplicateFixtures.column("price", "numeric(10,2)"),
                DuplicateFixtures.column("price_with_tax", "numeric(10,2)", generated: true)
            ]
        )
        let plan = builder.plan(
            request: DuplicateFixtures.request(mode: .structureAndData),
            introspection: introspection,
            quoting: DuplicateFixtures.quoting
        )
        guard case .chunked(let spec) = copyBody(plan) else {
            Issue.record("expected a chunked copy body")
            return
        }
        #expect(spec.columnList == "\"id\", \"price\"")
    }

    /// A filter makes the planner's estimate an answer to a different question, so the copy goes
    /// chunked and the filter has to reach every batch.
    @Test("A row filter picks chunked mode and reaches the batch")
    func rowFilterReachesTheChunkedBatch() throws {
        var options = DuplicateOptions()
        options.rowFilter = "status = 'paid'"
        let plan = builder.plan(
            request: DuplicateFixtures.request(mode: .structureAndData, options: options),
            introspection: table(rows: 42),
            quoting: DuplicateFixtures.quoting
        )
        #expect(plan.copyMode == .chunked)
        guard case .chunked(let spec) = copyBody(plan) else {
            Issue.record("expected a chunked copy body")
            return
        }
        #expect(spec.rowFilter == "status = 'paid'")
        #expect(spec.batchSQL(after: nil, rows: 10, quoting: DuplicateFixtures.quoting)
            .contains("WHERE (status = 'paid')"))
    }

    // MARK: - Preview

    @Test("The preview renders the DDL plus one representative batch")
    func previewRendersOneBatch() {
        let rendered = DuplicatePlanPreview.script(
            plan: plan(rows: 5_000_000),
            harvestedIndexCount: 0,
            quoting: DuplicateFixtures.quoting
        )
        #expect(rendered.contains("CREATE TABLE \"public\".\"orders_copy\""))
        #expect(rendered.contains(":lastKey"))
        #expect(rendered.contains("LIMIT :batchSize"))
        #expect(!rendered.uppercased().contains("OFFSET"))
    }

    // MARK: - Service recovery

    private func failingService(
        confirmDrop: @escaping @Sendable (Int64) async -> Bool
    ) -> (DuplicateTableService, DuplicateDrivingStub) {
        let driver = DuplicateDrivingStub()
        driver.columns = table(rows: nil).columns
        driver.rowsForQueryContaining["pg_sequences"] = [
            ["id", "orders_id_seq", "1", "1", "9223372036854775807", "1", "f"]
        ]
        driver.rowsForQueryContaining["obj_description"] = [[nil, "f", "t", "f"]]
        driver.rowsForQueryContaining["has_schema_privilege"] = [["t", "t"]]
        driver.respond = { sql in
            guard sql.contains("RETURNING") else { return nil }
            return [["10000", "10000"]]
        }
        // `setval` runs after the copy and is fatal, which is the shape that leaves committed
        // rows behind with no transaction to undo them.
        driver.errorForQueryContaining["setval"] = DuplicateStubError(message: "boom")
        var hooks = DuplicateServiceHooks()
        hooks.confirmDropPartialCopy = confirmDrop
        return (
            DuplicateTableService(
                databaseType: .postgresql,
                session: DuplicateSessionStub(driver: driver),
                hooks: hooks
            ),
            driver
        )
    }

    /// A chunked copy commits every batch, so a later failure has real rows to answer for. The
    /// user decides; the service does not delete them on its own.
    @Test("A chunked failure with committed rows asks before dropping and keeps the table on no")
    func chunkedFailureAsksAndKeeps() async throws {
        let asked = DuplicateAskRecorder()
        let (service, driver) = failingService(confirmDrop: { rows in
            asked.record(rows)
            return false
        })
        var options = DuplicateOptions()
        options.copyMode = .chunked
        options.limit = 10_000

        _ = try? await service.run(DuplicateFixtures.request(mode: .structureAndData, options: options))

        #expect(asked.rows == [10_000])
        #expect(!driver.executedSQL.contains { $0.hasPrefix("DROP TABLE") })
    }

    @Test("Answering yes drops the partly copied table")
    func chunkedFailureDropsOnYes() async throws {
        let (service, driver) = failingService(confirmDrop: { _ in true })
        var options = DuplicateOptions()
        options.copyMode = .chunked
        options.limit = 10_000

        _ = try? await service.run(DuplicateFixtures.request(mode: .structureAndData, options: options))

        #expect(driver.executedSQL.contains { $0.hasPrefix("DROP TABLE IF EXISTS") })
    }

    /// A chunked copy never opens a transaction: there is nothing a rollback could undo, and
    /// holding one open across hundreds of batches is the thing chunking exists to avoid.
    @Test("A chunked run never begins a transaction")
    func chunkedRunIsNotTransactional() async throws {
        let (service, driver) = failingService(confirmDrop: { _ in false })
        var options = DuplicateOptions()
        options.copyMode = .chunked
        options.limit = 10_000

        _ = try? await service.run(DuplicateFixtures.request(mode: .structureAndData, options: options))

        #expect(!driver.calls.contains(.begin))
        #expect(!driver.calls.contains(.rollback))
    }
}

final class DuplicateAskRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int64] = []

    var rows: [Int64] { lock.withLock { recorded } }

    func record(_ value: Int64) {
        lock.withLock { recorded.append(value) }
    }
}
