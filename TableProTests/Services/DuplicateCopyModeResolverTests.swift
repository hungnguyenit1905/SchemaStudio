//
//  DuplicateCopyModeResolverTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DuplicateCopyModeResolver")
struct DuplicateCopyModeResolverTests {
    private func table(
        rows: Int64?,
        columns: [PluginColumnInfo] = [DuplicateFixtures.column("id", "bigint", primaryKey: true)]
    ) -> DuplicateTableIntrospection {
        DuplicateTableIntrospection(columns: columns, estimatedRowCount: rows)
    }

    private func resolve(
        rows: Int64?,
        mode: DuplicateMode = .structureAndData,
        copyMode: DuplicateCopyMode = .auto,
        rowFilter: String? = nil,
        limit: Int64? = nil,
        supportsTransactionalDDL: Bool = true,
        columns: [PluginColumnInfo] = [DuplicateFixtures.column("id", "bigint", primaryKey: true)]
    ) -> DuplicateCopyModeDecision {
        var options = DuplicateOptions()
        options.copyMode = copyMode
        options.rowFilter = rowFilter
        options.limit = limit
        return DuplicateCopyModeResolver.resolve(
            request: DuplicateFixtures.request(mode: mode, options: options),
            introspection: table(rows: rows, columns: columns),
            supportsTransactionalDDL: supportsTransactionalDDL,
            databaseType: .postgresql
        )
    }

    // MARK: - Row estimate

    /// The case the whole resolver exists for. PostgreSQL reports `reltuples = -1` for a table it
    /// never analyzed, the driver maps that to nil, and a five-million-row table then looks small.
    /// Unknown has to mean chunked or a huge copy runs as one statement with no progress.
    @Test("An unknown row estimate picks chunked, not atomic")
    func unknownEstimateIsChunked() {
        #expect(resolve(rows: nil).mode == .chunked)
    }

    @Test("A table above the threshold picks chunked")
    func largeTableIsChunked() {
        #expect(resolve(rows: DuplicateCopyModeResolver.chunkedRowThreshold + 1).mode == .chunked)
    }

    @Test("A table at or below the threshold stays atomic")
    func smallTableIsAtomic() {
        #expect(resolve(rows: DuplicateCopyModeResolver.chunkedRowThreshold).mode == .atomic)
        #expect(resolve(rows: 42).mode == .atomic)
        #expect(resolve(rows: 0).mode == .atomic)
    }

    /// A `LIMIT` caps the work no matter how large the source is, so a hundred rows out of ten
    /// million is a small copy.
    @Test("A small LIMIT on a huge table stays atomic")
    func limitCapsTheEstimate() {
        #expect(resolve(rows: 10_000_000, limit: 100).mode == .atomic)
    }

    /// `reltuples` counts the table, not the filtered subset, so with a filter the estimate is an
    /// answer to a different question and the safe reading is unknown.
    @Test("A row filter makes the estimate unusable and picks chunked")
    func rowFilterIsChunked() {
        #expect(resolve(rows: 42, rowFilter: "status = 'paid'").mode == .chunked)
    }

    // MARK: - Mode overrides

    @Test("Structure-only is always atomic, whatever the estimate says")
    func structureOnlyIsAtomic() {
        let decision = resolve(rows: nil, mode: .structureOnly)
        #expect(decision.mode == .atomic)
        #expect(decision.warnings.isEmpty)
    }

    /// A vendor that commits its `CREATE TABLE` on the spot has nothing to roll back, so one long
    /// statement buys nothing.
    @Test("A vendor without transactional DDL picks chunked even for a small table")
    func nonTransactionalDDLIsChunked() {
        #expect(resolve(rows: 10, supportsTransactionalDDL: false).mode == .chunked)
    }

    @Test("An explicit choice is honoured in both directions")
    func explicitChoiceWins() {
        #expect(resolve(rows: nil, copyMode: .atomic).mode == .atomic)
        #expect(resolve(rows: 10, copyMode: .chunked).mode == .chunked)
    }

    // MARK: - Key requirements

    @Test("A composite primary key falls back to atomic with a warning")
    func compositeKeyFallsBack() {
        let decision = resolve(
            rows: nil,
            columns: [
                DuplicateFixtures.column("tenant_id", "bigint", primaryKey: true),
                DuplicateFixtures.column("order_no", "bigint", primaryKey: true)
            ]
        )
        #expect(decision.mode == .atomic)
        #expect(decision.warnings == [.chunkedNeedsSingleColumnKey])
        #expect(decision.keyColumn == nil)
    }

    @Test("No primary key at all falls back to atomic with a warning")
    func noKeyFallsBack() {
        let decision = resolve(rows: nil, columns: [DuplicateFixtures.column("label", "text")])
        #expect(decision.mode == .atomic)
        #expect(decision.warnings == [.chunkedNeedsSingleColumnKey])
    }

    /// A key the copy does not write back cannot be compared against the rows that landed, so it
    /// is not a usable cursor.
    @Test("A generated primary key falls back to atomic")
    func generatedKeyFallsBack() {
        let decision = resolve(
            rows: nil,
            columns: [DuplicateFixtures.column("id", "bigint", primaryKey: true, generated: true)]
        )
        #expect(decision.mode == .atomic)
    }

    /// A timestamp key renders as a literal the value's own shape cannot classify, and guessing
    /// wrong skips rows or fails the comparison outright.
    @Test("A key type with no unambiguous literal form falls back to atomic")
    func ambiguousKeyTypeFallsBack() {
        let decision = resolve(
            rows: nil,
            columns: [DuplicateFixtures.column("created_at", "timestamp with time zone", primaryKey: true)]
        )
        #expect(decision.mode == .atomic)
        #expect(decision.warnings == [.chunkedNeedsSingleColumnKey])
    }

    @Test("A text key is usable and keeps its textual literal kind")
    func textKeyIsUsable() {
        let decision = resolve(
            rows: nil,
            columns: [DuplicateFixtures.column("code", "text", primaryKey: true)]
        )
        #expect(decision.mode == .chunked)
        #expect(decision.keyLiteralKind == .textual)
    }

    // MARK: - Warnings

    /// Every committed batch is its own snapshot, so the copy can straddle another session's
    /// writes. The warning is shown only when that is true, never for atomic mode.
    @Test("Chunked warns that the copy is not a snapshot, atomic does not")
    func chunkedWarnsAboutSnapshot() {
        #expect(resolve(rows: nil).warnings == [.chunkedCopyIsNotASnapshot])
        #expect(resolve(rows: 42).warnings.isEmpty)
    }

    @Test("No warning is blocking, so the copy still runs")
    func warningsAreNotBlocking() {
        #expect(!DuplicateWarning.chunkedCopyIsNotASnapshot.isBlocking)
        #expect(!DuplicateWarning.chunkedNeedsSingleColumnKey.isBlocking)
    }
}
