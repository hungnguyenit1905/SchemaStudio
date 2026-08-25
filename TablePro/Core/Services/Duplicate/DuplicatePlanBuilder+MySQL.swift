//
//  DuplicatePlanBuilder+MySQL.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Builds the duplicate sequence on top of `CREATE TABLE t2 LIKE t1`.
///
/// The engine reproduces the storage engine, the row format, every column's precision, unsigned
/// and zerofill flags, the character set and collation, the indexes and the CHECK constraints
/// exactly. None of that is written here, which is the point: a builder that spelled out column
/// DDL would be a second, worse implementation of what the server already does.
///
/// What `LIKE` does not carry is foreign keys, triggers and rows. Triggers are out of scope for
/// this phase; the other two are what the rest of this plan is for.
struct MySqlDuplicatePlanBuilder: DuplicatePlanBuilding {
    func plan(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        quoting: DuplicateSQLQuoting
    ) -> DuplicatePlan {
        var warnings = warnings(for: request, introspection: introspection)
        guard !introspection.isPartitioned else {
            return DuplicatePlan(statements: [], warnings: warnings)
        }

        let groupedForeignKeys: DuplicateForeignKeyGrouping.Result? = request.options.foreignKeys
            ? DuplicateForeignKeyGrouping.grouped(introspection.foreignKeys)
            : nil
        warnings.append(contentsOf: groupedForeignKeys?.warnings ?? [])

        let source = quoting.qualified(request.source)
        let target = quoting.qualified(request.target)
        let copyMode = DuplicateCopyModeResolver.resolve(
            request: request,
            introspection: introspection,
            supportsTransactionalDDL: false,
            databaseType: .mysql
        )
        warnings.append(contentsOf: copyMode.warnings)

        let indexHandling = indexHandling(request: request, introspection: introspection)
        if indexHandling == .keptInPlace {
            warnings.append(.indexesKeptDuringCopy)
        }

        var statements: [DuplicateStatement] = []

        if let filter = activeRowFilter(request) {
            statements.append(
                DuplicateStatement(
                    kind: .validateRowFilter,
                    sql: "EXPLAIN SELECT 1 FROM \(source) WHERE \(filter)"
                )
            )
        }

        statements.append(DuplicateStatement(kind: .createTable, sql: "CREATE TABLE \(target) LIKE \(source)"))

        // `LIKE` copies the table comment with everything else, so the only thing the comment
        // switch can mean here is removing it again.
        if !request.options.comments {
            statements.append(
                DuplicateStatement(kind: .tableComment, sql: "ALTER TABLE \(target) COMMENT = ''")
            )
        }

        if indexHandling != .keptInPlace {
            statements.append(DuplicateStatement(kind: .harvestIndexes, sql: "SHOW CREATE TABLE \(target)"))
            statements.append(DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes))
        }

        if request.mode == .structureAndData {
            statements.append(
                copyData(
                    request: request,
                    introspection: introspection,
                    source: source,
                    target: target,
                    quoting: quoting,
                    copyMode: copyMode
                )
            )
        }

        if indexHandling == .droppedAndReplayed {
            statements.append(DuplicateStatement(kind: .replayIndex, deferred: .fromHarvestedIndexes))
        }

        if request.options.identity, introspection.hasAutoIncrementColumn {
            statements.append(autoIncrementReset(target: target))
        }

        if let groupedForeignKeys {
            statements.append(
                contentsOf: DuplicateForeignKeyGrouping.statements(
                    request: request,
                    keys: groupedForeignKeys.keys,
                    quoting: quoting
                )
            )
        }

        statements.append(DuplicateStatement(kind: .analyze, sql: "ANALYZE TABLE \(target)"))

