//
//  AddressCardinalityTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Address cardinality and redraw")
struct AddressCardinalityTests {
    private static let registry = GeneratorRegistry.standard

    private func make(_ identifier: String, params: String, dataType: String) throws -> any ValueGenerator {
        try Self.registry.make(
            identifier: identifier,
            params: Data(params.utf8),
            column: GeneratorTestFixtures.column(dataType: dataType),
            seed: 17
        )
    }

    @Test("A house number in a narrow text column reports only what it can produce")
    func buildingNumberRespectsTheColumnWidth() throws {
        let narrow = try make(BuildingNumberGenerator.identifier, params: #"{"min":1,"max":500}"#, dataType: "varchar(1)")
        let claimed = try #require(narrow.distinctValueCount)
        var produced: Set<String> = []
        let truncator = GenerationStringTruncator(unit: .unicodeScalars)
        for index in 0..<5_000 {
            let value = try narrow.next(row: GeneratorTestFixtures.rowContext(rowIndex: index), index: index)
            guard case let .text(text) = value else { continue }
            produced.insert(truncator.truncate(text, to: 1))
        }
        #expect(
            claimed >= produced.count,
            "claims \(claimed) values but a varchar(1) column only holds \(produced.count)"
        )
        #expect(claimed <= 10)
    }

    @Test("A house number in an integer column keeps the whole range")
    func buildingNumberInAnIntegerColumnKeepsItsRange() throws {
        let numeric = try make(BuildingNumberGenerator.identifier, params: #"{"min":1,"max":500}"#, dataType: "integer")
        #expect(numeric.distinctValueCount == 500)
    }

    @Test("Alley numbers combine two draws, so the range is not the domain")
    func alleyNumbersReportNoCount() throws {
        let alleys = try make(
            BuildingNumberGenerator.identifier,
            params: #"{"min":1,"max":500,"alleyPercent":100}"#,
            dataType: "varchar(32)"
        )
        #expect(alleys.distinctValueCount == nil)
    }

    /// A locality column is a pure function of the row index, so redrawing it to
    /// settle a composite collision returns the identical value every time. If it
    /// is treated as redrawable the run burns the whole retry budget and throws
    /// `uniqueExhausted` even though the sibling column had room left.
    @Test("A composite unique over a locality column redraws the sibling instead")
    func compositeUniqueRedrawsTheSiblingOfALocalityColumn() throws {
        let unconstrained = try Self.statePairPlan(rowCount: 400, constrained: false)
        let loose = try RowBuilder(
            plan: unconstrained,
            truncator: GenerationStringTruncator(unit: .unicodeScalars),
            registry: .standard,
            runSeed: 99,
            compositeRetryBudget: 16
        )
        var natural: Set<String> = []
        for index in 0..<400 {
            natural.insert(try loose.buildRow(index: index).map(\.textFallback).joined(separator: "|"))
        }
        #expect(
            natural.count < 400,
            "the fixture never collides, so it proves nothing about redrawing"
        )

        let plan = try Self.statePairPlan(rowCount: 400)
        let builder = try RowBuilder(
            plan: plan,
            truncator: GenerationStringTruncator(unit: .unicodeScalars),
            registry: .standard,
            runSeed: 99,
            compositeRetryBudget: 16
        )
        var pairs: Set<String> = []
        for index in 0..<400 {
            let row = try builder.buildRow(index: index)
            pairs.insert(row.map(\.textFallback).joined(separator: "|"))
        }
        #expect(pairs.count == 400)
    }

    /// `StateCode` holds 36 values against the slot column's 30, so the redraw
    /// rule picks the state unless locality columns are excluded. 150 rows over
    /// 1080 possible pairs makes collisions a certainty, while leaving every
    /// state far more free slots than the rows that land on it.
    private static func statePairPlan(rowCount: Int, constrained: Bool = true) throws -> TablePlan {
        let table = GenerationPlanningFixtures.table(
            "visits",
            columns: [
                PluginColumnInfo(name: "state_code", dataType: "varchar(8)", isNullable: false),
                PluginColumnInfo(name: "slot", dataType: "integer", isNullable: false)
            ]
        )
        let stateCode = try #require(table.column(named: "state_code"))
        let slot = try #require(table.column(named: "slot"))
        let slotParams = JSONValue.object(["min": .int(1), "max": .int(30)])
        return TablePlan(
            reference: GenerationTableReference(schema: "public", table: "visits"),
            rowCount: rowCount,
            emptyFirst: false,
            columns: [
                ColumnPlan(
                    column: stateCode,
                    generator: StateCodeField.identifier,
                    params: Data(#"{"locale":"en_US"}"#.utf8),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                ),
                ColumnPlan(
                    column: slot,
                    generator: "Integer",
                    params: Data(slotParams.jsonText?.utf8 ?? "{}".utf8),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                )
            ],
            insertColumns: ["state_code", "slot"],
            deferredColumns: [],
            uniqueConstraints: constrained
                ? [GenerationUniqueConstraint(name: "uq_visits", columns: ["state_code", "slot"])]
                : [],
            primaryKeyColumns: [],
            sequenceBackedColumns: []
        )
    }
}
