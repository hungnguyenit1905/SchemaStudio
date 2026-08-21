//
//  CompositeUniqueTrackerTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("CompositeUniqueTracker")
struct CompositeUniqueTrackerTests {
    private func tracker(columns: [String] = ["a", "b"], redraw: String = "b") -> CompositeUniqueTracker {
        CompositeUniqueTracker(
            constraints: [
                CompositeUniqueTracker.Constraint(name: "uq", columns: columns, redrawColumn: redraw)
            ]
        )
    }

    @Test("A repeated column is fine as long as the pair differs")
    func repeatedColumnWithDifferentPartner() {
        var tracked = tracker()
        let first: [String: PluginCellValue] = ["a": .int(1), "b": .text("x")]
        let second: [String: PluginCellValue] = ["a": .int(1), "b": .text("y")]
        #expect(tracked.collision(in: first) == nil)
        tracked.record(first)
        #expect(tracked.collision(in: second) == nil)
        tracked.record(second)
        #expect(tracked.collision(in: first) != nil)
    }

    @Test("A repeated pair collides on the constraint that owns it")
    func repeatedPairCollides() throws {
        var tracked = tracker()
        let row: [String: PluginCellValue] = ["a": .int(1), "b": .text("x")]
        tracked.record(row)
        let collision = try #require(tracked.collision(in: row))
        #expect(collision.name == "uq")
        #expect(collision.columns == ["a", "b"])
    }

    @Test("A row that collided leaves nothing behind")
    func rejectedRowIsNotRecorded() {
        var tracked = tracker()
        let row: [String: PluginCellValue] = ["a": .int(1), "b": .text("x")]
        #expect(tracked.collision(in: row) == nil)
        #expect(tracked.collision(in: row) == nil)
    }

    @Test("Resetting forgets every constraint")
    func resetForgets() {
        var tracked = tracker()
        let row: [String: PluginCellValue] = ["a": .int(1), "b": .text("x")]
        tracked.record(row)
        tracked.reset()
        #expect(tracked.collision(in: row) == nil)
    }

    @Test("A pair carrying a null is never a collision, because the server never rejects it")
    func nullMemberIsNotTracked() {
        var tracked = tracker()
        let withNull: [String: PluginCellValue] = ["a": .int(1), "b": .null]
        tracked.record(withNull)
        #expect(tracked.collision(in: withNull) == nil)
        tracked.record(withNull)
        #expect(tracked.collision(in: withNull) == nil)

        let withoutNull: [String: PluginCellValue] = ["a": .int(1), "b": .text("x")]
        tracked.record(withoutNull)
        #expect(tracked.collision(in: withoutNull) != nil)
    }

    @Test("A missing column reads as null and is left alone too")
    func missingColumnIsNotTracked() {
        var tracked = tracker()
        let partial: [String: PluginCellValue] = ["a": .int(1)]
        tracked.record(partial)
        #expect(tracked.collision(in: partial) == nil)
    }

    @Test("The column with the most values to offer is the one redrawn")
    func widestColumnIsRedrawn() throws {
        let plan = try CompositeFixtures.plan(
            columns: [("status", "List", 3), ("serial", "RandomString", 1_000_000)],
            constraintColumns: ["status", "serial"]
        )
        let constraints = CompositeUniqueTracker.constraints(
            for: plan,
            redrawable: { _ in true },
            cardinality: { name in name == "status" ? 3 : 1_000_000 }
        )
        let constraint = try #require(constraints.first)
        #expect(constraint.redrawColumn == "serial")
    }

    @Test("An unbounded column outranks a counted one")
    func unboundedColumnIsWidest() throws {
        let plan = try CompositeFixtures.plan(
            columns: [("status", "List", 3), ("note", "LoremWords", nil)],
            constraintColumns: ["status", "note"]
        )
        let constraints = CompositeUniqueTracker.constraints(
            for: plan,
            redrawable: { _ in true },
            cardinality: { name in name == "status" ? 3 : nil }
        )
        #expect(constraints.first?.redrawColumn == "note")
    }

    @Test("A constraint with nothing redrawable in it is not tracked")
    func untouchableConstraintIsDropped() throws {
        let plan = try CompositeFixtures.plan(
            columns: [("status", "List", 3), ("serial", "RandomString", 100)],
            constraintColumns: ["status", "serial"]
        )
        let constraints = CompositeUniqueTracker.constraints(
            for: plan,
            redrawable: { _ in false },
            cardinality: { _ in 100 }
        )
        #expect(constraints.isEmpty)
    }

    @Test("Under a case-insensitive collation the pair is compared the way the server compares it")
    func caseInsensitiveMemberCollides() {
        var tracked = CompositeUniqueTracker(
            constraints: [
                CompositeUniqueTracker.Constraint(
                    name: "uq",
                    columns: ["region", "label"],
                    redrawColumn: "label",
                    matching: ["region": .exact, "label": .caseInsensitive]
                )
            ]
        )
        let first: [String: PluginCellValue] = ["region": .text("VN"), "label": .text("Alpha")]
        let sameLowered: [String: PluginCellValue] = ["region": .text("VN"), "label": .text("alpha")]
        let otherRegion: [String: PluginCellValue] = ["region": .text("SG"), "label": .text("alpha")]
        tracked.record(first)
        #expect(tracked.collision(in: sameLowered) != nil)
        #expect(tracked.collision(in: otherRegion) == nil)
    }

