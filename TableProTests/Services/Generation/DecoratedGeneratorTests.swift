//
//  DecoratedGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

private final class CyclingTextGenerator: ValueGenerator {
    static let identifier = "test.cyclingText"

    private let values: [String]
    private var position = 0

    init(values: [String]) {
        self.values = values
    }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        values = []
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard !values.isEmpty else { return .null }
        defer { position += 1 }
        return .text(values[position % values.count])
    }

    func reset() {
        position = 0
    }
}

private final class CyclingDecimalTextGenerator: ValueGenerator {
    static let identifier = "test.cyclingDecimalText"

    private let values: [String]
    private var position = 0

    init(values: [String]) {
        self.values = values
    }

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {
        values = []
    }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        guard !values.isEmpty else { return .null }
        defer { position += 1 }
        return .decimalText(values[position % values.count])
    }

    func reset() {
        position = 0
    }
}

private final class CountingIntGenerator: ValueGenerator {
    static let identifier = "test.countingInt"

    private var position: Int64 = 0

    init() {}

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {}

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        defer { position += 1 }
        return .int(position)
    }

    func reset() {
        position = 0
    }
}

@Suite("DecoratedGenerator")
struct DecoratedGeneratorTests {
    private let row = RowContext(table: "people", rowIndex: 0)

    private func column(
        name: String = "name",
        dataType: String = "varchar(64)",
        databaseType: DatabaseType = .postgresql
    ) -> GenerationColumn {
        let table = SchemaFactsAssembler(databaseType: databaseType).assemble(
            schema: nil,
            table: "people",
            columns: [PluginColumnInfo(name: name, dataType: dataType)],
            foreignKeys: [],
            indexes: []
        )
        guard let resolved = table.column(named: name) else {
            preconditionFailure("fixture column missing")
        }
        return resolved
    }

    private func decorated(
        inner: any ValueGenerator,
        column: GenerationColumn,
        common: CommonParams = .none,
        vendor: TransferVendor? = .postgresql,
        seed: UInt64 = 42,
        uniqueRetryBudget: Int = DecoratedGenerator.defaultUniqueRetryBudget
    ) -> DecoratedGenerator {
        DecoratedGenerator(
            inner: inner,
            column: column,
            common: common,
            truncator: .forVendor(vendor),
            seed: seed,
            uniqueRetryBudget: uniqueRetryBudget
        )
    }

    private func take(_ generator: DecoratedGenerator, _ count: Int) throws -> [PluginCellValue] {
        try (0..<count).map { try generator.next(row: row, index: $0) }
    }

