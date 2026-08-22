//
//  DuplicateExecutorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("DuplicateExecutor")
struct DuplicateExecutorTests {
    private func plan(_ statements: [DuplicateStatement], copyMode: DuplicateCopyMode = .atomic) -> DuplicatePlan {
        DuplicatePlan(statements: statements, copyMode: copyMode)
    }

    // MARK: - Protocol routing

    /// The security rule of the whole feature: a statement embedding the user's filter must not
    /// reach the server through the protocol that accepts several statements at once.
    @Test("Filter-bearing statements take the extended path and nothing else does")
    func filterBearingStatementsTakeExtendedPath() async throws {
        let driver = DuplicateDrivingStub()
        let executor = DuplicateExecutor(driver: driver)
        _ = try await executor.run(plan([
            DuplicateStatement(kind: .validateRowFilter, sql: "EXPLAIN SELECT 1 WHERE x = 1"),
            DuplicateStatement(kind: .createTable, sql: "CREATE TABLE t2 (LIKE t1)"),
            DuplicateStatement(kind: .copyData, sql: "INSERT INTO t2 SELECT * FROM t1 WHERE x = 1"),
            DuplicateStatement(kind: .analyze, sql: "ANALYZE t2")
        ]))

        #expect(driver.calls == [
            .extended("EXPLAIN SELECT 1 WHERE x = 1"),
            .simple("CREATE TABLE t2 (LIKE t1)"),
            .extended("INSERT INTO t2 SELECT * FROM t1 WHERE x = 1"),
            .simple("ANALYZE t2")
        ])
    }

    // MARK: - Deferred statements

    @Test("Each harvested index becomes one drop before the copy and one replay after it")
    func deferredStatementsExpandPerHarvestedIndex() async throws {
        let driver = DuplicateDrivingStub()
        driver.rowsForQueryContaining["pg_get_indexdef"] = [
            ["public.idx_a", "CREATE INDEX idx_a ON public.t2 (a)"],
            ["public.idx_b", "CREATE INDEX idx_b ON public.t2 (b) WHERE source = 'orders'"]
        ]
        let executor = DuplicateExecutor(driver: driver)
        let outcome = try await executor.run(plan([
            DuplicateStatement(kind: .harvestIndexes, sql: "SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i"),
            DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes),
            DuplicateStatement(kind: .copyData, sql: "INSERT INTO t2 SELECT * FROM t1"),
            DuplicateStatement(kind: .replayIndex, deferred: .fromHarvestedIndexes)
        ]))

        #expect(outcome.executedStatements == [
            "SELECT pg_get_indexdef(i.indexrelid) FROM pg_index i",
            "DROP INDEX public.idx_a",
            "DROP INDEX public.idx_b",
            "INSERT INTO t2 SELECT * FROM t1",
            "CREATE INDEX idx_a ON public.t2 (a)",
            "CREATE INDEX idx_b ON public.t2 (b) WHERE source = 'orders'"
        ])
    }

    /// The harvested definition is replayed byte for byte. Anything that reformatted it could
    /// change a predicate literal, which is the failure the whole harvest design avoids.
    @Test("A replayed index keeps its predicate exactly as the server wrote it")
    func replayedIndexIsVerbatim() async throws {
        let definition = "CREATE UNIQUE INDEX idx ON public.t2 USING btree (lower(email)) WHERE source = 'orders'"
        let driver = DuplicateDrivingStub()
        driver.rowsForQueryContaining["pg_get_indexdef"] = [["public.idx", definition]]
        let executor = DuplicateExecutor(driver: driver)
        let outcome = try await executor.run(plan([
            DuplicateStatement(kind: .harvestIndexes, sql: "SELECT pg_get_indexdef(x) FROM pg_index"),
            DuplicateStatement(kind: .replayIndex, deferred: .fromHarvestedIndexes)
        ]))

        #expect(outcome.executedStatements.last == definition)
    }

    /// `regclass` already returns a qualified, quoted reference. Quoting it again would name a
    /// single index `"public.idx_a"`, which does not exist.
    @Test("A harvested reference is not quoted a second time")
    func harvestedReferenceIsUsedVerbatim() async throws {
        let driver = DuplicateDrivingStub()
        driver.rowsForQueryContaining["pg_get_indexdef"] = [["public.\"weird name\"", "CREATE INDEX x ON t (a)"]]
        let executor = DuplicateExecutor(driver: driver)
        let outcome = try await executor.run(plan([
            DuplicateStatement(kind: .harvestIndexes, sql: "SELECT pg_get_indexdef(x) FROM pg_index"),
            DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes)
        ]))

        #expect(outcome.executedStatements.last == "DROP INDEX public.\"weird name\"")
    }

    @Test("No harvested indexes means the deferred statements run nothing")
    func noHarvestedIndexesRunsNothing() async throws {
        let driver = DuplicateDrivingStub()
        let executor = DuplicateExecutor(driver: driver)
        let outcome = try await executor.run(plan([
            DuplicateStatement(kind: .harvestIndexes, sql: "SELECT pg_get_indexdef(x) FROM pg_index"),
            DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes),
            DuplicateStatement(kind: .replayIndex, deferred: .fromHarvestedIndexes)
        ]))

        #expect(outcome.executedStatements.count == 1)
    }

    @Test("A harvest row missing a column is skipped rather than producing a broken statement")
    func malformedHarvestRowIsSkipped() {
        let indexes = DuplicateIndexDialect.postgresql.harvestedIndexes(from: [
            ["public.idx_a", "CREATE INDEX idx_a ON t (a)"],
            ["public.idx_b", nil],
            [nil, "CREATE INDEX idx_c ON t (c)"],
            ["", ""]
        ])
        #expect(indexes.count == 1)
        #expect(indexes.first?.reference == "public.idx_a")
    }

    // MARK: - Severity

    /// Losing statistics after a long copy must not be treated the same as losing the copy.
    @Test("A best-effort failure becomes a warning and the run continues")
    func bestEffortFailureWarnsAndContinues() async throws {
        let driver = DuplicateDrivingStub()
        driver.errorForQueryContaining["ANALYZE"] = DuplicateStubError(message: "lock timeout")
        let executor = DuplicateExecutor(driver: driver)
        let outcome = try await executor.run(plan([
            DuplicateStatement(kind: .createTable, sql: "CREATE TABLE t2 (LIKE t1)"),
            DuplicateStatement(kind: .analyze, sql: "ANALYZE t2"),
            DuplicateStatement(kind: .addForeignKey, sql: "ALTER TABLE t2 ADD FOREIGN KEY (a) REFERENCES t3 (a)")
        ]))

        #expect(outcome.executedStatements.count == 2)
        #expect(outcome.executedStatements.last?.hasPrefix("ALTER TABLE") == true)
        #expect(outcome.warnings.count == 1)
        if case .bestEffortStepFailed(_, let message) = outcome.warnings.first {
            #expect(message.contains("lock timeout"))
        } else {
            Issue.record("expected a best-effort warning")
        }
    }

    @Test("A fatal failure stops the run and reports the statement verbatim")
    func fatalFailureStopsAndReportsStatement() async throws {
        let driver = DuplicateDrivingStub()
        driver.errorForQueryContaining["INSERT"] = DuplicateStubError(message: "disk full")
        let executor = DuplicateExecutor(driver: driver)

        await #expect(throws: DuplicateError.statementFailed(
            sql: "INSERT INTO t2 SELECT * FROM t1",
            serverMessage: "disk full"
        )) {
            _ = try await executor.run(plan([
                DuplicateStatement(kind: .createTable, sql: "CREATE TABLE t2 (LIKE t1)"),
                DuplicateStatement(kind: .copyData, sql: "INSERT INTO t2 SELECT * FROM t1"),
                DuplicateStatement(kind: .analyze, sql: "ANALYZE t2")
            ]))
        }
        #expect(!driver.executedSQL.contains("ANALYZE t2"))
    }

    // MARK: - Cancellation

    @Test("Cancelling stops before the next statement runs")
    func cancellationStopsTheRun() async throws {
        let driver = DuplicateDrivingStub()
        let token = DuplicateCancellationToken()
        token.cancel()
        let executor = DuplicateExecutor(driver: driver, token: token)

        await #expect(throws: DuplicateError.cancelled) {
            _ = try await executor.run(plan([
                DuplicateStatement(kind: .createTable, sql: "CREATE TABLE t2 (LIKE t1)")
            ]))
        }
        #expect(driver.executedSQL.isEmpty)
    }

    // MARK: - Progress

    /// The harvest is what reveals how many index statements there really are, so the total the UI
    /// is given grows partway through. A progress bar that trusts the first total would jump.
    @Test("The step total grows once the harvest reports how many indexes exist")
    func totalStepsGrowAfterHarvest() async throws {
        let driver = DuplicateDrivingStub()
        driver.rowsForQueryContaining["pg_get_indexdef"] = [
            ["public.idx_a", "CREATE INDEX idx_a ON t (a)"],
            ["public.idx_b", "CREATE INDEX idx_b ON t (b)"],
            ["public.idx_c", "CREATE INDEX idx_c ON t (c)"]
        ]
        let recorded = Mutex<[DuplicateProgress]>([])
        let executor = DuplicateExecutor(driver: driver) { progress in
            recorded.withLock { $0.append(progress) }
        }
        _ = try await executor.run(plan([
            DuplicateStatement(kind: .harvestIndexes, sql: "SELECT pg_get_indexdef(x) FROM pg_index"),
            DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes),
            DuplicateStatement(kind: .copyData, sql: "INSERT INTO t2 SELECT * FROM t1"),
            DuplicateStatement(kind: .replayIndex, deferred: .fromHarvestedIndexes)
        ]))

        let progress = recorded.withLock { $0 }
        #expect(progress.first?.totalSteps == 4)
        #expect(progress.last?.totalSteps == 8)
        #expect(progress.map(\.step) == Array(1 ... 8))
    }
}

/// Minimal lock box so a test can collect callbacks from a `@Sendable` closure.
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