    @Test("A collation the plan carries reaches the constraint")
    func collationReachesTheConstraint() throws {
        let table = GenerationPlanningFixtures.table(
            "tickets",
            columns: [
                PluginColumnInfo(name: "region", dataType: "varchar(2)", isNullable: false),
                PluginColumnInfo(
                    name: "label",
                    dataType: "varchar(32)",
                    isNullable: false,
                    collation: "utf8mb4_general_ci"
                )
            ],
            databaseType: .mysql
        )
        let region = try #require(table.column(named: "region"))
        let label = try #require(table.column(named: "label"))
        let plan = TablePlan(
            reference: GenerationTableReference(schema: nil, table: "tickets"),
            rowCount: 10,
            emptyFirst: false,
            columns: [region, label].map { column in
                ColumnPlan(
                    column: column,
                    generator: "RandomString",
                    params: Data(),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                )
            },
            insertColumns: ["region", "label"],
            deferredColumns: [],
            uniqueConstraints: [
                GenerationUniqueConstraint(name: "tickets_region_label_key", columns: ["region", "label"])
            ],
            primaryKeyColumns: [],
            sequenceBackedColumns: []
        )
        let constraint = try #require(
            CompositeUniqueTracker.constraints(for: plan, redrawable: { _ in true }, cardinality: { _ in nil }).first
        )
        #expect(constraint.matching["label"] == .caseInsensitive)
        #expect(constraint.matching["region"] == .exact)
    }

    @Test("A single-column constraint is left to the column's own tracking")
    func singleColumnConstraintIsIgnored() throws {
        let plan = try CompositeFixtures.plan(
            columns: [("status", "List", 3), ("serial", "RandomString", 100)],
            constraintColumns: ["serial"]
        )
        let constraints = CompositeUniqueTracker.constraints(
            for: plan,
            redrawable: { _ in true },
            cardinality: { _ in 100 }
        )
        #expect(constraints.isEmpty)
    }
}

@Suite("RowBuilder composite uniqueness")
struct RowBuilderCompositeUniquenessTests {
    @Test("Rows keep the pair distinct by redrawing the wider column")
    func rowsStayDistinct() throws {
        let plan = try CompositeFixtures.pairPlan(rowCount: 40)
        let builder = try RowBuilder(
            plan: plan,
            truncator: GenerationStringTruncator(unit: .unicodeScalars),
            registry: .standard,
            runSeed: 5
        )
        var pairs: Set<String> = []
        for index in 0 ..< 40 {
            let row = try builder.buildRow(index: index)
            pairs.insert(row.map(\.textFallback).joined(separator: "|"))
        }
        #expect(pairs.count == 40)
    }

    @Test("A pair with nowhere left to go fails instead of spinning")
    func exhaustedPairFails() throws {
        let plan = try CompositeFixtures.pairPlan(rowCount: 12, statusValues: ["a", "b"], serialDomain: 3)
        let builder = try RowBuilder(
            plan: plan,
            truncator: GenerationStringTruncator(unit: .unicodeScalars),
            registry: .standard,
            runSeed: 5,
            compositeRetryBudget: 8
        )
        #expect(throws: GenerationError.self) {
            for index in 0 ..< 12 {
                _ = try builder.buildRow(index: index)
            }
        }
    }
}

enum CompositeFixtures {
    static func plan(
        columns: [(String, String, Int?)],
        constraintColumns: [String],
        rowCount: Int = 10
    ) throws -> TablePlan {
        let infos = columns.map { name, _, _ in
            PluginColumnInfo(name: name, dataType: "varchar(64)", isNullable: false)
        }
        let table = GenerationPlanningFixtures.table("t", columns: infos)
        let columnPlans = try columns.map { name, generator, _ -> ColumnPlan in
            let column = try #require(table.column(named: name))
            return ColumnPlan(
                column: column,
                generator: generator,
                params: Data(),
                common: .none,
                excludedFromInsert: false,
                dependencies: []
            )
        }
        return TablePlan(
            reference: GenerationTableReference(schema: "public", table: "t"),
            rowCount: rowCount,
            emptyFirst: false,
            columns: columnPlans,
            insertColumns: columns.map(\.0),
            deferredColumns: [],
            uniqueConstraints: [
                GenerationUniqueConstraint(name: "uq", columns: constraintColumns)
            ],
            primaryKeyColumns: [],
            sequenceBackedColumns: []
        )
    }

    /// A low-cardinality status paired with a wider serial, which is the shape the
    /// redraw rule exists for.
    static func pairPlan(
        rowCount: Int,
        statusValues: [String] = ["new", "paid", "shipped"],
        serialDomain: Int = 1_000
    ) throws -> TablePlan {
        let table = GenerationPlanningFixtures.table(
            "orders",
            columns: [
                PluginColumnInfo(name: "status", dataType: "varchar(16)", isNullable: false),
                PluginColumnInfo(name: "serial", dataType: "integer", isNullable: false)
            ]
        )
        let status = try #require(table.column(named: "status"))
        let serial = try #require(table.column(named: "serial"))
        let statusParams = JSONValue.object(["values": .array(statusValues.map(JSONValue.string))])
        let serialParams = JSONValue.object(["min": .int(1), "max": .int(serialDomain)])
        return TablePlan(
            reference: GenerationTableReference(schema: "public", table: "orders"),
            rowCount: rowCount,
            emptyFirst: false,
            columns: [
                ColumnPlan(
                    column: status,
                    generator: "List",
                    params: Data(statusParams.jsonText?.utf8 ?? "{}".utf8),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                ),
                ColumnPlan(
                    column: serial,
                    generator: "Integer",
                    params: Data(serialParams.jsonText?.utf8 ?? "{}".utf8),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                )
            ],
            insertColumns: ["status", "serial"],
            deferredColumns: [],
            uniqueConstraints: [
                GenerationUniqueConstraint(name: "orders_status_serial_key", columns: ["status", "serial"])
            ],
            primaryKeyColumns: [],
            sequenceBackedColumns: []
        )
    }
}
