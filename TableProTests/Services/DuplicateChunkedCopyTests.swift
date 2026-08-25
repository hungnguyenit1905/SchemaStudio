//
//  DuplicateChunkedCopyTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DuplicateChunkedCopy")
struct DuplicateChunkedCopyTests {
    private let quoting = DuplicateFixtures.quoting

    private func spec(
        limit: Int64? = nil,
        batchSize: Int64 = 10_000,
        rowFilter: String? = nil,
        strategy: DuplicateChunkedCopySpec.LastKeyStrategy = .insertReturning,
        keyLiteralKind: TransferKeyLiteralKind = .numeric
    ) -> DuplicateChunkedCopySpec {
        DuplicateChunkedCopySpec(
            source: "\"public\".\"orders\"",
            target: "\"public\".\"orders_copy\"",
            columnList: "\"id\", \"total\"",
            overriding: "",
            keyColumn: "id",
            keyLiteralKind: keyLiteralKind,
            rowFilter: rowFilter,
            batchSize: batchSize,
            limit: limit,
            strategy: strategy
        )
    }

    /// Answers every batch with a full one, so the loop is driven by the sizes it asks for rather
    /// than by the source running out.
    private func fullBatches(_ recorded: RecordedBatches) -> @Sendable (String) -> [[String?]]? {
        { sql in
            guard let limit = RecordedBatches.limit(in: sql) else { return nil }
            recorded.record(sql: sql, rows: limit)
            return [["\(limit)", "\(recorded.lastKey)"]]
        }
    }

