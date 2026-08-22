//
//  DuplicatePlanBuilder+PostgreSQL.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Builds the duplicate sequence on top of `CREATE TABLE … (LIKE … INCLUDING …)` rather than
/// synthesising column DDL. The server reproduces opclasses, collations, index expressions,
/// partial predicates and storage parameters exactly, and names the new indexes itself, so no
/// text is ever rewritten.
struct PostgreSqlDuplicatePlanBuilder: DuplicatePlanBuilding {
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

        let source = qualified(request.source, quoting: quoting)
        let target = qualified(request.target, quoting: quoting)
        let copiesData = request.mode == .structureAndData
        let rewritesIndexes = copiesData && request.options.indexes
        let copyMode = DuplicateCopyModeResolver.resolve(
            request: request,
            introspection: introspection,
            supportsTransactionalDDL: true,
            databaseType: .postgresql
        )
        warnings.append(contentsOf: copyMode.warnings)

        var statements: [DuplicateStatement] = []

        if let filter = activeRowFilter(request) {
            statements.append(
                DuplicateStatement(
                    kind: .validateRowFilter,
                    sql: "EXPLAIN SELECT 1 FROM \(source) WHERE \(filter)"
                )
            )
        }

        statements.append(createTable(source: source, target: target, options: request.options))

        if request.options.comments, let comment = introspection.tableComment {
            statements.append(
                DuplicateStatement(
                    kind: .tableComment,
                    sql: "COMMENT ON TABLE \(target) IS \(quoting.stringLiteral(comment))"
                )
            )
        }

        if rewritesIndexes {
            statements.append(harvestIndexes(target: request.target, quoting: quoting))
            statements.append(DuplicateStatement(kind: .dropIndex, deferred: .fromHarvestedIndexes))
        }

        statements.append(
            contentsOf: sequenceStatements(request: request, introspection: introspection, quoting: quoting)
        )

