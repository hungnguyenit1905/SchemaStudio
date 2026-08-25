//
//  DuplicatePlanBuilderMySQLTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("MySqlDuplicatePlanBuilder")
struct DuplicatePlanBuilderMySQLTests {
    private let builder = MySqlDuplicatePlanBuilder()
    private let quoting = DuplicateFixtures.mysqlQuoting

    private func plan(
        _ request: DuplicateTableRequest,
        _ introspection: DuplicateTableIntrospection
    ) -> DuplicatePlan {
        builder.plan(request: request, introspection: introspection, quoting: quoting)
    }

    private func sql(_ plan: DuplicatePlan, kind: DuplicateStatement.Kind) -> [String] {
        plan.statements.compactMap { statement in
            guard statement.kind == kind, case .sql(let sql) = statement.body else { return nil }
            return sql
        }
    }

    // MARK: - Structure

    /// The engine, the charset, the row format and every column attribute come from `LIKE`. A
    /// builder that spelled any of that out would be a second, worse implementation of the server.
    @Test("The table is created with LIKE and nothing about its columns is written out")
    func createsWithLike() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        #expect(sql(plan, kind: .createTable) == ["CREATE TABLE `orders_copy` LIKE `orders`"])
    }

    @Test("The plan ends with ANALYZE TABLE, which may fail without discarding the copy")
    func analyzesLast() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        #expect(plan.statements.last?.kind == .analyze)
        #expect(sql(plan, kind: .analyze) == ["ANALYZE TABLE `orders_copy`"])
        #expect(plan.statements.last?.severity == .bestEffort)
    }

    /// MySQL commits every DDL statement, so a run that looks atomic still has committed objects.
    @Test("A copy always runs in chunked semantics")
    func alwaysChunked() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        #expect(plan.copyMode == .chunked)
    }

    @Test("The plan declares the MySQL index dialect so the executor reads SHOW CREATE TABLE")
    func declaresDialect() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        #expect(plan.indexDialect == .mysql(target: "`orders_copy`"))
    }

    // MARK: - Auto increment

    /// MySQL refuses to set the counter below the largest stored value and uses `max + 1` instead,
    /// so `= 1` is the reset the spec asks for without a `MAX` query.
    @Test("The auto-increment counter is reset after the copy")
    func resetsAutoIncrement() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        #expect(sql(plan, kind: .resetAutoIncrement) == ["ALTER TABLE `orders_copy` AUTO_INCREMENT = 1"])
    }

    /// Losing the counter to a metadata lock after twenty million rows have landed must not
    /// discard the copy: the next insert derives the same value from the data anyway.
    @Test("Failing to set the counter is best effort, not fatal")
    func autoIncrementIsBestEffort() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        let statement = plan.statements.first { $0.kind == .resetAutoIncrement }
        #expect(statement?.severity == .bestEffort)
    }

    @Test("A table with no auto-increment column gets no counter statement")
    func noAutoIncrementColumnNoStatement() {
        let introspection = DuplicateTableIntrospection(
            columns: [DuplicateFixtures.column("id", "int", primaryKey: true)],
            estimatedRowCount: DuplicateFixtures.analyzedRowCount
        )
        #expect(sql(plan(DuplicateFixtures.mysqlRequest(), introspection), kind: .resetAutoIncrement).isEmpty)
    }

    // MARK: - Indexes

    @Test("Indexes are harvested from SHOW CREATE TABLE on the new table, not the source")
    func harvestsFromTarget() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        #expect(sql(plan, kind: .harvestIndexes) == ["SHOW CREATE TABLE `orders_copy`"])
    }

    /// MySQL rebuilds the whole table once per `ALTER`, so six indexes in six statements is six
    /// rebuilds of a table that may hold millions of rows.
    @Test("Every index is dropped in one ALTER and put back in one ALTER")
    func combinesIndexStatements() {
        let dialect = DuplicateIndexDialect.mysql(target: "`orders_copy`")
        let harvested = dialect.harvestedIndexes(from: [["orders_copy", MySQLCreateTableFixtures.mysql8]])

        #expect(
            dialect.dropSQL(for: harvested, quoting: quoting) == [
                """
                ALTER TABLE `orders_copy` DROP INDEX `uq_orders_email`, DROP INDEX `idx_orders_tenant`, \
                DROP INDEX `idx_orders_email_prefix`, DROP INDEX `ft_orders_body`
                """
            ]
        )
        #expect(
            dialect.replaySQL(for: harvested) == [
                """
                ALTER TABLE `orders_copy` ADD UNIQUE KEY `uq_orders_email` (`email`), \
                ADD KEY `idx_orders_tenant` (`tenant_id`,`id`), \
                ADD KEY `idx_orders_email_prefix` (`email`(10)), \
                ADD FULLTEXT KEY `ft_orders_body` (`body`)
                """
            ]
        )
    }

    @Test("Nothing is harvested when the server reports no create statement")
    func emptyHarvestYieldsNothing() {
        let dialect = DuplicateIndexDialect.mysql(target: "`orders_copy`")
        #expect(dialect.harvestedIndexes(from: []).isEmpty)
        #expect(dialect.dropSQL(for: [], quoting: quoting).isEmpty)
        #expect(dialect.replaySQL(for: []).isEmpty)
    }

    /// An index on an expression cannot be read back with enough confidence to drop and rewrite,
    /// so the whole table keeps its indexes during the copy. Slower beats losing an index.
    @Test("An expression index keeps every index in place and says so")
    func expressionIndexKeepsIndexes() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlExpressionIndexTable)
        #expect(sql(plan, kind: .harvestIndexes).isEmpty)
        #expect(!plan.statements.contains { $0.kind == .dropIndex || $0.kind == .replayIndex })
        #expect(plan.warnings.contains(.indexesKeptDuringCopy))
    }

    @Test("A structure-only copy leaves the indexes LIKE created and harvests nothing")
    func structureOnlyKeepsIndexes() {
        let plan = plan(
            DuplicateFixtures.mysqlRequest(mode: .structureOnly),
            DuplicateFixtures.mysqlAutoIncrementTable
        )
        #expect(sql(plan, kind: .harvestIndexes).isEmpty)
        #expect(!plan.statements.contains { $0.kind == .copyData })
    }

    /// Turning indexes off is the one thing `LIKE` cannot express, so the copy drops what the
    /// server created and never puts it back.
    @Test("Turning indexes off drops them and skips the replay")
    func indexesOffDropsWithoutReplay() {
        var options = DuplicateOptions()
        options.indexes = false
        let plan = plan(
            DuplicateFixtures.mysqlRequest(options: options),
            DuplicateFixtures.mysqlAutoIncrementTable
        )
        #expect(plan.statements.contains { $0.kind == .dropIndex })
        #expect(!plan.statements.contains { $0.kind == .replayIndex })
    }

    // MARK: - Data

    /// MySQL computes a generated column itself and rejects a write to one, virtual or stored.
    @Test("Generated columns are left out of both sides of the copy")
    func generatedColumnsExcluded() {
        var options = DuplicateOptions()
        options.copyMode = .atomic
        let plan = plan(
            DuplicateFixtures.mysqlRequest(options: options),
            DuplicateFixtures.mysqlAutoIncrementTable
        )
        let copy = sql(plan, kind: .copyData).first
        #expect(copy?.contains("`total`") == false)
        #expect(copy?.hasPrefix("INSERT INTO `orders_copy` (`id`, `email`)") == true)
    }

    /// `OVERRIDING SYSTEM VALUE` is PostgreSQL syntax. An `AUTO_INCREMENT` column takes an
    /// explicit value without any ceremony, and emitting the clause would be a syntax error.
    @Test("The copy never carries PostgreSQL's OVERRIDING clause")
    func noOverridingClause() {
        var options = DuplicateOptions()
        options.copyMode = .atomic
        let plan = plan(
            DuplicateFixtures.mysqlRequest(options: options),
            DuplicateFixtures.mysqlAutoIncrementTable
        )
        #expect(sql(plan, kind: .copyData).first?.contains("OVERRIDING") == false)
    }

    /// MySQL has no `RETURNING`, so a batch cannot say where it ended and a second statement has
    /// to read it back over the range the insert just wrote.
    @Test("A chunked copy reads its last key with a follow-up statement")
    func chunkedUsesFollowUpRead() throws {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.mysqlAutoIncrementTable)
        let statement = try #require(plan.statements.first { $0.kind == .copyData })
        guard case .chunked(let spec) = statement.body else {
            Issue.record("The copy is not chunked")
            return
        }
        #expect(spec.strategy == .selectMaxOverInsertedRange)
        #expect(spec.overriding.isEmpty)
        #expect(spec.keyColumn == "id")
    }

    // MARK: - Foreign keys

    /// `CREATE TABLE … LIKE` carries no foreign key at all, so every one of them is written here.
    @Test("Foreign keys are added when asked for and point at the copy when self-referencing")
    func addsForeignKeys() {
        var options = DuplicateOptions()
        options.foreignKeys = true
        let request = DuplicateTableRequest(
            source: DuplicateTableRef(schema: nil, name: "orders"),
            targetSchema: nil,
            targetName: "orders_copy",
            mode: .structureAndData,
            options: options
        )
        let introspection = DuplicateTableIntrospection(
            columns: [DuplicateFixtures.column("id", "int", primaryKey: true), DuplicateFixtures.column("parent_id")],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_parent_fk",
                    column: "parent_id",
                    referencedTable: "orders",
                    referencedColumn: "id",
                    referencedSchema: nil,
                    onDelete: "CASCADE",
                    onUpdate: "NO ACTION"
                )
            ],
            estimatedRowCount: DuplicateFixtures.analyzedRowCount
        )
        #expect(
            sql(plan(request, introspection), kind: .addForeignKey) == [
                """
                ALTER TABLE `orders_copy` ADD FOREIGN KEY (`parent_id`) \
                REFERENCES `orders_copy` (`id`) ON DELETE CASCADE
                """
            ]
        )
    }

    // MARK: - Options the engine cannot honour

    /// A switch that silently does nothing is worse than a switch that says so. `LIKE` is all or
    /// nothing for these, and undoing them would mean rewriting column DDL from metadata.
    @Test("Switches LIKE cannot turn off are reported instead of being ignored")
    func reportsAlwaysCopiedOptions() {
        var options = DuplicateOptions()
        options.defaults = false
        options.generated = false
        let plan = plan(
            DuplicateFixtures.mysqlRequest(options: options),
            DuplicateFixtures.mysqlAutoIncrementTable
        )
        let reported = plan.warnings.compactMap { warning -> [String]? in
            guard case .optionsAlwaysCopied(let names) = warning else { return nil }
            return names
        }
        #expect(reported.count == 1)
        #expect(reported.first?.count == 2)
    }

    @Test("Every switch left on reports nothing")
    func defaultOptionsReportNothing() {
        #expect(MySqlDuplicatePlanBuilder.alwaysCopiedOptions(DuplicateOptions()).isEmpty)
    }

    /// `LIKE` copies the table comment with everything else, so the comment switch can only mean
    /// clearing it again.
    @Test("Turning comments off clears the comment the copy inherited")
    func commentsOffClearsComment() {
        var options = DuplicateOptions()
        options.comments = false
        let plan = plan(
            DuplicateFixtures.mysqlRequest(options: options),
            DuplicateFixtures.mysqlAutoIncrementTable
        )
        #expect(sql(plan, kind: .tableComment) == ["ALTER TABLE `orders_copy` COMMENT = ''"])
    }

    @Test("Leaving comments on writes no comment statement, because LIKE already carried it")
    func commentsOnWritesNothing() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.commentedTable)
        #expect(sql(plan, kind: .tableComment).isEmpty)
    }

    // MARK: - Refusals

    @Test("A partitioned source produces no statements at all")
    func partitionedSourceIsBlocked() {
        let plan = plan(DuplicateFixtures.mysqlRequest(), DuplicateFixtures.partitionedTable)
        #expect(plan.statements.isEmpty)
        #expect(plan.isBlocked)
    }

    @Test("The row filter is checked with EXPLAIN before anything is created")
    func validatesRowFilterFirst() {
        var options = DuplicateOptions()
        options.rowFilter = "status = 'paid'"
        let plan = plan(
            DuplicateFixtures.mysqlRequest(options: options),
            DuplicateFixtures.mysqlAutoIncrementTable
        )
        #expect(plan.statements.first?.kind == .validateRowFilter)
        #expect(sql(plan, kind: .validateRowFilter) == ["EXPLAIN SELECT 1 FROM `orders` WHERE status = 'paid'"])
    }
}
