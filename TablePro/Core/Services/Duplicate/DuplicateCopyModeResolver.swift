//
//  DuplicateCopyModeResolver.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the resolver decided and what the user has to be told about it. The key column travels
/// with the decision because the same rule that picks chunked mode is the one that proves a
/// usable key exists; recomputing it in the builder would be a second copy of that rule.
struct DuplicateCopyModeDecision: Sendable, Hashable {
    let mode: DuplicateCopyMode
    let keyColumn: String?
    let keyLiteralKind: TransferKeyLiteralKind?
    let warnings: [DuplicateWarning]

    var isChunked: Bool { mode == .chunked }
}

/// Picks between one server-side `INSERT … SELECT` and a loop of committed batches.
///
/// Pure, so the whole matrix is testable without a server, including the case that matters most:
/// an unknown row count. `reltuples` is `-1` on a table that was never analyzed, which the driver
/// already maps to `nil`. Treating `nil` as "small" would run a five-million-row copy as one
/// statement with no progress and no way back except a rollback of the entire thing.
enum DuplicateCopyModeResolver {
    /// Above this the copy is long enough that a user needs progress and a stop that keeps what
    /// it already wrote.
    static let chunkedRowThreshold: Int64 = 1_000_000

    static func resolve(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        supportsTransactionalDDL: Bool,
        databaseType: DatabaseType
    ) -> DuplicateCopyModeDecision {
        guard request.mode == .structureAndData else {
            return DuplicateCopyModeDecision(mode: .atomic, keyColumn: nil, keyLiteralKind: nil, warnings: [])
        }
        let wantsChunked = wantsChunked(
            request: request,
            introspection: introspection,
            supportsTransactionalDDL: supportsTransactionalDDL
        )
        guard wantsChunked else {
            return DuplicateCopyModeDecision(mode: .atomic, keyColumn: nil, keyLiteralKind: nil, warnings: [])
        }

        guard let key = chunkKey(introspection: introspection, databaseType: databaseType) else {
            return DuplicateCopyModeDecision(
                mode: .atomic,
                keyColumn: nil,
                keyLiteralKind: nil,
                warnings: [.chunkedNeedsSingleColumnKey]
            )
        }

        return DuplicateCopyModeDecision(
            mode: .chunked,
            keyColumn: key.column.name,
            keyLiteralKind: key.kind,
            warnings: [.chunkedCopyIsNotASnapshot]
        )
    }

    /// An explicit choice is honoured as written. `.auto` is where the rules live: a vendor
    /// without transactional DDL has already committed its `CREATE TABLE`, so a single long
    /// statement buys nothing that a rollback could undo.
    private static func wantsChunked(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        supportsTransactionalDDL: Bool
    ) -> Bool {
        switch request.options.copyMode {
        case .atomic:
            return false
        case .chunked:
            return true
        case .auto:
            guard supportsTransactionalDDL else { return true }
            guard let rows = effectiveRowCount(request: request, introspection: introspection) else { return true }
            return rows > chunkedRowThreshold
        }
    }

    /// A row filter makes `reltuples` an answer to a different question, and counting the filtered
    /// rows for real would mean a full scan before the copy even starts. Unknown is the honest
    /// answer, and unknown means chunked.
    private static func effectiveRowCount(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection
    ) -> Int64? {
        guard request.options.rowFilter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return nil
        }
        guard let estimated = introspection.estimatedRowCount else { return nil }
        guard let limit = request.options.limit else { return estimated }
        return min(estimated, limit)
    }

    /// Keyset pagination needs one column that orders totally and renders as a literal the server
    /// compares the same way it orders the column. A composite key, a key the copy does not write,
    /// or a type whose literal form is ambiguous all fail that, and the answer is atomic mode with
    /// a warning rather than `OFFSET`, which rescans everything it already read and skips rows
    /// when another session writes between pages.
    private static func chunkKey(
        introspection: DuplicateTableIntrospection,
        databaseType: DatabaseType
    ) -> (column: PluginColumnInfo, kind: TransferKeyLiteralKind)? {
        let keys = introspection.columns.filter(\.isPrimaryKey)
        guard keys.count == 1, let key = keys.first else { return nil }
        guard introspection.writableColumns.contains(where: { $0.name == key.name }) else { return nil }
        let kinds = TransferChunkPlanner.keyLiteralKinds(
            columns: introspection.columns,
            primaryKeyColumns: [key.name],
            databaseType: databaseType
        )
        guard let kind = kinds[key.name] else { return nil }
        return (key, kind)
    }
}
