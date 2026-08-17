//
//  GeneratorHardeningTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// Every case here is a defect a review found in the first cut of the catalog.
@Suite("Generator hardening")
struct GeneratorHardeningTests {
    private let row = GeneratorTestFixtures.rowContext()

    private func take(_ generator: any ValueGenerator, _ count: Int) throws -> [PluginCellValue] {
        try (0..<count).map { try generator.next(row: row, index: $0) }
    }

    private func take(_ generator: DecoratedGenerator, _ count: Int) throws -> [PluginCellValue] {
        try (0..<count).map { try generator.next(row: row, index: $0) }
    }

    @Test("A JSON number too large for Int64 does not trap on an integer column")
    func hugeNumberOnIntegerColumnDoesNotTrap() throws {
        let generator = try FixedGenerator(
            params: GeneratorTestFixtures.params(#"{"value":1e30}"#),
            column: GeneratorTestFixtures.column(dataType: "bigint"),
            seed: 1
        )
        let value = try take(generator, 1)[0]
        guard case .decimalText(let text) = value else {
            Issue.record("expected the out-of-range value to fall back to decimal text, got \(value)")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test("A representable JSON double still lands as an integer")
    func representableNumberStaysAnInteger() throws {
        let generator = try FixedGenerator(
            params: GeneratorTestFixtures.params(#"{"value":42.0}"#),
            column: GeneratorTestFixtures.column(dataType: "bigint"),
            seed: 1
        )
        #expect(try take(generator, 1) == [.int(42)])
    }

    @Test("A JSON object value survives as JSON text instead of an empty string")
    func objectValueIsSerialized() throws {
        let generator = try FixedGenerator(
            params: GeneratorTestFixtures.params(#"{"value":{"a":1,"b":"two"}}"#),
            column: GeneratorTestFixtures.column(dataType: "jsonb"),
            seed: 1
        )
        let text = try #require(try take(generator, 1)[0].asText)
        #expect(text == #"{"a":1,"b":"two"}"#)
    }

    @Test("A large decimal is written in fixed point, never scientific notation")
    func decimalNeverUsesScientificNotation() {
        #expect(GenerationValueMapper.fixedPointText(1e20) == "100000000000000000000")
        #expect(GenerationValueMapper.fixedPointText(1.25) == "1.25")
        #expect(GenerationValueMapper.fixedPointText(-0.5) == "-0.5")
        #expect(GenerationValueMapper.fixedPointText(0) == "0")
        #expect(!GenerationValueMapper.fixedPointText(1e20).contains("e"))
    }

    @Test("A non-finite decimal is rejected rather than sent to the server")
    func nonFiniteDecimalIsRejected() {
        #expect(GenerationValueMapper.value(from: "nan", base: .decimal) == .text("nan"))
        #expect(GenerationValueMapper.value(from: "inf", base: .decimal) == .text("inf"))
        #expect(GenerationValueMapper.value(from: "1.25", base: .decimal) == .decimalText("1.25"))
    }

    @Test("A timestamp with a negative UTC offset keeps its offset")
    func negativeOffsetIsHonoured() {
        #expect(DateTimeGenerator.epochSeconds("2024-03-01T12:00:00-05:00") == 1_709_312_400)
        #expect(DateTimeGenerator.epochSeconds("2024-03-01T12:00:00+05:00") == 1_709_276_400)
        #expect(DateTimeGenerator.epochSeconds("2024-03-01T12:00:00Z") == 1_709_294_400)
        #expect(DateTimeGenerator.epochSeconds("2024-03-01 12:00:00") == 1_709_294_400)
        #expect(DateTimeGenerator.epochSeconds("2024-03-01 12:00:00 +0000") == 1_709_294_400)
    }

    @Test("A date with no time still reads as midnight UTC")
    func dateOnlyStillParses() {
        #expect(DateTimeGenerator.epochSeconds("2024-03-01") == 1_709_251_200)
    }

    @Test("An unparseable timestamp fails instead of silently becoming midnight")
    func unparseableTimestampFails() {
        #expect(DateTimeGenerator.epochSeconds("2024-03-01T25:99:99Z") == nil)
        #expect(DateTimeGenerator.epochSeconds("nonsense") == nil)
        #expect(throws: GenerationError.self) {
            _ = try DateTimeGenerator(
                params: GeneratorTestFixtures.params(#"{"from":"2024-03-01T25:99:99Z"}"#),
                column: GeneratorTestFixtures.column(dataType: "timestamp"),
                seed: 1
            )
        }
    }

    @Test("The decorator draws from a different stream than the generator it wraps")
    func decoratorStreamIsIndependent() throws {
        let column = GeneratorTestFixtures.column(dataType: "boolean")
        let seed = GenerationSeed.columnSeed(runSeed: 1, table: "fixture", column: "value")
        let inner = try BooleanGenerator(
            params: GeneratorTestFixtures.params(#"{"truePercent":50}"#),
            column: column,
            seed: seed
        )
        let generator = DecoratedGenerator(
            inner: inner,
            column: column,
            common: CommonParams(nullPercent: 50),
            truncator: .forVendor(.postgresql),
            seed: seed
        )
        let values = try take(generator, 4_000)
        let trues = values.filter { $0 == .bool(true) }.count
        let falses = values.filter { $0 == .bool(false) }.count
        #expect(trues > 700)
        #expect(falses > 700)
        #expect(DecoratedGenerator.decoratorSeed(from: seed) != seed)
    }

    @Test("A column that has to be distinct is never blanked")
    func uniqueColumnIsNeverBlanked() throws {
        let column = GeneratorTestFixtures.column(dataType: "varchar(64)")
        let inner = try RandomStringGenerator(
            params: GeneratorTestFixtures.params(#"{"minLength":12,"maxLength":12}"#),
            column: column,
            seed: 4
        )
        let generator = DecoratedGenerator(
            inner: inner,
            column: column,
            common: CommonParams(blankPercent: 50, unique: true),
            truncator: .forVendor(.postgresql),
            seed: 4
        )
        let values = try take(generator, 500)
        #expect(!values.contains(.text("")))
        #expect(Set(values).count == values.count)
        #expect(generator.warnings.count == 1)
    }

    @Test("Blanks still apply when the column does not have to be distinct")
    func blanksApplyWhenNotUnique() throws {
        let column = GeneratorTestFixtures.column(dataType: "varchar(64)")
        let inner = try RandomStringGenerator(params: Data(), column: column, seed: 4)
        let generator = DecoratedGenerator(
            inner: inner,
            column: column,
            common: CommonParams(blankPercent: 50),
            truncator: .forVendor(.postgresql),
            seed: 4
        )
        #expect(try take(generator, 200).contains(.text("")))
        #expect(generator.warnings.isEmpty)
    }

    @Test("A composite foreign key is refused rather than drawn column by column")
    func compositeForeignKeyIsRefused() throws {
        let table = SchemaFactsAssembler(databaseType: .postgresql).assemble(
            schema: "public",
            table: "orders",
            columns: [
                PluginColumnInfo(name: "tenant_id", dataType: "bigint"),
                PluginColumnInfo(name: "customer_id", dataType: "bigint")
            ],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "fk",
                    localColumns: ["tenant_id", "customer_id"],
                    referencedTable: "customers",
                    referencedColumns: ["tenant_id", "id"]
                )
            ],
            indexes: []
        )
        let column = try #require(table.column(named: "customer_id"))
        #expect(throws: GenerationError.self) {
            _ = try ReferenceGenerator(params: Data(), column: column, seed: 1)
        }
        #expect(throws: Never.self) {
            _ = try ReferenceGenerator(
                params: GeneratorTestFixtures.params(#"{"table":"customers","column":"id"}"#),
                column: column,
                seed: 1
            )
        }
    }

    @Test("A double range wide enough to overflow its own span is refused")
    func infiniteSpanIsRefused() {
        #expect(throws: GenerationError.self) {
            _ = try DoubleGenerator(
                params: GeneratorTestFixtures.params(#"{"min":-1e308,"max":1e308}"#),
                column: GeneratorTestFixtures.column(dataType: "double precision"),
                seed: 1
            )
        }
    }

    @Test("Weights that overflow the running total are refused rather than trapping")
    func overflowingWeightsAreRefused() {
        #expect(throws: GenerationError.self) {
            _ = try ListGenerator(
                params: GeneratorTestFixtures.params(
                    #"{"values":["a","b"],"weights":[9223372036854775807,9223372036854775807]}"#
                ),
                column: GeneratorTestFixtures.column(),
                seed: 1
            )
        }
    }
}
