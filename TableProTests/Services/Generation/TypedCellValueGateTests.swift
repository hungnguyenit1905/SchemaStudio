//
//  TypedCellValueGateTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Typed cell downgrade")
struct TypedCellDowngradeTests {
    @Test("Every typed case reduces to the text a v19 driver would have received")
    func typedCasesBecomeText() {
        let cases: [PluginCellValue] = [
            .int(42),
            .double(1.5),
            .decimalText("1.25"),
            .bool(true),
            .date(year: 2026, month: 8, day: 19),
            .time(seconds: 3_661, nanoseconds: 0),
            .timestamp(Date(timeIntervalSince1970: 0)),
            .uuid(UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()),
            .array([.int(1), .int(2)])
        ]
        for value in cases {
            #expect(value.downgradedToLegacyCases == .text(value.textFallback))
            #expect(value.downgradedToLegacyCases.asText != nil)
        }
    }

    @Test("The pre-v20 cases are handed through untouched")
    func legacyCasesAreUnchanged() {
        let untouched: [PluginCellValue] = [.null, .text("hello"), .bytes(Data([0x01, 0xFF]))]
        for value in untouched {
            #expect(value.downgradedToLegacyCases == value)
        }
    }

    @Test("A driver reading a downgraded cell with asText never sees nil")
    func downgradedCellsAreReadableAsText() {
        #expect(PluginCellValue.int(7).downgradedToLegacyCases.asText == "7")
        #expect(PluginCellValue.bool(false).downgradedToLegacyCases.asText == "0")
    }
}

@Suite("Portable SQL literals")
struct PortableTimestampLiteralTests {
    @Test("A timestamp literal has no ISO 8601 T or Z")
    func timestampLiteralIsPortable() {
        let rendered = PluginCellValue.portableTimestampLiteral(Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!rendered.contains("T"))
        #expect(!rendered.contains("Z"))
        #expect(rendered.hasPrefix("2023-11-14 "))
    }

    @Test("textFallback keeps the v19 ISO rendering")
    func textFallbackIsUnchanged() {
        let value = PluginCellValue.timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        #expect(value.textFallback.contains("T"))
        #expect(value.textFallback.hasSuffix("Z"))
    }
}