    @Test("The decorator applies case, then affixes, then truncation")
    func decoratorOrderIsExact() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["ab"]),
            column: column(dataType: "varchar(3)"),
            common: CommonParams(prefix: "p", suffix: "s", textCase: .uppercase)
        )
        let value = try generator.next(row: row, index: 0)
        #expect(value == .text("pAB"))
        #expect(value != .text("PAB"))
        #expect(value != .text("pABs"))
    }

    @Test("A null percentage of 100 makes every value null")
    func allNullsAtHundredPercent() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["a", "b", "c"]),
            column: column(),
            common: CommonParams(nullPercent: 100)
        )
        #expect(try take(generator, 25).allSatisfy(\.isNull))
    }

    @Test("A null percentage of 0 never yields a null")
    func noNullsAtZeroPercent() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["a", "b", "c"]),
            column: column()
        )
        #expect(try take(generator, 50).allSatisfy { !$0.isNull })
    }

    @Test("A null percentage in between produces nulls at roughly that rate")
    func nullPercentageIsHonoured() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["a"]),
            column: column(),
            common: CommonParams(nullPercent: 30)
        )
        let nulls = try take(generator, 2_000).filter(\.isNull).count
        #expect(nulls > 450)
        #expect(nulls < 750)
    }

    @Test("A blank percentage of 100 makes every text value empty without making it null")
    func allBlanksAtHundredPercent() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["a", "b"]),
            column: column(),
            common: CommonParams(blankPercent: 100)
        )
        #expect(try take(generator, 20).allSatisfy { $0 == .text("") })
    }

    @Test("Null wins over blank because it is applied last")
    func nullIsAppliedAfterBlank() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["a"]),
            column: column(),
            common: CommonParams(nullPercent: 100, blankPercent: 100)
        )
        #expect(try take(generator, 10).allSatisfy(\.isNull))
    }

    @Test("A unique column retries until it finds a distinct value")
    func uniqueRetriesUntilDistinct() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["a", "a", "a", "b"]),
            column: column(),
            common: CommonParams(unique: true),
            uniqueRetryBudget: 8
        )
        #expect(try generator.next(row: row, index: 0) == .text("a"))
        #expect(try generator.next(row: row, index: 1) == .text("b"))
    }

    @Test("A unique column throws once the retry budget runs out")
    func uniqueExhaustedAfterBudget() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["same"]),
            column: column(),
            common: CommonParams(unique: true),
            uniqueRetryBudget: 5
        )
        #expect(try generator.next(row: row, index: 0) == .text("same"))
        #expect(throws: GenerationError.uniqueExhausted(column: "name", attempts: 5)) {
            try generator.next(row: row, index: 1)
        }
    }

    @Test("Truncation runs before the unique check, so it uses the stored value")
    func uniquenessSeesTheTruncatedValue() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["abcx", "abcy", "abd"]),
            column: column(dataType: "varchar(3)"),
            common: CommonParams(unique: true),
            uniqueRetryBudget: 8
        )
        #expect(try generator.next(row: row, index: 0) == .text("abc"))
        #expect(try generator.next(row: row, index: 1) == .text("abd"))
    }

    @Test("A varchar(3) holding a family emoji is cut to what the vendor counts")
    func truncationUsesVendorCount() throws {
        let familyEmoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"
        let postgres = decorated(
            inner: CyclingTextGenerator(values: [familyEmoji]),
            column: column(dataType: "varchar(3)"),
            vendor: .postgresql
        )
        let sqlServer = decorated(
            inner: CyclingTextGenerator(values: [familyEmoji]),
            column: column(dataType: "nvarchar(3)", databaseType: .mssql),
            vendor: .mssql
        )
        let postgresValue = try #require(try postgres.next(row: row, index: 0).asText)
        let sqlServerValue = try #require(try sqlServer.next(row: row, index: 0).asText)
        #expect(postgresValue.unicodeScalars.count <= 3)
        #expect(sqlServerValue.utf16.count <= 3)
        #expect(postgresValue != sqlServerValue)
    }

    @Test("An overflowing prefix and suffix warn once per column, not once per row")
    func affixOverflowWarnsOnce() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["value"]),
            column: column(dataType: "varchar(3)"),
            common: CommonParams(prefix: "ab", suffix: "cd")
        )
        _ = try take(generator, 20)
        #expect(generator.warnings.count == 1)
        #expect(generator.warnings.first?.column == "name")
    }

    @Test("An affix that fits raises no warning")
    func affixThatFitsIsSilent() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["value"]),
            column: column(dataType: "varchar(32)"),
            common: CommonParams(prefix: "a-", suffix: "-z")
        )
        _ = try take(generator, 20)
        #expect(generator.warnings.isEmpty)
    }

    @Test("A non-text value skips case, affixes and truncation")
    func nonTextValuesBypassTextShaping() throws {
        let generator = decorated(
            inner: CountingIntGenerator(),
            column: column(name: "counter", dataType: "bigint"),
            common: CommonParams(prefix: "p", suffix: "s", textCase: .uppercase)
        )
        #expect(try take(generator, 3) == [.int(0), .int(1), .int(2)])
    }

    @Test("decimalText is decorated and truncated exactly like text")
    func decimalTextIsDecorated() throws {
        let generator = decorated(
            inner: CyclingDecimalTextGenerator(values: ["12.5"]),
            column: column(dataType: "varchar(6)"),
            common: CommonParams(prefix: "$", suffix: "!")
        )
        let value = try generator.next(row: row, index: 0)
        #expect(value == .decimalText("$12.5!"))
    }

    @Test("decimalText is truncated to the column's length like text")
    func decimalTextIsTruncated() throws {
        let generator = decorated(
            inner: CyclingDecimalTextGenerator(values: ["1234.56"]),
            column: column(dataType: "varchar(4)")
        )
        let value = try generator.next(row: row, index: 0)
        #expect(value == .decimalText("1234"))
    }

    @Test("Two decorators built from the same seed emit identical sequences")
    func deterministicAcrossInstances() throws {
        func build() -> DecoratedGenerator {
            decorated(
                inner: CyclingTextGenerator(values: ["a", "b", "c", "d"]),
                column: column(),
                common: CommonParams(nullPercent: 30, blankPercent: 20),
                seed: 12_345
            )
        }
        #expect(try take(build(), 500) == take(build(), 500))
    }

    @Test("Reset restarts the value stream and clears the unique memory")
    func resetRestartsTheStream() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["a", "b", "c"]),
            column: column(),
            common: CommonParams(nullPercent: 25, unique: true)
        )
        let first = try take(generator, 3)
        generator.reset()
        #expect(try take(generator, 3) == first)
    }

    @Test("Reset clears a warning so a rerun reports it once again")
    func resetClearsWarnings() throws {
        let generator = decorated(
            inner: CyclingTextGenerator(values: ["value"]),
            column: column(dataType: "varchar(3)"),
            common: CommonParams(prefix: "ab", suffix: "cd")
        )
        _ = try take(generator, 5)
        generator.reset()
        _ = try take(generator, 5)
        #expect(generator.warnings.count == 1)
    }
}
