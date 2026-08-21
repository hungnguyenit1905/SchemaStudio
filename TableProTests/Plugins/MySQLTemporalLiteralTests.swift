//
//  MySQLTemporalLiteralTests.swift
//  TableProTests
//
//  Regression cover for a bug found by round-tripping against a real MySQL
//  server: `textFallback` renders `.timestamp` as ISO-8601, and MySQL rejects
//  both the `T` separator and the trailing `Z` in a DATETIME literal with error
//  1292. Every insert carrying a typed timestamp failed outright.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL temporal literal")
struct MySQLTemporalLiteralTests {
    @Test("A timestamp renders as a space-separated MySQL DATETIME literal")
    func timestampUsesMySQLDatetimeForm() {
        let instant = Date(timeIntervalSince1970: 1_755_000_000)
        let literal = MySQLTemporalLiteral.literal(for: .timestamp(instant))

        #expect(literal == "2025-08-12 12:00:00")
        #expect(!literal.contains("T"))
        #expect(!literal.hasSuffix("Z"))
    }

    @Test("The literal is the UTC wall clock, not the host timezone")
    func timestampRendersInUTC() {
        #expect(MySQLTemporalLiteral.literal(for: .timestamp(Date(timeIntervalSince1970: 0)))
            == "1970-01-01 00:00:00")
    }

    @Test("Sub-second precision renders as six digits and is omitted when zero")
    func fractionalSecondsRenderAsMicroseconds() {
        let base = Date(timeIntervalSince1970: 1_755_000_000)
        #expect(MySQLTemporalLiteral.literal(for: .timestamp(base)) == "2025-08-12 12:00:00")
        #expect(MySQLTemporalLiteral.string(from: base.addingTimeInterval(0.5))
            == "2025-08-12 12:00:00.500000")
    }

    @Test("Every other case is left to textFallback unchanged")
    func nonTimestampCasesAreUnchanged() {
        let values: [PluginCellValue] = [
            .null, .text("hello"), .bytes(Data([0xDE, 0xAD])), .int(42), .double(1.5),
            .decimalText("1.10"), .bool(true), .date(year: 2_026, month: 8, day: 16),
            .time(seconds: 3_661, nanoseconds: 0), .uuid(UUID()), .array([.int(1)]),
        ]
        for value in values {
            #expect(MySQLTemporalLiteral.literal(for: value) == value.textFallback)
        }
    }

    @Test("A timestamp inside an array still renders through textFallback")
    func nestedTimestampIsNotRewritten() {
        // Only a top-level timestamp is rewritten. MySQL has no array type, so a
        // nested one can only ever land in a string column, where the ISO-8601
        // form is the same thing v19 would have carried.
        let nested = PluginCellValue.array([.timestamp(Date(timeIntervalSince1970: 0))])
        #expect(MySQLTemporalLiteral.literal(for: nested) == nested.textFallback)
    }
}
