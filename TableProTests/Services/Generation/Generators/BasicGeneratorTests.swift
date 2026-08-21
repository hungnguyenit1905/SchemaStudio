//
//  BasicGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Basic generators")
struct BasicGeneratorTests {
    private let row = GeneratorTestFixtures.rowContext()

    private func take(_ generator: any ValueGenerator, _ count: Int) throws -> [PluginCellValue] {
        try (0..<count).map { try generator.next(row: row, index: $0) }
    }

    private func integers(_ values: [PluginCellValue]) -> [Int64] {
        values.compactMap { value in
            guard case .int(let number) = value else { return nil }
            return number
        }
    }

    @Test("Integer stays inside its own range")
    func integerRespectsRange() throws {
        let generator = try IntegerGenerator(
            params: GeneratorTestFixtures.params(#"{"min":10,"max":20}"#),
            column: GeneratorTestFixtures.column(dataType: "integer"),
            seed: 2
        )
        let values = integers(try take(generator, 2_000))
        #expect(values.count == 2_000)
        #expect(values.allSatisfy { (10...20).contains($0) })
        #expect(values.contains(10))
        #expect(values.contains(20))
    }

    @Test("Integer never leaves the column's native range")
    func integerRespectsNativeRange() throws {
        let generator = try IntegerGenerator(
            params: GeneratorTestFixtures.params(#"{"min":-100000,"max":100000}"#),
            column: GeneratorTestFixtures.column(dataType: "smallint"),
            seed: 2
        )
        #expect(integers(try take(generator, 2_000)).allSatisfy { (-32_768...32_767).contains($0) })
    }

    @Test("Integer honours its step")
    func integerRespectsStep() throws {
        let generator = try IntegerGenerator(
            params: GeneratorTestFixtures.params(#"{"min":0,"max":100,"step":5}"#),
            column: GeneratorTestFixtures.column(dataType: "integer"),
            seed: 2
        )
        let values = integers(try take(generator, 500))
        #expect(values.allSatisfy { $0 % 5 == 0 })
        #expect(values.allSatisfy { (0...100).contains($0) })
    }

    @Test("Integer rejects an inverted range and a non-positive step")
    func integerRejectsBadParams() {
        #expect(throws: GenerationError.self) {
            _ = try IntegerGenerator(
                params: GeneratorTestFixtures.params(#"{"min":10,"max":1}"#),
                column: GeneratorTestFixtures.column(dataType: "integer"),
                seed: 1
            )
        }
        #expect(throws: GenerationError.self) {
            _ = try IntegerGenerator(
                params: GeneratorTestFixtures.params(#"{"step":0}"#),
                column: GeneratorTestFixtures.column(dataType: "integer"),
                seed: 1
            )
        }
    }

    @Test("Decimal emits decimal text, never a double")
    func decimalEmitsDecimalText() throws {
        let generator = try DecimalGenerator(
            params: GeneratorTestFixtures.params(#"{"min":0,"max":100}"#),
            column: GeneratorTestFixtures.column(dataType: "numeric(10,2)"),
            seed: 3
        )
        let values = try take(generator, 500)
        #expect(values.allSatisfy { if case .decimalText = $0 { return true } else { return false } })
        #expect(values.allSatisfy { value in
            guard case .decimalText(let text) = value else { return false }
            return text.split(separator: ".").last?.count == 2
        })
        #expect(values.allSatisfy { value in
            guard case .decimalText(let text) = value, let number = Double(text) else { return false }
            return number >= 0 && number <= 100
        })
    }

    @Test("Decimal takes its scale from the column when unset")
    func decimalUsesColumnScale() throws {
        let generator = try DecimalGenerator(
            params: GeneratorTestFixtures.params(#"{"min":1,"max":2}"#),
            column: GeneratorTestFixtures.column(dataType: "numeric(12,4)"),
            seed: 3
        )
        guard case .decimalText(let text) = try take(generator, 1)[0] else {
            Issue.record("expected decimal text")
            return
        }
        #expect(text.split(separator: ".").last?.count == 4)
    }

    @Test("Decimal formats a scaled integer without floating point drift")
    func decimalFormatting() {
        #expect(DecimalGenerator.format(unscaled: 125, scale: 2) == "1.25")
        #expect(DecimalGenerator.format(unscaled: 5, scale: 2) == "0.05")
        #expect(DecimalGenerator.format(unscaled: 0, scale: 2) == "0.00")
        #expect(DecimalGenerator.format(unscaled: -5, scale: 2) == "-0.05")
        #expect(DecimalGenerator.format(unscaled: -12_345, scale: 3) == "-12.345")
        #expect(DecimalGenerator.format(unscaled: 42, scale: 0) == "42")
    }

    @Test("Decimal stays inside the column's precision")
    func decimalRespectsPrecision() throws {
        let generator = try DecimalGenerator(
            params: GeneratorTestFixtures.params(#"{"min":0,"max":100000}"#),
            column: GeneratorTestFixtures.column(dataType: "numeric(4,1)"),
            seed: 3
        )
        #expect(try take(generator, 200).allSatisfy { value in
            guard case .decimalText(let text) = value else { return false }
            return text.filter(\.isNumber).count <= 4
        })
    }

