//
//  DuplicatePlanPreviewTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("DuplicatePlanPreview")
struct DuplicatePlanPreviewTests {
    private let builder = PostgreSqlDuplicatePlanBuilder()

    private func script(
        request: DuplicateTableRequest,
        introspection: DuplicateTableIntrospection
    ) -> String {
        let plan = builder.plan(
            request: request,
            introspection: introspection,
            quoting: DuplicateFixtures.quoting
        )
        return DuplicatePlanPreview.script(
            plan: plan,
            harvestedIndexCount: DuplicatePlanPreview.estimatedHarvestedIndexCount(introspection.indexes)
        )
    }

    @Test("A plain SQL statement is rendered verbatim")
    func sqlIsVerbatim() {
        let rendered = script(
            request: DuplicateFixtures.request(mode: .structureOnly),
            introspection: DuplicateFixtures.serialTable
        )
        #expect(rendered.contains("CREATE TABLE \"public\".\"orders_copy\" (LIKE \"public\".\"orders\""))
        #expect(rendered.contains("ANALYZE \"public\".\"orders_copy\";"))
    }

    /// The names come from the server once the new table exists, so the block says how many
    /// statements it stands for instead of inventing them.
    @Test("A deferred block is labelled with the index count")
    func deferredBlockIsLabelled() {
        let rendered = script(
            request: DuplicateFixtures.request(mode: .structureAndData),
            introspection: DuplicateFixtures.threeIndexTable
        )
        #expect(rendered.contains("-- Generated when this runs: DROP INDEX for the 3 index(es)"))
        #expect(rendered.contains("-- Generated when this runs: 3 index(es) recreated"))
    }

    @Test("A structure-only plan carries no deferred block")
    func structureOnlyHasNoDeferredBlock() {
        let rendered = script(
            request: DuplicateFixtures.request(mode: .structureOnly),
            introspection: DuplicateFixtures.threeIndexTable
        )
        #expect(!rendered.contains("Generated when this runs"))
    }

    @Test("Every statement in the plan reaches the script")
    func everyStatementIsRendered() {
        let request = DuplicateFixtures.request(mode: .structureAndData)
        let plan = builder.plan(
            request: request,
            introspection: DuplicateFixtures.threeIndexTable,
            quoting: DuplicateFixtures.quoting
        )
        let rendered = DuplicatePlanPreview.script(plan: plan, harvestedIndexCount: 3)
        #expect(rendered.components(separatedBy: "\n\n").count == plan.statements.count)
    }

    @Test("Constraint-backed indexes are left out of the count")
    func countSkipsConstraintIndexes() {
        let indexes = [
            PluginIndexInfo(name: "orders_pkey", columns: ["id"], isUnique: true, isPrimary: true),
            PluginIndexInfo(name: "orders_email_key", columns: ["email"], isUnique: true),
            PluginIndexInfo(name: "idx_orders_total", columns: ["total"])
        ]
        #expect(DuplicatePlanPreview.estimatedHarvestedIndexCount(indexes) == 1)
    }
}
