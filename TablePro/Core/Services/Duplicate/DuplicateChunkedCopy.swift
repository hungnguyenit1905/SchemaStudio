//
//  DuplicateChunkedCopy.swift
//  TablePro
//

import Foundation

/// How many rows a running copy has committed. Held by reference because the answer is still
/// needed after the run throws: a cancel or a failure part way through a chunked copy leaves real
/// rows behind, and whether to keep or drop them is a question only the user can answer.
final class DuplicateCopyLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: Int64 = 0

    var copiedRows: Int64 {
        lock.withLock { rows }
    }

    func add(_ count: Int64) {
        lock.withLock { rows += count }
    }
}

/// Copies rows in batches that each commit, walking the key rather than paging with `OFFSET`,
/// which rereads every earlier row on each page and silently skips rows when another session
/// writes between pages.
struct DuplicateChunkedCopy: Sendable {
    struct Outcome: Sendable, Hashable {
        let copiedRows: Int64
        let batches: Int
        /// One representative statement plus a summary, not one entry per batch: five million rows
        /// at ten thousand a batch is five hundred statements for a single user action.
        let executedStatements: [String]
    }

    let spec: DuplicateChunkedCopySpec
    let driver: any DuplicateDriving
    let token: DuplicateCancellationToken
    let ledger: DuplicateCopyLedger
    let onBatch: @Sendable (Int64) -> Void

    init(
        spec: DuplicateChunkedCopySpec,
        driver: any DuplicateDriving,
        token: DuplicateCancellationToken = DuplicateCancellationToken(),
        ledger: DuplicateCopyLedger = DuplicateCopyLedger(),
        onBatch: @escaping @Sendable (Int64) -> Void = { _ in }
    ) {
        self.spec = spec
        self.driver = driver
        self.token = token
        self.ledger = ledger
        self.onBatch = onBatch
    }

    func run() async throws -> Outcome {
        let statement = DuplicateStatement(kind: .copyData, sql: "")
        var lastKey: String?
        var copied: Int64 = 0
        var batches = 0
        var firstStatement: String?

        while true {
            // Whether there is work left is asked first, so a copy that finished on the previous
            // batch reports success even if the user pressed Stop while it was landing.
            guard let size = batchSize(copied: copied) else { break }
            guard !token.isCancelled else { throw DuplicateError.cancelled }

            let sql = spec.batchSQL(after: lastKey, rows: size, quoting: driver.quoting)
            if firstStatement == nil { firstStatement = sql }
            let report = try await perform(statement, sql: sql, after: lastKey)
            guard report.count >= 1 else { break }

            // Counted before the cursor is checked: these rows are committed either way, and the
            // recovery prompt is only honest if it names all of them.
            copied += report.count
            batches += 1
            ledger.add(report.count)
            onBatch(copied)

            guard let key = report.key, report.count >= size else { break }
            lastKey = key
        }

        return Outcome(
            copiedRows: copied,
            batches: batches,
            executedStatements: statements(first: firstStatement, batches: batches, copied: copied)
        )
    }

    // MARK: - Batch sizing

    /// The last batch under a `LIMIT` is cut to whatever is left, so the copy stops on the exact
    /// row the user asked for instead of overshooting by up to a whole batch.
    private func batchSize(copied: Int64) -> Int64? {
        guard let limit = spec.limit else { return spec.batchSize }
        let remaining = limit - copied
        guard remaining > 0 else { return nil }
        return min(spec.batchSize, remaining)
    }

    // MARK: - Batch result

    /// A failed batch reports the statement that failed, the same way every other statement does.
    /// Without this the user sees the driver's message with no SQL to act on.
    private func perform(
        _ statement: DuplicateStatement,
        sql: String,
        after lastKey: String?
    ) async throws -> BatchReportValues {
        do {
            return try await report(for: try await driver.run(statement, sql: sql), after: lastKey)
        } catch let error as DuplicateError {
            throw error
        } catch {
            throw DuplicateError.statementFailed(sql: sql, serverMessage: error.localizedDescription)
        }
    }

    private func report(for rows: [[String?]], after lastKey: String?) async throws -> BatchReportValues {
        guard let followUp = spec.lastKeySQL(after: lastKey, quoting: driver.quoting) else {
            return Self.report(from: rows)
        }
        let statement = DuplicateStatement(kind: .copyData, sql: followUp)
        return Self.report(from: try await driver.run(statement, sql: followUp))
    }

    /// Both vendors answer with one row of `count, max(key)`. An empty answer means the batch
    /// wrote nothing, which is how the loop learns the source is exhausted.
    static func report(from rows: [[String?]]) -> BatchReportValues {
        guard let row = rows.first, row.count >= 2, let count = row[0].flatMap(Int64.init) else {
            return BatchReportValues(count: 0, key: nil)
        }
        return BatchReportValues(count: count, key: row[1])
    }

    struct BatchReportValues: Sendable, Hashable {
        let count: Int64
        let key: String?
    }

    private func statements(first: String?, batches: Int, copied: Int64) -> [String] {
        guard let first else { return [] }
        guard batches > 1 else { return [first] }
        return [
            first,
            String(
                format: String(localized: "-- Repeated for %1$d batches, %2$lld rows copied"),
                batches,
                copied
            )
        ]
    }
}