    final class RecordedBatches: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(sql: String, rows: Int64)] = []
        private var key: Int64 = 0

        var sizes: [Int64] { lock.withLock { recorded.map(\.rows) } }
        var statements: [String] { lock.withLock { recorded.map(\.sql) } }
        var lastKey: Int64 { lock.withLock { key } }

        func record(sql: String, rows: Int64) {
            lock.withLock {
                recorded.append((sql, rows))
                key += rows
            }
        }

        static func limit(in sql: String) -> Int64? {
            guard let range = sql.range(of: "LIMIT ", options: .backwards) else { return nil }
            let tail = sql[range.upperBound...].prefix { $0.isNumber }
            return Int64(tail)
        }
    }

    // MARK: - Keyset boundary

    /// `OFFSET` rescans every row it already read and skips rows when another session writes
    /// between pages. There must not be one anywhere in what this feature sends.
    @Test("No batch uses OFFSET")
    func noOffsetAnywhere() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        driver.respond = fullBatches(recorded)
        _ = try await DuplicateChunkedCopy(spec: spec(limit: 25_000), driver: driver).run()

        #expect(!recorded.statements.isEmpty)
        #expect(!recorded.statements.contains { $0.uppercased().contains("OFFSET") })
    }

    @Test("Each batch walks the key from where the previous one ended")
    func batchesWalkTheKey() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        driver.respond = fullBatches(recorded)
        _ = try await DuplicateChunkedCopy(spec: spec(limit: 25_000), driver: driver).run()

        #expect(!recorded.statements[0].contains("\"id\" >"))
        #expect(recorded.statements[1].contains("\"id\" > 10000"))
        #expect(recorded.statements[2].contains("\"id\" > 20000"))
        #expect(recorded.statements.allSatisfy { $0.contains("ORDER BY \"id\" ASC") })
    }

    /// A text key stays quoted: comparing `'123'` as a number against a column the server orders
    /// as text skips rows.
    @Test("A textual key is written as a quoted literal")
    func textualKeyIsQuoted() {
        let sql = spec(keyLiteralKind: .textual).batchSQL(after: "abc", rows: 10, quoting: quoting)
        #expect(sql.contains("\"id\" > 'abc'"))
    }

    // MARK: - LIMIT

    @Test("A LIMIT smaller than one batch copies exactly that many rows")
    func limitSmallerThanABatch() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        driver.respond = fullBatches(recorded)
        let outcome = try await DuplicateChunkedCopy(spec: spec(limit: 100), driver: driver).run()

        #expect(recorded.sizes == [100])
        #expect(outcome.copiedRows == 100)
    }

    @Test("A LIMIT across batches cuts the last one to what is left")
    func limitCutsTheLastBatch() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        driver.respond = fullBatches(recorded)
        let outcome = try await DuplicateChunkedCopy(spec: spec(limit: 25_000), driver: driver).run()

        #expect(recorded.sizes == [10_000, 10_000, 5_000])
        #expect(outcome.copiedRows == 25_000)
    }

    @Test("A short batch ends the copy: the source is exhausted")
    func shortBatchEndsTheCopy() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        driver.respond = { sql in
            guard let limit = RecordedBatches.limit(in: sql) else { return nil }
            let rows = recorded.statements.isEmpty ? limit : 42
            recorded.record(sql: sql, rows: rows)
            return [["\(rows)", "\(recorded.lastKey)"]]
        }
        let outcome = try await DuplicateChunkedCopy(spec: spec(), driver: driver).run()

        #expect(outcome.copiedRows == 10_042)
        #expect(outcome.batches == 2)
    }

    // MARK: - Cancel

    /// Stopping lands on a batch boundary, and what already committed is reported so the user can
    /// be asked whether to keep it.
    @Test("Cancel stops at a batch boundary and reports the committed rows")
    func cancelStopsAtBatchBoundary() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        let token = DuplicateCancellationToken()
        let ledger = DuplicateCopyLedger()
        driver.respond = { sql in
            guard let limit = RecordedBatches.limit(in: sql) else { return nil }
            recorded.record(sql: sql, rows: limit)
            token.cancel()
            return [["\(limit)", "\(recorded.lastKey)"]]
        }

        await #expect(throws: DuplicateError.cancelled) {
            _ = try await DuplicateChunkedCopy(
                spec: spec(),
                driver: driver,
                token: token,
                ledger: ledger
            ).run()
        }
        #expect(recorded.sizes == [10_000])
        #expect(ledger.copiedRows == 10_000)
    }

    /// A batch that lands and a Stop that arrives in the same moment is a finished copy, not a
    /// cancelled one.
    @Test("A copy that completed its last batch is not reported as cancelled")
    func cancelAfterTheFinalBatchStillSucceeds() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        let token = DuplicateCancellationToken()
        driver.respond = { sql in
            guard let limit = RecordedBatches.limit(in: sql) else { return nil }
            recorded.record(sql: sql, rows: limit)
            token.cancel()
            return [["\(limit)", "\(recorded.lastKey)"]]
        }
        let outcome = try await DuplicateChunkedCopy(
            spec: spec(limit: 10_000),
            driver: driver,
            token: token
        ).run()

        #expect(outcome.copiedRows == 10_000)
    }

    /// Rows that committed are counted even when the cursor cannot advance, or the keep-or-delete
    /// prompt would understate what is in the table.
    @Test("A batch with no usable cursor still counts the rows it committed")
    func rowsAreCountedWithoutACursor() async throws {
        let driver = DuplicateDrivingStub()
        let ledger = DuplicateCopyLedger()
        driver.respond = { sql in
            guard RecordedBatches.limit(in: sql) != nil else { return nil }
            return [["7", nil]]
        }
        let outcome = try await DuplicateChunkedCopy(spec: spec(), driver: driver, ledger: ledger).run()

        #expect(outcome.copiedRows == 7)
        #expect(ledger.copiedRows == 7)
    }

    // MARK: - Last key per vendor

    /// PostgreSQL reads the key off the insert itself, so a batch is one round trip.
    @Test("PostgreSQL takes the last key from the insert's own RETURNING")
    func postgresUsesReturning() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        driver.respond = { sql in
            guard RecordedBatches.limit(in: sql) != nil else { return nil }
            recorded.record(sql: sql, rows: 5)
            return [["5", "5"]]
        }
        _ = try await DuplicateChunkedCopy(spec: spec(), driver: driver).run()

        #expect(recorded.statements.count == 1)
        #expect(recorded.statements[0].contains("RETURNING \"id\""))
        #expect(recorded.statements[0].contains("SELECT count(*)::text, max(\"id\")::text FROM inserted"))
        #expect(driver.executedSQL.count == 1)
    }

    /// MySQL has no `RETURNING`, so the key comes from a second statement bounded to the range the
    /// insert just wrote. A `MAX` over the whole target would be wrong under a `LIMIT`, where the
    /// target already holds earlier batches.
    @Test("MySQL reads the last key over the range the batch just inserted")
    func mysqlReadsMaxOverInsertedRange() async throws {
        let driver = DuplicateDrivingStub()
        let answers = RecordedBatches()
        driver.respond = { sql in
            guard sql.hasPrefix("SELECT count(*)") else { return nil }
            answers.record(sql: sql, rows: 1)
            return answers.sizes.count == 1 ? [["10000", "10000"]] : [["0", nil]]
        }
        _ = try await DuplicateChunkedCopy(
            spec: spec(strategy: .selectMaxOverInsertedRange),
            driver: driver
        ).run()

        let follow = driver.executedSQL.filter { $0.hasPrefix("SELECT count(*)") }
        #expect(follow.count == 2)
        #expect(follow[0] == "SELECT count(*), max(\"id\") FROM \"public\".\"orders_copy\"")
        #expect(follow[1].contains("FROM \"public\".\"orders_copy\" WHERE \"id\" > 10000"))
        #expect(driver.executedSQL.contains { $0.hasPrefix("INSERT INTO \"public\".\"orders_copy\"") })
    }

    // MARK: - Row filter

    @Test("The row filter is ANDed with the boundary, not replaced by it")
    func rowFilterSurvivesTheBoundary() {
        let sql = spec(rowFilter: "status = 'paid'").batchSQL(after: "500", rows: 10, quoting: quoting)
        #expect(sql.contains("WHERE (status = 'paid') AND \"id\" > 500"))
    }

    /// Every batch embeds the filter the user typed, so it takes the protocol that refuses a
    /// second statement in one request.
    @Test("Batches take the extended path")
    func batchesTakeExtendedPath() async throws {
        let driver = DuplicateDrivingStub()
        driver.respond = { _ in [["1", "1"]] }
        _ = try await DuplicateChunkedCopy(spec: spec(limit: 1), driver: driver).run()

        #expect(driver.calls.allSatisfy { call in
            if case .extended = call { return true }
            return false
        })
    }

    // MARK: - History

    /// Five million rows at ten thousand a batch is five hundred statements. History gets one
    /// entry for the copy, not five hundred.
    @Test("A run of many batches reports one statement plus a summary")
    func historyGetsOneEntryPerCopy() async throws {
        let driver = DuplicateDrivingStub()
        let recorded = RecordedBatches()
        driver.respond = fullBatches(recorded)
        let outcome = try await DuplicateChunkedCopy(spec: spec(limit: 25_000), driver: driver).run()

        #expect(outcome.batches == 3)
        #expect(outcome.executedStatements.count == 2)
        #expect(outcome.executedStatements[1].hasPrefix("--"))
    }

    // MARK: - Preview

    @Test("The preview shows one batch with placeholders and how many batches to expect")
    func previewShowsPlaceholdersAndBatchCount() {
        let rendered = spec().previewScript(estimatedRowCount: 5_000_000, quoting: quoting)
        #expect(rendered.contains(":lastKey"))
        #expect(rendered.contains("LIMIT :batchSize"))
        #expect(rendered.contains("500"))
        #expect(!rendered.uppercased().contains("OFFSET"))
    }

    @Test("The preview says the batch count is unknown when the estimate is")
    func previewWithoutAnEstimate() {
        let rendered = spec().previewScript(estimatedRowCount: nil, quoting: quoting)
        #expect(rendered.contains(":lastKey"))
        #expect(!rendered.contains("about"))
    }

    @Test("A LIMIT caps the rows the progress counts towards")
    func totalRowsRespectsTheLimit() {
        #expect(spec(limit: 100).totalRows(estimatedRowCount: 5_000_000) == 100)
        #expect(spec().totalRows(estimatedRowCount: 5_000_000) == 5_000_000)
        #expect(spec(limit: 100).totalRows(estimatedRowCount: nil) == 100)
        #expect(spec().totalRows(estimatedRowCount: nil) == nil)
    }
}