        return DuplicatePlan(
            statements: statements,
            warnings: warnings,
            copyMode: copyMode.mode,
            estimatedRowCount: introspection.estimatedRowCount,
            indexDialect: .mysql(target: target)
        )
    }

    // MARK: - Indexes

    private enum IndexHandling {
        /// Dropped before the copy and put back after, so the rows land against a heap.
        case droppedAndReplayed
        /// Dropped and never put back, which is what turning the index switch off means.
        case droppedOnly
        /// Left alone: the copy is slower, but nothing can be lost.
        case keptInPlace
    }

    /// An index on an expression cannot be read back out of `SHOW CREATE TABLE` with enough
    /// confidence to drop it and write it again, so its presence turns the speedup off for the
    /// whole table. Slower beats losing an index (spec test 15's failure mode, one step earlier).
    private func indexHandling(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection
    ) -> IndexHandling {
        guard request.options.indexes else { return .droppedOnly }
        guard request.mode == .structureAndData else { return .keptInPlace }
        guard !introspection.hasExpressionIndex else { return .keptInPlace }
        return .droppedAndReplayed
    }

    // MARK: - Auto increment

    /// MySQL refuses to set the counter below the largest value already stored and quietly uses
    /// `max + 1` instead, so `= 1` is exactly the "reset to max + 1" the spec asks for after a
    /// copy, and a real reset to 1 on an empty structure-only copy. No `MAX` query is needed and
    /// the builder stays pure.
    ///
    /// Best effort on purpose: the counter is derived from the data on the next insert anyway, so
    /// losing this step to a metadata lock must never discard a copy that already landed.
    private func autoIncrementReset(target: String) -> DuplicateStatement {
        DuplicateStatement(kind: .resetAutoIncrement, sql: "ALTER TABLE \(target) AUTO_INCREMENT = 1")
    }

    // MARK: - Warnings

    private func warnings(
        for request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection
    ) -> [DuplicateWarning] {
        var warnings: [DuplicateWarning] = []
        if introspection.isPartitioned {
            warnings.append(.partitionedTableNotSupported(request.source.name))
        }
        let alwaysCopied = Self.alwaysCopiedOptions(request.options)
        if !alwaysCopied.isEmpty {
            warnings.append(.optionsAlwaysCopied(alwaysCopied))
        }
        return warnings
    }

    /// Switches the engine cannot honour. `CREATE TABLE … LIKE` is all or nothing for these, and
    /// undoing them afterwards would mean rewriting column DDL from metadata, which is the thing
    /// this builder exists to avoid. Saying so is better than a switch that silently does nothing.
    static func alwaysCopiedOptions(_ options: DuplicateOptions) -> [String] {
        var names: [String] = []
        if !options.constraints { names.append(String(localized: "primary key, unique keys and check constraints")) }
        if !options.defaults { names.append(String(localized: "default values")) }
        if !options.identity { names.append(String(localized: "auto increment")) }
        if !options.generated { names.append(String(localized: "generated columns")) }
        if !options.tableOptions { names.append(String(localized: "table options")) }
        return names
    }

    // MARK: - Data

    /// Generated columns are left out of both lists: MySQL rejects a write to a virtual or a
    /// stored generated column and computes it itself. There is no `OVERRIDING SYSTEM VALUE`
    /// equivalent to worry about, because an `AUTO_INCREMENT` column accepts an explicit value.
    private func copyData(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        source: String,
        target: String,
        quoting: DuplicateSQLQuoting,
        copyMode: DuplicateCopyModeDecision
    ) -> DuplicateStatement {
        let columnList = introspection.writableColumns
            .map { quoting.identifier($0.name) }
            .joined(separator: ", ")

        if let spec = chunkedSpec(
            request: request,
            source: source,
            target: target,
            columnList: columnList,
            copyMode: copyMode
        ) {
            return DuplicateStatement(kind: .copyData, chunked: spec)
        }

        var sql = "INSERT INTO \(target) (\(columnList))\n"
        sql += "SELECT \(columnList) FROM \(source)"
        if let filter = activeRowFilter(request) {
            sql += " WHERE \(filter)"
        }
        if let limit = request.options.limit {
            let keys = introspection.columns.filter(\.isPrimaryKey).map { quoting.identifier($0.name) }
            if !keys.isEmpty {
                sql += " ORDER BY \(keys.joined(separator: ", "))"
            }
            sql += " LIMIT \(limit)"
        }
        return DuplicateStatement(kind: .copyData, sql: sql)
    }

    /// MySQL has no `RETURNING`, so a batch cannot report where it ended. The runner reads the
    /// last key with a second statement bounded to the range the insert just wrote.
    private func chunkedSpec(
        request: DuplicateTableRequest,
        source: String,
        target: String,
        columnList: String,
        copyMode: DuplicateCopyModeDecision
    ) -> DuplicateChunkedCopySpec? {
        guard copyMode.isChunked, let key = copyMode.keyColumn, let kind = copyMode.keyLiteralKind else {
            return nil
        }
        return DuplicateChunkedCopySpec(
            source: source,
            target: target,
            columnList: columnList,
            overriding: "",
            keyColumn: key,
            keyLiteralKind: kind,
            rowFilter: activeRowFilter(request),
            batchSize: request.options.batchSize,
            limit: request.options.limit,
            strategy: .selectMaxOverInsertedRange
        )
    }

    private func activeRowFilter(_ request: DuplicateTableRequest) -> String? {
        guard request.mode == .structureAndData else { return nil }
        guard let filter = request.options.rowFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filter.isEmpty else { return nil }
        return filter
    }
}
