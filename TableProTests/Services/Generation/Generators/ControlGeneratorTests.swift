//
//  ControlGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Control generators")
struct ControlGeneratorTests {
    private let row = GeneratorTestFixtures.rowContext()

    private func take(_ generator: any ValueGenerator, _ count: Int) throws -> [PluginCellValue] {
        try (0..<count).map { try generator.next(row: row, index: $0) }
    }

    @Test("AutoIncrement walks from its start by its step")
    func autoIncrementWalks() throws {
        let generator = try AutoIncrementGenerator(
            params: GeneratorTestFixtures.params(#"{"start":100,"step":5}"#),
            column: GeneratorTestFixtures.column(dataType: "bigint"),
            seed: 1
        )
        #expect(try take(generator, 4) == [.int(100), .int(105), .int(110), .int(115)])
        generator.reset()
        #expect(try take(generator, 1) == [.int(100)])
    }

    @Test("AutoIncrement rejects a zero step")
    func autoIncrementRejectsZeroStep() {
        #expect(throws: GenerationError.self) {
            _ = try AutoIncrementGenerator(
                params: GeneratorTestFixtures.params(#"{"step":0}"#),
                column: GeneratorTestFixtures.column(dataType: "bigint"),
                seed: 1
            )
        }
    }

    @Test("Fixed emits the same value coerced to the column type")
    func fixedCoercesToColumnType() throws {
        let onText = try FixedGenerator(
            params: GeneratorTestFixtures.params(#"{"value":"42"}"#),
            column: GeneratorTestFixtures.column(dataType: "text"),
            seed: 1
        )
        #expect(try take(onText, 2) == [.text("42"), .text("42")])

        let onInt = try FixedGenerator(
            params: GeneratorTestFixtures.params(#"{"value":"42"}"#),
            column: GeneratorTestFixtures.column(dataType: "integer"),
            seed: 1
        )
        #expect(try take(onInt, 1) == [.int(42)])

        let onNumeric = try FixedGenerator(
            params: GeneratorTestFixtures.params(#"{"value":"1.25"}"#),
            column: GeneratorTestFixtures.column(dataType: "numeric(10,2)"),
            seed: 1
        )
        #expect(try take(onNumeric, 1) == [.decimalText("1.25")])
    }

    @Test("List picks from its values and falls back to the column's enum members")
    func listUsesValuesOrEnumMembers() throws {
        let explicit = try ListGenerator(
            params: GeneratorTestFixtures.params(#"{"values":["a","b"]}"#),
            column: GeneratorTestFixtures.column(),
            seed: 4
        )
        #expect(try take(explicit, 50).allSatisfy { $0 == .text("a") || $0 == .text("b") })

        let fromEnum = try ListGenerator(
            params: Data(),
            column: GeneratorTestFixtures.column(
                dataType: "enum('new','paid')",
                databaseType: .mysql,
                allowedValues: ["new", "paid"]
            ),
            seed: 4
        )
        #expect(try take(fromEnum, 20).allSatisfy { $0 == .text("new") || $0 == .text("paid") })
    }

    @Test("List in sequential mode cycles in order")
    func listSequentialCycles() throws {
        let generator = try ListGenerator(
            params: GeneratorTestFixtures.params(#"{"values":["a","b","c"],"mode":"sequential"}"#),
            column: GeneratorTestFixtures.column(),
            seed: 4
        )
        #expect(try take(generator, 5) == [.text("a"), .text("b"), .text("c"), .text("a"), .text("b")])
    }

    @Test("List weights are honoured with integer arithmetic")
    func listWeightsAreHonoured() throws {
        let generator = try ListGenerator(
            params: GeneratorTestFixtures.params(#"{"values":["rare","common"],"weights":[1,9]}"#),
            column: GeneratorTestFixtures.column(),
            seed: 4
        )
        let values = try take(generator, 10_000)
        let rare = values.filter { $0 == .text("rare") }.count
        #expect(rare > 800)
        #expect(rare < 1_200)
    }

    @Test("List rejects a zero weight everywhere and a mismatched weight count")
    func listRejectsBadWeights() {
        #expect(throws: GenerationError.self) {
            _ = try ListGenerator(
                params: GeneratorTestFixtures.params(#"{"values":["a","b"],"weights":[1]}"#),
                column: GeneratorTestFixtures.column(),
                seed: 1
            )
        }
        #expect(throws: GenerationError.self) {
            _ = try ListGenerator(
                params: GeneratorTestFixtures.params(#"{"values":["a","b"],"weights":[0,0]}"#),
                column: GeneratorTestFixtures.column(),
                seed: 1
            )
        }
    }

    @Test("List rejects an empty value list rather than emitting nothing")
    func listRejectsEmptyValues() {
        #expect(throws: GenerationError.self) {
            _ = try ListGenerator(params: Data(), column: GeneratorTestFixtures.column(), seed: 1)
        }
    }

    @Test("A list value is coerced to the column type")
    func listCoercesToColumnType() throws {
        let generator = try ListGenerator(
            params: GeneratorTestFixtures.params(#"{"values":["10","20"],"mode":"sequential"}"#),
            column: GeneratorTestFixtures.column(dataType: "integer"),
            seed: 1
        )
        #expect(try take(generator, 2) == [.int(10), .int(20)])
    }

    @Test("Null always emits null and Default emits null while leaving the column out")
    func nullAndDefault() throws {
        let null = try NullGenerator(params: Data(), column: GeneratorTestFixtures.column(), seed: 1)
        #expect(try take(null, 3).allSatisfy(\.isNull))
        #expect(!NullGenerator.excludesColumnFromInsert)

        let fallback = try DefaultGenerator(params: Data(), column: GeneratorTestFixtures.column(), seed: 1)
        #expect(try take(fallback, 3).allSatisfy(\.isNull))
        #expect(DefaultGenerator.excludesColumnFromInsert)
        #expect(AutoIncrementGenerator.excludesColumnFromInsert)
    }

    @Test("Copy returns the value already in the row")
    func copyReadsTheRow() throws {
        let generator = try CopyGenerator(
            params: GeneratorTestFixtures.params(#"{"sourceColumn":"other"}"#),
            column: GeneratorTestFixtures.column(),
            seed: 1
        )
        #expect(try generator.next(row: row, index: 0) == .text("copied"))
        #expect(generator.rowDependencies == ["other"])
    }

    @Test("Copy throws when its source has not been generated yet")
    func copyThrowsOnMissingSource() throws {
        let generator = try CopyGenerator(
            params: GeneratorTestFixtures.params(#"{"sourceColumn":"absent"}"#),
            column: GeneratorTestFixtures.column(name: "target"),
            seed: 1
        )
        #expect(throws: GenerationError.dependencyMissing(column: "target", dependsOn: "absent")) {
            try generator.next(row: row, index: 0)
        }
    }

    @Test("Copy refuses to name itself or nothing")
    func copyRejectsBadSources() {
        #expect(throws: GenerationError.self) {
            _ = try CopyGenerator(params: Data(), column: GeneratorTestFixtures.column(), seed: 1)
        }
        #expect(throws: GenerationError.self) {
            _ = try CopyGenerator(
                params: GeneratorTestFixtures.params(#"{"sourceColumn":"value"}"#),
                column: GeneratorTestFixtures.column(name: "value"),
                seed: 1
            )
        }
    }

    @Test("Reference takes its parent from the column's foreign key when unset")
    func referenceInfersItsTarget() throws {
        let column = GeneratorTestFixtures.column(
            name: "customer_id",
            dataType: "bigint",
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "fk",
                    column: "customer_id",
                    referencedTable: "customers",
                    referencedColumn: "id",
                    referencedSchema: "public"
                )
            ]
        )
        let generator = try ReferenceGenerator(params: Data(), column: column, seed: 1)
        #expect(generator.referenceTarget == ReferenceTarget(schema: "public", table: "customers", column: "id"))
    }

    @Test("Reference throws until its pool is bound, then draws only pool values")
    func referenceNeedsItsPool() throws {
        let generator = try ReferenceGenerator(
            params: GeneratorTestFixtures.params(#"{"table":"parent","column":"id"}"#),
            column: GeneratorTestFixtures.column(name: "parent_id", dataType: "bigint"),
            seed: 1
        )
        #expect(throws: GenerationError.self) {
            try generator.next(row: row, index: 0)
        }
        generator.bind(
            pool: ReferenceValuePool(target: generator.referenceTarget, values: [.int(1), .int(2)])
        )
        #expect(try take(generator, 50).allSatisfy { $0 == .int(1) || $0 == .int(2) })
    }

    @Test("Reference in sequential mode walks the pool in order and wraps")
    func referenceSequentialWraps() throws {
        let generator = try ReferenceGenerator(
            params: GeneratorTestFixtures.params(#"{"table":"parent","column":"id","strategy":"sequential"}"#),
            column: GeneratorTestFixtures.column(name: "parent_id", dataType: "bigint"),
            seed: 1
        )
        generator.bind(
            pool: ReferenceValuePool(target: generator.referenceTarget, values: [.int(7), .int(8)])
        )
        #expect(try take(generator, 4) == [.int(7), .int(8), .int(7), .int(8)])
    }

    @Test("Reference refuses to be built without a parent to draw from")
    func referenceRejectsMissingTarget() {
        #expect(throws: GenerationError.self) {
            _ = try ReferenceGenerator(params: Data(), column: GeneratorTestFixtures.column(), seed: 1)
        }
    }
}
