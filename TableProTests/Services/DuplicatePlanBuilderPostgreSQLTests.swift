//
//  DuplicatePlanBuilderPostgreSQLTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DuplicatePlanBuilderPostgreSQL")
struct DuplicatePlanBuilderPostgreSQLTests {
    private let builder = PostgreSqlDuplicatePlanBuilder()

    private func plan(
        _ introspection: DuplicateTableIntrospection,
        request: DuplicateTableRequest = DuplicateFixtures.request()
    ) -> DuplicatePlan {
        builder.plan(request: request, introspection: introspection, quoting: DuplicateFixtures.quoting)
    }

    /// Ordering assertions go through this rather than force-unwrapping two indices: a missing
    /// kind reads as "does not precede" and the accompanying presence check reports which one.
    private func precedes(
        _ kinds: [DuplicateStatement.Kind],
        _ first: DuplicateStatement.Kind,
        _ second: DuplicateStatement.Kind
    ) -> Bool {
        guard let firstIndex = kinds.firstIndex(of: first),
              let secondIndex = kinds.firstIndex(of: second) else { return false }
        return firstIndex < secondIndex
    }

    private func sql(_ plan: DuplicatePlan, _ kind: DuplicateStatement.Kind) -> [String] {
        plan.statements.compactMap { statement in
            guard statement.kind == kind, case .sql(let text) = statement.body else { return nil }
            return text
        }
    }

    // MARK: - Registry

    @Test("Only in-scope vendors resolve to a builder")
    func registryScope() {
        #expect(DuplicatePlanBuilder.builder(for: .postgresql) != nil)
        #expect(DuplicatePlanBuilder.builder(for: DatabaseType.mongodb) == nil)
        #expect(DuplicatePlanBuilder.builder(for: .sqlite) == nil)
    }

    // MARK: - Statement order

    @Test("Sequence fixup runs after CREATE TABLE, never before it")
    func sequenceFixupFollowsCreateTable() {
        let kinds = plan(DuplicateFixtures.serialTable).statements.map(\.kind)
        #expect(kinds.contains(.createTable))
        #expect(kinds.contains(.createSequence))
        #expect(precedes(kinds, .createTable, .createSequence))
        #expect(precedes(kinds, .createSequence, .setColumnDefault))
        #expect(precedes(kinds, .setColumnDefault, .ownSequence))
    }

    @Test("Indexes are dropped before the copy and replayed after it")
    func indexesStraddleTheCopy() {
        let kinds = plan(DuplicateFixtures.threeIndexTable).statements.map(\.kind)
        for kind in [DuplicateStatement.Kind.harvestIndexes, .dropIndex, .copyData, .replayIndex] {
            #expect(kinds.contains(kind), "missing \(kind)")
        }
        #expect(precedes(kinds, .harvestIndexes, .dropIndex))
        #expect(precedes(kinds, .dropIndex, .copyData))
        #expect(precedes(kinds, .copyData, .replayIndex))
    }

    @Test("Index drop and replay are deferred, not fabricated at build time")
    func indexStatementsAreDeferred() {
        let statements = plan(DuplicateFixtures.threeIndexTable).statements
        let deferred = statements.filter { $0.body == .deferred(.fromHarvestedIndexes) }
        #expect(deferred.count == 2)
        #expect(deferred.map(\.kind) == [.dropIndex, .replayIndex])
    }

    @Test("A structure-only copy leaves the indexes the server just created alone")
    func structureOnlySkipsIndexRewrite() {
        let request = DuplicateFixtures.request(mode: .structureOnly)
        let kinds = plan(DuplicateFixtures.threeIndexTable, request: request).statements.map(\.kind)
        #expect(!kinds.contains(.harvestIndexes))
        #expect(!kinds.contains(.dropIndex))
        #expect(!kinds.contains(.replayIndex))
        #expect(!kinds.contains(.copyData))
    }

    // MARK: - Index fidelity

    /// The builder must never contain the source predicate, let alone a rewritten one. Anything
    /// touching index text happens on the server side of `pg_get_indexdef`.
    @Test("No generated SQL mentions an index name or a predicate literal")
    func indexTextIsNeverRewritten() {
        let generated = plan(DuplicateFixtures.threeIndexTable).statements
            .compactMap { statement -> String? in
                guard case .sql(let text) = statement.body else { return nil }
                return text
            }
            .joined(separator: "\n")
        #expect(!generated.contains("idx_orders_source"))
        #expect(!generated.contains("idx_orders_lower_email"))
        #expect(!generated.contains("source = 'orders'"))
        #expect(!generated.contains("orders_copy'"))
    }