    @Test("Double stays inside its range")
    func doubleRespectsRange() throws {
        let generator = try DoubleGenerator(
            params: GeneratorTestFixtures.params(#"{"min":-1.5,"max":2.5}"#),
            column: GeneratorTestFixtures.column(dataType: "double precision"),
            seed: 5
        )
        #expect(try take(generator, 1_000).allSatisfy { value in
            guard case .double(let number) = value else { return false }
            return number >= -1.5 && number <= 2.5
        })
    }

    @Test("Boolean honours its true percentage")
    func booleanHonoursPercentage() throws {
        let generator = try BooleanGenerator(
            params: GeneratorTestFixtures.params(#"{"truePercent":25}"#),
            column: GeneratorTestFixtures.column(dataType: "boolean"),
            seed: 6
        )
        let trues = try take(generator, 4_000).filter { $0 == .bool(true) }.count
        #expect(trues > 850)
        #expect(trues < 1_150)
    }

    @Test("Boolean emits an integer on an integer column")
    func booleanOnIntegerColumn() throws {
        let generator = try BooleanGenerator(
            params: GeneratorTestFixtures.params(#"{"truePercent":100}"#),
            column: GeneratorTestFixtures.column(dataType: "int", databaseType: .mysql),
            seed: 6
        )
        #expect(try take(generator, 5).allSatisfy { $0 == .int(1) })
    }

    @Test("RandomString respects its length range and character set")
    func randomStringRespectsLengthAndCharset() throws {
        let generator = try RandomStringGenerator(
            params: GeneratorTestFixtures.params(#"{"minLength":3,"maxLength":8,"charset":"numeric"}"#),
            column: GeneratorTestFixtures.column(dataType: "varchar(64)"),
            seed: 8
        )
        let values = try take(generator, 500).compactMap(\.asText)
        #expect(values.count == 500)
        #expect(values.allSatisfy { (3...8).contains($0.count) })
        #expect(values.allSatisfy { $0.allSatisfy(\.isNumber) })
    }

    @Test("RandomString never exceeds the column's declared length")
    func randomStringRespectsColumnLength() throws {
        let generator = try RandomStringGenerator(
            params: GeneratorTestFixtures.params(#"{"minLength":10,"maxLength":50}"#),
            column: GeneratorTestFixtures.column(dataType: "varchar(6)"),
            seed: 8
        )
        #expect(try take(generator, 200).compactMap(\.asText).allSatisfy { $0.count <= 6 })
    }

    @Test("RandomString rejects an empty custom character set")
    func randomStringRejectsEmptyCharset() {
        #expect(throws: GenerationError.self) {
            _ = try RandomStringGenerator(
                params: GeneratorTestFixtures.params(#"{"charset":"custom","customCharacters":""}"#),
                column: GeneratorTestFixtures.column(dataType: "varchar(64)"),
                seed: 1
            )
        }
    }

    @Test("RandomBytes respects its length range")
    func randomBytesRespectsLength() throws {
        let generator = try RandomBytesGenerator(
            params: GeneratorTestFixtures.params(#"{"minLength":4,"maxLength":9}"#),
            column: GeneratorTestFixtures.column(dataType: "bytea"),
            seed: 9
        )
        #expect(try take(generator, 300).allSatisfy { value in
            guard case .bytes(let data) = value else { return false }
            return (4...9).contains(data.count)
        })
    }

    @Test("UUID emits a well formed version 4 identifier from the seeded stream")
    func uuidIsVersionFourAndSeeded() throws {
        let generator = try UuidGenerator(
            params: Data(),
            column: GeneratorTestFixtures.column(dataType: "uuid"),
            seed: 10
        )
        let values = try take(generator, 500).compactMap { value -> UUID? in
            guard case .uuid(let identifier) = value else { return nil }
            return identifier
        }
        #expect(values.count == 500)
        #expect(Set(values).count == 500)
        #expect(values.allSatisfy { $0.uuid.6 & 0xF0 == 0x40 })
        #expect(values.allSatisfy { $0.uuid.8 & 0xC0 == 0x80 })
    }

    @Test("UUID emits text on a non-uuid column")
    func uuidOnTextColumn() throws {
        let generator = try UuidGenerator(
            params: Data(),
            column: GeneratorTestFixtures.column(dataType: "varchar(36)"),
            seed: 10
        )
        let text = try #require(try take(generator, 1)[0].asText)
        #expect(UUID(uuidString: text) != nil)
        #expect(text == text.lowercased())
    }

    @Test("Date emits calendar components inside its range")
    func dateRespectsRange() throws {
        let generator = try DateGenerator(
            params: GeneratorTestFixtures.params(#"{"from":"2024-02-01","to":"2024-03-01"}"#),
            column: GeneratorTestFixtures.column(dataType: "date"),
            seed: 11
        )
        let values = try take(generator, 1_000)
        #expect(values.allSatisfy { value in
            guard case .date(let year, let month, let day) = value else { return false }
            let civil = CivilDate(year: year, month: month, day: day)
            return civil >= CivilDate(year: 2_024, month: 2, day: 1)
                && civil <= CivilDate(year: 2_024, month: 3, day: 1)
        })
    }

    @Test("Date never emits a day that does not exist in its month")
    func dateNeverEmitsAnInvalidDay() throws {
        let generator = try DateGenerator(
            params: GeneratorTestFixtures.params(#"{"from":"1900-01-01","to":"2100-12-31"}"#),
            column: GeneratorTestFixtures.column(dataType: "date"),
            seed: 12
        )
        #expect(try take(generator, 20_000).allSatisfy { value in
            guard case .date(let year, let month, let day) = value else { return false }
            return (1...12).contains(month) && day >= 1 && day <= CivilDate.daysInMonth(year: year, month: month)
        })
    }

    @Test("29 February exists only in a leap year")
    func leapDayHandling() {
        #expect(CivilDate(iso8601: "2024-02-29") != nil)
        #expect(CivilDate(iso8601: "2023-02-29") == nil)
        #expect(CivilDate(iso8601: "2000-02-29") != nil)
        #expect(CivilDate(iso8601: "1900-02-29") == nil)
        #expect(CivilDate(year: 2_024, month: 2, day: 29).daysSinceEpoch == 19_782)
        #expect(CivilDate.fromDaysSinceEpoch(19_782) == CivilDate(year: 2_024, month: 2, day: 29))
    }

    @Test("A civil date round trips through its day number", arguments: [
        "1970-01-01", "1969-12-31", "1900-03-01", "2000-02-29", "2100-01-01", "2038-01-19"
    ])
    func civilDateRoundTrip(text: String) throws {
        let date = try #require(CivilDate(iso8601: text))
        #expect(CivilDate.fromDaysSinceEpoch(date.daysSinceEpoch) == date)
        #expect(date.iso8601 == text)
    }

    @Test("Date rejects a reversed or unparseable range")
    func dateRejectsBadRange() {
        #expect(throws: GenerationError.self) {
            _ = try DateGenerator(
                params: GeneratorTestFixtures.params(#"{"from":"2024-01-02","to":"2024-01-01"}"#),
                column: GeneratorTestFixtures.column(dataType: "date"),
                seed: 1
            )
        }
        #expect(throws: GenerationError.self) {
            _ = try DateGenerator(
                params: GeneratorTestFixtures.params(#"{"from":"not-a-date"}"#),
                column: GeneratorTestFixtures.column(dataType: "date"),
                seed: 1
            )
        }
    }

    @Test("DateTime emits a UTC timestamp inside its range")
    func dateTimeRespectsRange() throws {
        let generator = try DateTimeGenerator(
            params: GeneratorTestFixtures.params(
                #"{"from":"2024-01-01T00:00:00Z","to":"2024-01-02T00:00:00Z"}"#
            ),
            column: GeneratorTestFixtures.column(dataType: "timestamp"),
            seed: 13
        )
        let lower = Date(timeIntervalSince1970: 1_704_067_200)
        let upper = Date(timeIntervalSince1970: 1_704_153_600)
        #expect(try take(generator, 1_000).allSatisfy { value in
            guard case .timestamp(let instant) = value else { return false }
            return instant >= lower && instant <= upper
        })
    }

    @Test("DateTime rounds to its granularity")
    func dateTimeRespectsGranularity() throws {
        let generator = try DateTimeGenerator(
            params: GeneratorTestFixtures.params(
                #"{"from":"2024-01-01T00:00:00Z","to":"2024-01-08T00:00:00Z","granularity":"hour"}"#
            ),
            column: GeneratorTestFixtures.column(dataType: "timestamp"),
            seed: 13
        )
        #expect(try take(generator, 500).allSatisfy { value in
            guard case .timestamp(let instant) = value else { return false }
            return Int(instant.timeIntervalSince1970) % 3_600 == 0
        })
    }

    @Test("LoremWords respects its word count and the column length")
    func loremWordsRespectsBounds() throws {
        let generator = try LoremWordsGenerator(
            params: GeneratorTestFixtures.params(#"{"minWords":2,"maxWords":5}"#),
            column: GeneratorTestFixtures.column(dataType: "text"),
            seed: 14
        )
        let values = try take(generator, 300).compactMap(\.asText)
        #expect(values.allSatisfy { (2...5).contains($0.split(separator: " ").count) })
        #expect(values.allSatisfy { $0.first?.isUppercase == true })

        let capped = try LoremWordsGenerator(
            params: GeneratorTestFixtures.params(#"{"minWords":10,"maxWords":20}"#),
            column: GeneratorTestFixtures.column(dataType: "varchar(12)"),
            seed: 14
        )
        #expect(try take(capped, 100).compactMap(\.asText).allSatisfy { $0.unicodeScalars.count <= 12 })
    }
}
