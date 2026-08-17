//
//  GenerationStringTruncatorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("GenerationStringTruncator")
struct GenerationStringTruncatorTests {
    private let familyEmoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"
    private let combiningAcuteE = "e\u{0301}"
    private let trebleClef = "\u{1D11E}"

    private let postgres = GenerationStringTruncator(unit: .unicodeScalars)
    private let sqlServer = GenerationStringTruncator(unit: .utf16CodeUnits)
    private let byteCounted = GenerationStringTruncator(unit: .utf8Bytes)

    @Test("The fixture emoji is one grapheme but five scalars and eight UTF-16 units")
    func fixtureShape() {
        #expect(familyEmoji.count == 1)
        #expect(familyEmoji.unicodeScalars.count == 5)
        #expect(familyEmoji.utf16.count == 8)
        #expect(familyEmoji.utf8.count == 18)
    }

    @Test("PostgreSQL and SQL Server disagree on the same over-length input")
    func vendorsDisagree() {
        let postgresResult = postgres.truncate(familyEmoji, to: 3)
        let sqlServerResult = sqlServer.truncate(familyEmoji, to: 3)
        #expect(postgresResult.unicodeScalars.count == 3)
        #expect(sqlServerResult.unicodeScalars.count == 2)
        #expect(postgresResult != sqlServerResult)
    }

    @Test("A truncated value fits the limit the vendor itself counts")
    func resultFitsVendorCount() {
        for limit in 0...10 {
            #expect(postgres.truncate(familyEmoji, to: limit).unicodeScalars.count <= limit)
            #expect(sqlServer.truncate(familyEmoji, to: limit).utf16.count <= limit)
            #expect(byteCounted.truncate(familyEmoji, to: limit).utf8.count <= limit)
        }
    }

    @Test("Grapheme counting would overflow where scalar counting does not")
    func graphemeCountingWouldOverflow() {
        #expect(String(familyEmoji.prefix(1)).unicodeScalars.count == 5)
        #expect(postgres.truncate(familyEmoji, to: 3).unicodeScalars.count == 3)
    }

    @Test("A combining mark is dropped rather than counted with its base")
    func combiningMarks() {
        #expect(combiningAcuteE.count == 1)
        #expect(combiningAcuteE.unicodeScalars.count == 2)
        #expect(postgres.truncate(combiningAcuteE, to: 1) == "e")
    }

    @Test("Vietnamese diacritics are counted as the vendor counts them")
    func vietnameseDiacritics() {
        let precomposed = "Nguy\u{1EC5}n"
        #expect(precomposed.unicodeScalars.count == 6)
        #expect(postgres.truncate(precomposed, to: 5).unicodeScalars.count == 5)
        #expect(postgres.truncate(precomposed, to: 6) == precomposed)

        let decomposed = "Nguye\u{0302}\u{0303}n"
        #expect(decomposed.unicodeScalars.count == 8)
        #expect(postgres.truncate(decomposed, to: 6).unicodeScalars.count == 6)
    }

    @Test("A character outside the BMP is never split into a lone surrogate")
    func astralCharacterNeverSplit() {
        #expect(trebleClef.utf16.count == 2)
        let cut = sqlServer.truncate("a" + trebleClef, to: 2)
        #expect(cut == "a")
        #expect(sqlServer.truncate(trebleClef, to: 1) == "")
        #expect(sqlServer.truncate(trebleClef, to: 2) == trebleClef)
    }

    @Test("A multibyte scalar is never split mid sequence")
    func multibyteScalarNeverSplit() {
        #expect(byteCounted.truncate("ñ", to: 1) == "")
        #expect(byteCounted.truncate("ñ", to: 2) == "ñ")
        #expect(byteCounted.truncate("añ", to: 2) == "a")
    }

    @Test("A zero limit produces an empty string")
    func zeroLimit() {
        #expect(postgres.truncate("anything", to: 0) == "")
        #expect(sqlServer.truncate(familyEmoji, to: 0) == "")
    }

    @Test("A nil limit leaves the value untouched")
    func nilLimitKeepsValue() {
        #expect(postgres.truncate(familyEmoji, to: nil) == familyEmoji)
    }

    @Test("A value already inside the limit is returned unchanged")
    func withinLimitUnchanged() {
        #expect(postgres.truncate("abc", to: 10) == "abc")
        #expect(postgres.fits("abc", limit: 3))
        #expect(!postgres.fits("abcd", limit: 3))
    }

    @Test("A byte budget applies on top of the scalar limit")
    func byteBudgetOnTopOfScalarLimit() {
        let mysqlIndexPrefix = GenerationStringTruncator(unit: .unicodeScalars, byteLimit: 4)
        let value = "ñññ"
        #expect(value.unicodeScalars.count == 3)
        #expect(value.utf8.count == 6)
        let cut = mysqlIndexPrefix.truncate(value, to: 10)
        #expect(cut == "ññ")
        #expect(cut.utf8.count <= 4)
        #expect(!mysqlIndexPrefix.fits(value, limit: 10))
    }

    @Test("Each vendor family resolves to the unit that vendor counts")
    func vendorUnits() {
        #expect(GenerationStringTruncator.unit(for: .postgresql) == .unicodeScalars)
        #expect(GenerationStringTruncator.unit(for: .mysql) == .unicodeScalars)
        #expect(GenerationStringTruncator.unit(for: .sqlite) == .unicodeScalars)
        #expect(GenerationStringTruncator.unit(for: .mssql) == .utf16CodeUnits)
        #expect(GenerationStringTruncator.unit(for: nil) == .unicodeScalars)
    }

    @Test("An empty string survives any limit")
    func emptyString() {
        #expect(postgres.truncate("", to: 0) == "")
        #expect(sqlServer.truncate("", to: 5) == "")
    }
}