    @Test("A source table named order with an index naming orders produces no rewritten name")
    func awkwardNamesAreNotRewritten() {
        let request = DuplicateFixtures.request(
            source: DuplicateTableRef(schema: "public", name: "order"),
            targetName: "order_copy"
        )
        let generated = plan(DuplicateFixtures.awkwardlyNamedTable, request: request).statements
            .compactMap { statement -> String? in
                guard case .sql(let text) = statement.body else { return nil }
                return text
            }
            .joined(separator: "\n")
        #expect(!generated.contains("idx_order_orders_id"))
        #expect(!generated.contains("idx_order_copy"))
    }

    @Test("Harvest reads the target table, not the source")
    func harvestTargetsTheCopy() {
        let harvest = sql(plan(DuplicateFixtures.threeIndexTable), .harvestIndexes).first
        #expect(harvest?.contains("\"public\".\"orders_copy\"") == true)
        #expect(harvest?.contains("::regclass") == true)
        #expect(harvest?.contains("indisprimary") == true)
    }

    /// A target name containing a quote must not break out of the literal the regclass cast uses.
    @Test("Harvest escapes a target name containing a quote")
    func harvestEscapesTargetName() {
        let request = DuplicateFixtures.request(targetName: "o'brien")
        let harvest = sql(plan(DuplicateFixtures.threeIndexTable, request: request), .harvestIndexes).first
        #expect(harvest?.contains("''") == true)
        #expect(harvest?.contains("'\"public\".\"o'brien\"'") == false)
    }

    // MARK: - INCLUDING flags

    @Test("Every option maps to its INCLUDING clause")
    func includingClausesFollowOptions() {
        let create = sql(plan(DuplicateFixtures.serialTable), .createTable).first ?? ""
        #expect(create.contains("CREATE TABLE \"public\".\"orders_copy\""))
        #expect(create.contains("LIKE \"public\".\"orders\""))
        for clause in ["DEFAULTS", "CONSTRAINTS", "INDEXES", "IDENTITY", "GENERATED", "STORAGE",
                       "COMPRESSION", "STATISTICS", "COMMENTS"] {
            #expect(create.contains("INCLUDING \(clause)"), "missing INCLUDING \(clause)")
        }
    }

    @Test("Turning options off removes their clauses")
    func includingClausesRespectOptionsOff() {
        var options = DuplicateOptions()
        options.indexes = false
        options.constraints = false
        options.tableOptions = false
        let create = sql(plan(DuplicateFixtures.serialTable, request: DuplicateFixtures.request(options: options)),
                         .createTable).first ?? ""
        #expect(!create.contains("INCLUDING INDEXES"))
        #expect(!create.contains("INCLUDING CONSTRAINTS"))
        #expect(!create.contains("INCLUDING STATISTICS"))
        #expect(create.contains("INCLUDING DEFAULTS"))
    }

    // MARK: - Table comment

    /// `INCLUDING COMMENTS` does not carry the table's own comment, so a separate statement must.
    @Test("A table comment gets its own statement")
    func tableCommentIsEmittedSeparately() {
        let comment = sql(plan(DuplicateFixtures.commentedTable), .tableComment).first
        #expect(comment == "COMMENT ON TABLE \"public\".\"orders_copy\" IS 'Customer orders, don''t drop'")
    }

    @Test("No table comment means no comment statement")
    func absentTableCommentEmitsNothing() {
        #expect(sql(plan(DuplicateFixtures.serialTable), .tableComment).isEmpty)
    }

    @Test("Turning comments off drops the table comment statement")
    func commentsOffSkipsTableComment() {
        var options = DuplicateOptions()
        options.comments = false
        let request = DuplicateFixtures.request(options: options)
        #expect(sql(plan(DuplicateFixtures.commentedTable, request: request), .tableComment).isEmpty)
    }

    // MARK: - Sequences

    @Test("A new sequence carries the source attributes including CACHE and CYCLE")
    func sequenceAttributesAreCarried() {
        let create = sql(plan(DuplicateFixtures.serialTable), .createSequence).first ?? ""
        #expect(create.contains("CREATE SEQUENCE \"public\".\"orders_copy_id_seq\""))
        #expect(create.contains("INCREMENT BY 5"))
        #expect(create.contains("MINVALUE 10"))
        #expect(create.contains("MAXVALUE 9999"))
        #expect(create.contains("CACHE 20"))
        #expect(create.contains("CYCLE"))
    }

