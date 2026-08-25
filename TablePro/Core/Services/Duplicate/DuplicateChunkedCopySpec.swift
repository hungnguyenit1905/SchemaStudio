//
//  DuplicateChunkedCopySpec.swift
//  TablePro
//

import Foundation

/// Everything needed to render one batch of a chunked copy, and nothing that needs a connection.
/// The builder produces it, the preview renders it and the runner executes it, so the SQL the
/// sheet shows and the SQL the server receives come from one place.
struct DuplicateChunkedCopySpec: Sendable, Hashable {
    /// How the last key of a batch comes back.
    ///
    /// PostgreSQL wraps the insert in a data-modifying CTE and reads `MAX` off `RETURNING`, so one
    /// statement copies the batch and reports where it ended. MySQL has no `RETURNING`, so the
    /// insert runs on its own and a second statement reads `MAX` over the range that insert just
    /// wrote. Neither reads `MAX` over the whole target: with a `LIMIT` the target already holds
    /// earlier batches, and a table-wide `MAX` would still be right only by accident.
    enum LastKeyStrategy: Sendable, Hashable {
        case insertReturning
        case selectMaxOverInsertedRange
    }

    let source: String
    let target: String
    let columnList: String
    let overriding: String
    let keyColumn: String
    let keyLiteralKind: TransferKeyLiteralKind
    let rowFilter: String?
    let batchSize: Int64
    let limit: Int64?
    let strategy: LastKeyStrategy

    /// The batch that copies the rows after `lastKey`. `rows` is the size of this batch, which is
    /// the configured batch size except for the last one under a `LIMIT`.
    func batchSQL(after lastKey: String?, rows: Int64, quoting: DuplicateSQLQuoting) -> String {
        let select = selectSQL(boundary: boundary(after: lastKey, quoting: quoting), rows: "\(rows)", quoting: quoting)
        let quotedKey = quoting.identifier(keyColumn)
        switch strategy {
        case .insertReturning:
            return """
            WITH source_batch AS (
            \(select)
            ), inserted AS (
                INSERT INTO \(target) (\(columnList))\(overriding)
                SELECT \(columnList) FROM source_batch
                RETURNING \(quotedKey)
            )
            SELECT count(*)::text, max(\(quotedKey))::text FROM inserted
            """
        case .selectMaxOverInsertedRange:
            return """
            INSERT INTO \(target) (\(columnList))\(overriding)
            \(select)
            """
        }
    }

    /// The follow-up read for a vendor whose insert reports nothing. Bounded to the rows this
    /// batch wrote by the same boundary predicate the batch used, applied to the target.
    func lastKeySQL(after lastKey: String?, quoting: DuplicateSQLQuoting) -> String? {
        guard strategy == .selectMaxOverInsertedRange else { return nil }
        let quotedKey = quoting.identifier(keyColumn)
        var sql = "SELECT count(*), max(\(quotedKey)) FROM \(target)"
        if let boundary = boundary(after: lastKey, quoting: quoting) {
            sql += " WHERE \(boundary)"
        }
        return sql
    }

    /// What the Preview SQL pane shows: one representative batch with the two values that change
    /// between batches left as placeholders, plus how many batches to expect.
    func previewScript(estimatedRowCount: Int64?, quoting: DuplicateSQLQuoting) -> String {
        let select = selectSQL(
            boundary: "\(quoting.identifier(keyColumn)) > :lastKey",
            rows: ":batchSize",
            quoting: quoting
        )
        let quotedKey = quoting.identifier(keyColumn)
        let body: String
        switch strategy {
        case .insertReturning:
            body = """
            WITH source_batch AS (
            \(select)
            ), inserted AS (
                INSERT INTO \(target) (\(columnList))\(overriding)
                SELECT \(columnList) FROM source_batch
                RETURNING \(quotedKey)
            )
            SELECT count(*)::text, max(\(quotedKey))::text FROM inserted;
            """
        case .selectMaxOverInsertedRange:
            body = """
            INSERT INTO \(target) (\(columnList))\(overriding)
            \(select);

            SELECT count(*), max(\(quotedKey)) FROM \(target) WHERE \(quotedKey) > :lastKey;
            """
        }
        return "\(previewHeader(estimatedRowCount: estimatedRowCount))\n\(body)"
    }

    func estimatedBatchCount(estimatedRowCount: Int64?) -> Int64? {
        guard let rows = totalRows(estimatedRowCount: estimatedRowCount), rows > 0 else { return nil }
        return (rows + batchSize - 1) / batchSize
    }

    /// A `LIMIT` caps the copy no matter how large the source is, so the smaller of the two is
    /// what the progress bar counts towards.
    func totalRows(estimatedRowCount: Int64?) -> Int64? {
        guard let limit else { return estimatedRowCount }
        guard let estimatedRowCount else { return limit }
        return min(limit, estimatedRowCount)
    }

    // MARK: - Rendering

    private func selectSQL(boundary: String?, rows: String, quoting: DuplicateSQLQuoting) -> String {
        var conditions: [String] = []
        if let rowFilter { conditions.append("(\(rowFilter))") }
        if let boundary { conditions.append(boundary) }
        var sql = "    SELECT \(columnList) FROM \(source)"
        if !conditions.isEmpty {
            sql += " WHERE \(conditions.joined(separator: " AND "))"
        }
        sql += " \(planner(quoting: quoting).orderByClause()) LIMIT \(rows)"
        return sql
    }

    private func previewHeader(estimatedRowCount: Int64?) -> String {
        guard let batches = estimatedBatchCount(estimatedRowCount: estimatedRowCount) else {
            return String(
                format: String(
                    localized: """
                    -- Repeated in batches of %lld rows until the source is exhausted, :lastKey \
                    advancing each time
                    """
                ),
                batchSize
            )
        }
        return String(
            format: String(
                localized: "-- Repeated about %1$lld times in batches of %2$lld rows, :lastKey advancing each time"
            ),
            batches,
            batchSize
        )
    }

    /// The keyset boundary comes from the Transfer planner rather than being spelled out again
    /// here, so both features order and compare a key the same way.
    private func boundary(after lastKey: String?, quoting: DuplicateSQLQuoting) -> String? {
        guard let lastKey else { return nil }
        return planner(quoting: quoting).boundaryPredicate(
            after: TransferChunkCursor(lastKey: [lastKey], rowsDone: 0)
        )
    }

    private func planner(quoting: DuplicateSQLQuoting) -> TransferChunkPlanner {
        TransferChunkPlanner(
            qualifiedTable: source,
            primaryKeyColumns: [keyColumn],
            chunkSize: Int(batchSize),
            comparison: .rowConstructor,
            quoteIdentifier: quoting.identifier,
            escapeStringLiteral: quoting.stringLiteral,
            keyLiteralKinds: [keyColumn: keyLiteralKind]
        )
    }
}