        if copiesData {
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

        if rewritesIndexes {
            statements.append(DuplicateStatement(kind: .replayIndex, deferred: .fromHarvestedIndexes))
        }

        if request.options.identity {
            statements.append(
                contentsOf: resetSequences(request: request, introspection: introspection, quoting: quoting)
            )
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

        statements.append(DuplicateStatement(kind: .analyze, sql: "ANALYZE \(target)"))

        return DuplicatePlan(
            statements: statements,
            warnings: warnings,
            copyMode: copyMode.mode,
            estimatedRowCount: introspection.estimatedRowCount,
            indexDialect: .postgresql
        )
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
        if introspection.hasRowLevelSecurity {
            warnings.append(.rowLevelSecurityPoliciesNotCopied)
            if !introspection.isOwner {
                warnings.append(.rowLevelSecurityMayHideRows)
            }
        }
        return warnings
    }

    // MARK: - Structure

    /// `INCLUDING COMMENTS` covers columns, constraints and indexes but not the table's own
    /// comment, which is why a separate `COMMENT ON TABLE` statement exists.
    private func createTable(source: String, target: String, options: DuplicateOptions) -> DuplicateStatement {
        var clauses: [String] = []
        if options.defaults { clauses.append("INCLUDING DEFAULTS") }
        if options.constraints { clauses.append("INCLUDING CONSTRAINTS") }
        if options.indexes { clauses.append("INCLUDING INDEXES") }
        if options.identity { clauses.append("INCLUDING IDENTITY") }
        if options.generated { clauses.append("INCLUDING GENERATED") }
        if options.tableOptions {
            clauses.append("INCLUDING STORAGE")
            clauses.append("INCLUDING COMPRESSION")
            clauses.append("INCLUDING STATISTICS")
        }
        if options.comments { clauses.append("INCLUDING COMMENTS") }

        let body = clauses.isEmpty ? "LIKE \(source)" : "LIKE \(source) \(clauses.joined(separator: " "))"
        return DuplicateStatement(kind: .createTable, sql: "CREATE TABLE \(target) (\(body))")
    }

    /// Reads the index definitions the server generated for the **target**, not the source: the
    /// names only exist after the table does, and replaying them verbatim is what avoids
    /// rewriting a predicate or an opclass.
    private func harvestIndexes(target: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> DuplicateStatement {
        let literal = quoting.stringLiteral(qualifiedLiteral(target, quoting: quoting))
        let sql = """
        SELECT i.indexrelid::regclass::text, pg_get_indexdef(i.indexrelid)
        FROM pg_index i
        WHERE i.indrelid = \(literal)::regclass
          AND NOT i.indisprimary
          AND NOT EXISTS (
              SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid
          )
        """
        return DuplicateStatement(kind: .harvestIndexes, sql: sql)
    }

    // MARK: - Sequences

    /// With identity on, each `serial` column gets its own sequence. With identity off the
    /// column must still stop pointing at the source's sequence: `INCLUDING DEFAULTS` copies the
    /// `nextval('source_seq')` expression verbatim, so leaving it would make every insert into
    /// the copy advance the **original** table's sequence. Dropping the default is what spec
    /// §6.2 means by removing the default sequence when the option is off.
    private func sequenceStatements(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        quoting: DuplicateSQLQuoting
    ) -> [DuplicateStatement] {
        guard request.options.identity else {
            guard request.options.defaults else { return [] }
            let target = qualified(request.target, quoting: quoting)
            return introspection.serialColumns.map { column in
                DuplicateStatement(
                    kind: .setColumnDefault,
                    sql: "ALTER TABLE \(target) ALTER COLUMN \(quoting.identifier(column.name)) DROP DEFAULT"
                )
            }
        }
        return sequenceFixups(request: request, introspection: introspection, quoting: quoting)
    }

    /// The new sequence is created after the table and pointed at afterwards, so there is no
    /// ordering requirement to get wrong.
    private func sequenceFixups(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        quoting: DuplicateSQLQuoting
    ) -> [DuplicateStatement] {
        let target = qualified(request.target, quoting: quoting)
        return introspection.serialColumns.flatMap { column -> [DuplicateStatement] in
            guard let attributes = introspection.sequencesByColumn[column.name] else { return [] }
            let sequence = newSequenceName(request: request, column: column.name)
            let qualifiedSequence = qualified(
                DuplicateTableRef(schema: request.targetSchema, name: sequence),
                quoting: quoting
            )
            let quotedColumn = quoting.identifier(column.name)
            let cycle = attributes.cycle ? " CYCLE" : ""
            return [
                DuplicateStatement(
                    kind: .createSequence,
                    sql: """
                    CREATE SEQUENCE \(qualifiedSequence) INCREMENT BY \(attributes.increment) \
                    MINVALUE \(attributes.minValue) MAXVALUE \(attributes.maxValue) \
                    CACHE \(attributes.cache)\(cycle)
                    """
                ),
                DuplicateStatement(
                    kind: .setColumnDefault,
                    sql: """
                    ALTER TABLE \(target) ALTER COLUMN \(quotedColumn) \
                    SET DEFAULT nextval(\(quoting.stringLiteral(qualifiedSequenceLiteral(request, sequence, quoting: quoting))))
                    """
                ),
                DuplicateStatement(
                    kind: .ownSequence,
                    sql: "ALTER SEQUENCE \(qualifiedSequence) OWNED BY \(target).\(quotedColumn)"
                )
            ]
        }
    }

    /// A structure-only copy must not inherit the source sequence's current value, so it resets
    /// to the start rather than to `max(column)`.
    private func resetSequences(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        quoting: DuplicateSQLQuoting
    ) -> [DuplicateStatement] {
        let target = qualified(request.target, quoting: quoting)
        let targetLiteral = quoting.stringLiteral(qualifiedLiteral(request.target, quoting: quoting))
        return introspection.serialColumns.map { column in
            let columnLiteral = quoting.stringLiteral(column.name)
            let sequenceExpression = "pg_get_serial_sequence(\(targetLiteral), \(columnLiteral))"
            guard request.mode == .structureAndData else {
                return DuplicateStatement(
                    kind: .resetSequence,
                    sql: "SELECT setval(\(sequenceExpression), 1, false)"
                )
            }
            let quotedColumn = quoting.identifier(column.name)
            return DuplicateStatement(
                kind: .resetSequence,
                sql: """
                SELECT setval(\(sequenceExpression), COALESCE(MAX(\(quotedColumn)), 1), \
                MAX(\(quotedColumn)) IS NOT NULL) FROM \(target)
                """
            )
        }
    }

    // MARK: - Data

    /// Columns are listed explicitly so generated columns can be left out: the server computes
    /// them and rejects a write. `OVERRIDING SYSTEM VALUE` appears only for `GENERATED ALWAYS AS
    /// IDENTITY`, where the server would otherwise refuse the original values.
    private func copyData(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection,
        source: String,
        target: String,
        quoting: DuplicateSQLQuoting,
        copyMode: DuplicateCopyModeDecision
    ) -> DuplicateStatement {
        let columns = introspection.writableColumns.map { quoting.identifier($0.name) }
        let columnList = columns.joined(separator: ", ")
        let overriding = introspection.hasIdentityAlwaysColumn ? " OVERRIDING SYSTEM VALUE" : ""

        if let spec = chunkedSpec(
            request: request,
            source: source,
            target: target,
            columnList: columnList,
            overriding: overriding,
            copyMode: copyMode
        ) {
            return DuplicateStatement(kind: .copyData, chunked: spec)
        }

        var sql = "INSERT INTO \(target) (\(columnList))\(overriding)\n"
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

    /// PostgreSQL reads the last key of a batch off the insert itself: a data-modifying CTE
    /// returns the keys it wrote, and `MAX` over them is one extra aggregate rather than a second
    /// round trip.
    private func chunkedSpec(
        request: DuplicateTableRequest,
        source: String,
        target: String,
        columnList: String,
        overriding: String,
        copyMode: DuplicateCopyModeDecision
    ) -> DuplicateChunkedCopySpec? {
        guard copyMode.isChunked, let key = copyMode.keyColumn, let kind = copyMode.keyLiteralKind else {
            return nil
        }
        return DuplicateChunkedCopySpec(
            source: source,
            target: target,
            columnList: columnList,
            overriding: overriding,
            keyColumn: key,
            keyLiteralKind: kind,
            rowFilter: activeRowFilter(request),
            batchSize: request.options.batchSize,
            limit: request.options.limit,
            strategy: .insertReturning
        )
    }

    // MARK: - Naming

    private func activeRowFilter(_ request: DuplicateTableRequest) -> String? {
        guard request.mode == .structureAndData else { return nil }
        guard let filter = request.options.rowFilter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filter.isEmpty else { return nil }
        return filter
    }

    /// The one place this feature names an object itself, so the byte-budget rules apply here and
    /// nowhere else: index and constraint names come from the server.
    private func newSequenceName(request: DuplicateTableRequest, column: String) -> String {
        let policy = TransferIdentifierPolicy.policy(for: .postgresql)
        return policy.shorten("\(request.targetName)_\(column)_seq")
    }

    private func qualified(_ ref: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        quoting.qualified(ref)
    }

    /// The text form a `regclass` cast or `pg_get_serial_sequence` expects: the same
    /// schema-qualified, quoted name the driver would produce, then escaped as a string literal.
    /// It goes through the injected quoting rather than concatenating quote marks here, so there
    /// is only one implementation of the vendor's escaping rules.
    private func qualifiedLiteral(_ ref: DuplicateTableRef, quoting: DuplicateSQLQuoting) -> String {
        qualified(ref, quoting: quoting)
    }

    private func qualifiedSequenceLiteral(
        _ request: DuplicateTableRequest,
        _ sequence: String,
        quoting: DuplicateSQLQuoting
    ) -> String {
        qualifiedLiteral(DuplicateTableRef(schema: request.targetSchema, name: sequence), quoting: quoting)
    }
}