    @Test("A non-cycling sequence does not gain CYCLE")
    func nonCyclingSequenceStaysNonCycling() {
        let create = sql(plan(DuplicateFixtures.renamedSequenceTable), .createSequence).first ?? ""
        #expect(!create.contains("CYCLE"))
        #expect(create.contains("CACHE 1"))
    }

    /// The new sequence is named from the target table, never from the source sequence, so a
    /// renamed source sequence cannot leak its name into the copy.
    @Test("A renamed source sequence does not name the new sequence")
    func renamedSequenceDoesNotLeak() {
        let statements = plan(DuplicateFixtures.renamedSequenceTable).statements
            .compactMap { statement -> String? in
                guard case .sql(let text) = statement.body else { return nil }
                return text
            }
            .joined(separator: "\n")
        #expect(!statements.contains("legacy_order_counter"))
        #expect(statements.contains("\"orders_copy_id_seq\""))
    }

    @Test("The new column default points at the new sequence")
    func columnDefaultPointsAtNewSequence() {
        let setDefault = sql(plan(DuplicateFixtures.serialTable), .setColumnDefault).first ?? ""
        #expect(setDefault.contains("ALTER TABLE \"public\".\"orders_copy\" ALTER COLUMN \"id\""))
        #expect(setDefault.contains("nextval('\"public\".\"orders_copy_id_seq\"')"))
    }

