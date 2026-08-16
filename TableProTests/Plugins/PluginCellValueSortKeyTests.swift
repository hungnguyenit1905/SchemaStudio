//
//  PluginCellValueSortKeyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("PluginCellValue - sortKey")
struct PluginCellValueSortKeyTests {
    @Test(".null sortKey is empty string")
    func nullSortKey() {
        #expect(PluginCellValue.null.sortKey == "")
    }

    @Test(".text sortKey is the text verbatim")
    func textSortKey() {
        #expect(PluginCellValue.text("hello").sortKey == "hello")
        #expect(PluginCellValue.text("").sortKey == "")
    }

    @Test(".bytes sortKey is uppercase hex without 0x prefix")
    func bytesSortKey() {
        #expect(PluginCellValue.bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])).sortKey == "DEADBEEF")
        #expect(PluginCellValue.bytes(Data()).sortKey == "")
        #expect(PluginCellValue.bytes(Data([0x00, 0xFF])).sortKey == "00FF")
    }

    @Test("Distinct binary values produce distinct sort keys (deterministic order)")
    func distinctBytesProduceDistinctKeys() {
        let a = PluginCellValue.bytes(Data([0x00])).sortKey
        let b = PluginCellValue.bytes(Data([0x01])).sortKey
        let c = PluginCellValue.bytes(Data([0xFF])).sortKey
        #expect(a < b)
        #expect(b < c)
        #expect(a != b)
    }

    // MARK: - asText contract

    //
    // `asText` MUST return nil for `.bytes` so callers cannot accidentally treat
    // binary cells as editable text. Returning empty string instead would cause
    // the inline cell editor to display the empty field on click and commit ""
    // on focus-out, silently wiping the original bytes (regression for #1217).

    @Test(".text.asText returns the text verbatim")
    func textAsText() {
        #expect(PluginCellValue.text("hello").asText == "hello")
        #expect(PluginCellValue.text("").asText == "")
    }

    @Test(".bytes.asText returns nil so inline edit is gated")
    func bytesAsTextIsNil() {
        #expect(PluginCellValue.bytes(Data([0xDE, 0xAD])).asText == nil)
        #expect(PluginCellValue.bytes(Data()).asText == nil)
    }

    @Test(".null.asText returns nil")
    func nullAsText() {
        #expect(PluginCellValue.null.asText == nil)
    }

    // MARK: - asBytes contract

    @Test(".bytes.asBytes returns the data; other cases return nil")
    func asBytes() {
        let data = Data([0x01, 0x02, 0x03])
        #expect(PluginCellValue.bytes(data).asBytes == data)
        #expect(PluginCellValue.text("hello").asBytes == nil)
        #expect(PluginCellValue.null.asBytes == nil)
    }

    // MARK: - textFallback contract
    //
    // Every driver that has not adopted the typed path renders through this, so
    // its output is a contract, not an implementation detail. The three v19
    // cases must render byte-identically to `sortKey` or a non-adopting driver
    // silently changes behavior on upgrade.

    @Test("textFallback matches sortKey exactly for the three v19 cases")
    func textFallbackMatchesSortKeyForV19Cases() {
        let values: [PluginCellValue] = [
            .null, .text("hello"), .text(""), .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])), .bytes(Data()),
        ]
        for value in values {
            #expect(value.textFallback == value.sortKey)
        }
    }

    @Test("textFallback renders each typed case to its specified form")
    func textFallbackRendersTypedCases() {
        #expect(PluginCellValue.int(42).textFallback == "42")
        #expect(PluginCellValue.int(-9_223_372_036_854_775_808).textFallback == "-9223372036854775808")
        #expect(PluginCellValue.double(1.5).textFallback == "1.5")
        #expect(PluginCellValue.decimalText("1.10").textFallback == "1.10")
        #expect(PluginCellValue.bool(true).textFallback == "1")
        #expect(PluginCellValue.bool(false).textFallback == "0")
        #expect(PluginCellValue.date(year: 2_026, month: 8, day: 6).textFallback == "2026-08-06")
        #expect(PluginCellValue.time(seconds: 3_661, nanoseconds: 0).textFallback == "01:01:01")
        #expect(PluginCellValue.time(seconds: 0, nanoseconds: 500_000).textFallback == "00:00:00.000500")
        #expect(
            PluginCellValue.timestamp(Date(timeIntervalSince1970: 0)).textFallback == "1970-01-01T00:00:00Z"
        )
        #expect(PluginCellValue.array([.int(1), .int(2), .int(3)]).textFallback == "{1,2,3}")
        #expect(PluginCellValue.array([]).textFallback == "{}")
    }

    @Test("decimalText is never reformatted, so trailing precision survives")
    func decimalTextPreservesPrecision() {
        let lossy = "0.1000000000000000055511151231257827"
        #expect(PluginCellValue.decimalText(lossy).textFallback == lossy)
    }

    @Test("uuid renders lowercase and hyphenated")
    func uuidRendersLowercase() throws {
        let uuid = try #require(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
        #expect(PluginCellValue.uuid(uuid).textFallback == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    }

    @Test("timestamp renders in UTC regardless of the host timezone")
    func timestampRendersInUTC() {
        let instant = Date(timeIntervalSince1970: 1_755_000_000)
        #expect(PluginCellValue.timestamp(instant).textFallback.hasSuffix("Z"))
        #expect(PluginCellValue.timestamp(instant).textFallback == "2025-08-12T12:00:00Z")
    }

    // MARK: - Hashable separation
    //
    // `.int(1)` and `.text("1")` now hash apart where only the text form used
    // to exist. Anywhere that round-trips a value through text and compares it
    // to a typed one stops matching, which is why this is asserted rather than
    // assumed.

    @Test("A typed value and its text rendering are distinct values")
    func typedAndTextAreDistinct() {
        #expect(PluginCellValue.int(1) != PluginCellValue.text("1"))
        #expect(PluginCellValue.bool(true) != PluginCellValue.text("1"))
        #expect(Set([PluginCellValue.int(1), .text("1")]).count == 2)
        #expect(PluginCellValue.int(1).textFallback == PluginCellValue.text("1").textFallback)
    }

    @Test("sortKey routes typed cases through the same rendering as textFallback")
    func sortKeyRoutesTypedCases() {
        #expect(PluginCellValue.int(42).sortKey == "42")
        #expect(PluginCellValue.bool(false).sortKey == "0")
        #expect(PluginCellValue.int(1).sortKey == PluginCellValue.text("1").sortKey)
    }
}