    @Test("The new sequence is owned by the new column so dropping the table drops it")
    func sequenceIsOwnedByTheNewColumn() {
        let owned = sql(plan(DuplicateFixtures.serialTable), .ownSequence).first
        #expect(owned == """
        ALTER SEQUENCE "public"."orders_copy_id_seq" OWNED BY "public"."orders_copy"."id"
        """)
    }

    @Test("A structure-only copy resets the sequence to the start, not to the source value")
    func structureOnlyResetsSequenceToStart()  {
        let request = DuplicateFixtures.request(mode: .structureOnly)
        let reset = sql(plan(DuplicateFixtures.serialTable, request: request), .resetSequence).first ?? ""
        #expect(reset.contains("setval("))
        #expect(reset.contains(", 1, false)"))
        #expect(!reset.contains("MAX("))
    }

    @Test("A data copy resets the sequence from the copied rows")
    func dataCopyResetsSequenceFromMax() {
        let reset = sql(plan(DuplicateFixtures.serialTable), .resetSequence).first ?? ""
        #expect(reset.contains("COALESCE(MAX(\"id\"), 1)"))
        #expect(reset.contains("MAX(\"id\") IS NOT NULL"))
        #expect(reset.contains("pg_get_serial_sequence('\"public\".\"orders_copy\"', 'id')"))
    }

    @Test("An identity column needs no sequence fixup")
    func identityColumnSkipsSequenceFixup() {
        let kinds = plan(DuplicateFixtures.identityAlwaysTable).statements.map(\.kind)
        #expect(!kinds.contains(.createSequence))
        #expect(!kinds.contains(.ownSequence))
    }

    /// Turning identity off must not leave the copied `nextval('source_seq')` default in place.
    /// If it did, every insert into the copy would advance the original table's sequence.
    @Test("Turning identity off drops the inherited sequence default instead of sharing it")
    func identityOffDropsInheritedDefault() {
        var options = DuplicateOptions()
        options.identity = false
        let request = DuplicateFixtures.request(options: options)
        let result = plan(DuplicateFixtures.serialTable, request: request)
        let kinds = result.statements.map(\.kind)
        #expect(!kinds.contains(.createSequence))
        #expect(!kinds.contains(.ownSequence))
        #expect(!kinds.contains(.resetSequence))
        #expect(sql(result, .setColumnDefault) == [
            "ALTER TABLE \"public\".\"orders_copy\" ALTER COLUMN \"id\" DROP DEFAULT"
        ])
    }

    @Test("Identity off with defaults off needs no drop, because nothing was inherited")
    func identityOffWithDefaultsOffEmitsNothing() {
        var options = DuplicateOptions()
        options.identity = false
        options.defaults = false
        let request = DuplicateFixtures.request(options: options)
        let result = plan(DuplicateFixtures.serialTable, request: request)
        #expect(sql(result, .setColumnDefault).isEmpty)
        #expect(!result.statements.map(\.kind).contains(.createSequence))
    }

    // MARK: - Data copy

    @Test("Generated columns appear in neither the insert nor the select list")
    func generatedColumnsAreExcluded() {
        let copy = sql(plan(DuplicateFixtures.generatedColumnTable), .copyData).first ?? ""
        #expect(!copy.contains("price_with_tax"))
        #expect(copy.contains("(\"id\", \"price\")"))
        #expect(copy.contains("SELECT \"id\", \"price\""))
    }

    @Test("GENERATED ALWAYS AS IDENTITY needs OVERRIDING SYSTEM VALUE")
    func identityAlwaysOverrides() {
        let copy = sql(plan(DuplicateFixtures.identityAlwaysTable), .copyData).first ?? ""
        #expect(copy.contains("OVERRIDING SYSTEM VALUE"))
    }

    @Test("GENERATED BY DEFAULT AS IDENTITY does not")
    func identityByDefaultDoesNotOverride() {
        let copy = sql(plan(DuplicateFixtures.identityByDefaultTable), .copyData).first ?? ""
        #expect(!copy.contains("OVERRIDING SYSTEM VALUE"))
    }

    @Test("A row filter lands in the copy and in its own validation statement")
    func rowFilterIsValidatedAndApplied() {
        var options = DuplicateOptions()
        options.rowFilter = "status = 'paid'"
        let result = plan(DuplicateFixtures.serialTable, request: DuplicateFixtures.request(options: options))
        #expect(sql(result, .validateRowFilter).first == "EXPLAIN SELECT 1 FROM \"public\".\"orders\" WHERE status = 'paid'")
        #expect(sql(result, .copyData).first?.contains("WHERE status = 'paid'") == true)
    }

    @Test("A structure-only copy never validates or applies a row filter")
    func structureOnlyIgnoresRowFilter() {
        var options = DuplicateOptions()
        options.rowFilter = "status = 'paid'"
        let request = DuplicateFixtures.request(mode: .structureOnly, options: options)
        let kinds = plan(DuplicateFixtures.serialTable, request: request).statements.map(\.kind)
        #expect(!kinds.contains(.validateRowFilter))
        #expect(!kinds.contains(.copyData))
    }

    @Test("A blank row filter is treated as absent")
    func blankRowFilterIsIgnored() {
        var options = DuplicateOptions()
        options.rowFilter = "   "
        let result = plan(DuplicateFixtures.serialTable, request: DuplicateFixtures.request(options: options))
        #expect(sql(result, .validateRowFilter).isEmpty)
        #expect(sql(result, .copyData).first?.contains("WHERE") == false)
    }

    @Test("A limit orders by the primary key so the subset is deterministic")
    func limitOrdersByPrimaryKey() {
        var options = DuplicateOptions()
        options.limit = 100
        let copy = sql(plan(DuplicateFixtures.serialTable, request: DuplicateFixtures.request(options: options)),
                       .copyData).first ?? ""
        #expect(copy.contains("ORDER BY \"id\""))
        #expect(copy.hasSuffix("LIMIT 100"))
    }

    @Test("No limit means no ORDER BY, so the server picks the cheapest plan")
    func noLimitMeansNoOrderBy() {
        let copy = sql(plan(DuplicateFixtures.serialTable), .copyData).first ?? ""
        #expect(!copy.contains("ORDER BY"))
        #expect(!copy.contains("LIMIT"))
    }

    // MARK: - Foreign keys

    @Test("Foreign keys are off by default")
    func foreignKeysOffByDefault() {
        let kinds = plan(DuplicateFixtures.selfReferencingTable).statements.map(\.kind)
        #expect(!kinds.contains(.addForeignKey))
    }

    /// A self-referencing key copied verbatim would tie the new table to the original.
    @Test("A self-referencing foreign key points at the copy and is added after the data")
    func selfReferencingForeignKeyPointsAtCopy() {
        var options = DuplicateOptions()
        options.foreignKeys = true
        let result = plan(DuplicateFixtures.selfReferencingTable,
                          request: DuplicateFixtures.request(options: options))
        let statement = sql(result, .addForeignKey).first ?? ""
        #expect(statement.contains("REFERENCES \"public\".\"orders_copy\" (\"id\")"))
        #expect(!statement.contains("REFERENCES \"public\".\"orders\" "))
        #expect(statement.contains("ON DELETE CASCADE"))
        #expect(!statement.contains("ON UPDATE"))

        let kinds = result.statements.map(\.kind)
        #expect(precedes(kinds, .copyData, .addForeignKey))
    }

    /// The PostgreSQL driver emits one row per column for a composite key, so the grouping has to
    /// reassemble them in order rather than treating each row as its own constraint.
    @Test("A composite foreign key emitted as one row per column becomes a single constraint")
    func compositeForeignKeyIsReassembled() {
        var options = DuplicateOptions()
        options.foreignKeys = true
        let result = plan(
            DuplicateFixtures.compositeForeignKeyTable,
            request: DuplicateFixtures.request(options: options)
        )
        let statements = sql(result, .addForeignKey)
        #expect(statements.count == 1)
        #expect(statements.first == """
        ALTER TABLE "public"."orders_copy" ADD FOREIGN KEY ("tenant_id", "order_no") \
        REFERENCES "public"."customers" ("tenant_id", "order_no")
        """)
        #expect(result.warnings.isEmpty)
    }

    @Test("A foreign key whose columns do not pair up is reported, not silently dropped")
    func unpairedForeignKeyWarns() {
        let broken = PluginForeignKeyInfo(
            name: "broken_fkey",
            localColumns: ["a", "b"],
            referencedTable: "orders",
            referencedColumns: ["id"],
            referencedSchema: "public"
        )
        let result = DuplicateForeignKeyGrouping.grouped([broken])
        #expect(result.keys.isEmpty)
        #expect(result.warnings == [DuplicateWarning.foreignKeyNotCarried("broken_fkey")])
    }

    // MARK: - Warnings

    @Test("A partitioned table is blocked and produces no statements")
    func partitionedTableIsBlocked() {
        let result = plan(DuplicateFixtures.partitionedTable)
        #expect(result.statements.isEmpty)
        #expect(result.isBlocked)
        #expect(result.warnings == [.partitionedTableNotSupported("orders")])
    }

    @Test("An owned row-level-security table warns once")
    func rowLevelSecurityOwnerWarnsOnce() {
        let result = plan(DuplicateFixtures.rowLevelSecurityOwnedTable)
        #expect(result.warnings == [.rowLevelSecurityPoliciesNotCopied])
        #expect(!result.isBlocked)
    }

    /// A non-owner reading through row-level security may see fewer rows than exist, so the copy
    /// can be silently incomplete. That is a second, distinct warning.
    @Test("A row-level-security table the user does not own warns twice")
    func rowLevelSecurityNonOwnerWarnsTwice() {
        let result = plan(DuplicateFixtures.rowLevelSecurityForeignTable)
        #expect(result.warnings == [.rowLevelSecurityPoliciesNotCopied, .rowLevelSecurityMayHideRows])
    }

    @Test("A table with nothing unusual produces no warnings")
    func plainTableHasNoWarnings() {
        #expect(plan(DuplicateFixtures.serialTable).warnings.isEmpty)
    }

    // MARK: - Tablespace and analyze

    @Test("Nothing generated mentions TABLESPACE, which this feature does not copy")
    func tablespaceIsNeverEmitted() {
        let generated = plan(DuplicateFixtures.serialTable).statements
            .compactMap { statement -> String? in
                guard case .sql(let text) = statement.body else { return nil }
                return text
            }
            .joined(separator: "\n")
        #expect(!generated.uppercased().contains("TABLESPACE"))
    }

    @Test("The plan ends with ANALYZE and carries the row estimate")
    func planEndsWithAnalyze() {
        let result = plan(DuplicateFixtures.serialTable)
        #expect(result.statements.last?.kind == .analyze)
        #expect(sql(result, .analyze).first == "ANALYZE \"public\".\"orders_copy\"")
        #expect(result.estimatedRowCount == 42)
    }

    @Test("An empty source table plans exactly like a populated one")
    func emptyTablePlansNormally() {
        let result = plan(DuplicateFixtures.emptyTable)
        #expect(result.statements.map(\.kind).contains(.copyData))
        #expect(result.estimatedRowCount == 0)
        #expect(result.warnings.isEmpty)
    }

    // MARK: - Schema handling

    @Test("A copy into another schema qualifies the target with that schema")
    func targetSchemaIsHonoured() {
        let request = DuplicateFixtures.request(targetSchema: "staging")
        let create = sql(plan(DuplicateFixtures.serialTable, request: request), .createTable).first ?? ""
        #expect(create.contains("CREATE TABLE \"staging\".\"orders_copy\""))
        #expect(create.contains("LIKE \"public\".\"orders\""))
    }

    @Test("A nil schema leaves the name unqualified")
    func nilSchemaIsUnqualified() {
        let request = DuplicateFixtures.request(
            source: DuplicateTableRef(schema: nil, name: "orders"),
            targetSchema: nil
        )
        let create = sql(plan(DuplicateFixtures.serialTable, request: request), .createTable).first ?? ""
        #expect(create.contains("CREATE TABLE \"orders_copy\" (LIKE \"orders\""))
    }
}
