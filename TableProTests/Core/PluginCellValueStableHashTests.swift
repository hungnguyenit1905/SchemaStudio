//
//  PluginCellValueStableHashTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("PluginCellValue.stableHash")
struct PluginCellValueStableHashTests {
    private static let fixedUuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")

    @Test("Each case hashes to its reference FNV-1a constant")
    func referenceVectors() throws {
        let uuid = try #require(Self.fixedUuid)
        let expected: [(PluginCellValue, UInt64)] = [
            (.null, 12_638_153_115_695_167_455),
            (.text("hello"), 6_173_028_704_329_603_409),
            (.text("1"), 5_850_558_308_127_721_962),
            (.bytes(Data([1, 2, 3])), 7_467_355_218_140_582_788),
            (.int(1), 8_750_169_272_185_725_317),
            (.double(1.0), 11_561_618_580_854_010_748),
            (.decimalText("1"), 17_193_854_673_680_416_966),
            (.bool(true), 588_769_818_076_096_488),
            (.bool(false), 588_770_917_587_724_699),
            (.date(year: 2_026, month: 8, day: 17), 13_500_510_402_833_230_064),
            (.time(seconds: 3_661, nanoseconds: 500_000_000), 29_075_941_784_981_973),
            (.timestamp(Date(timeIntervalSince1970: 0)), 17_144_315_140_666_876_996),
            (.uuid(uuid), 13_397_976_863_359_337_274),
            (.array([.int(1), .int(2)]), 9_423_397_973_393_806_263)
        ]
        for (value, constant) in expected {
            #expect(value.stableHash == constant, "\(value)")
        }
    }

    @Test("Values that look alike across cases hash differently")
    func casesDoNotCollide() {
        let hashes = [
            PluginCellValue.int(1).stableHash,
            PluginCellValue.double(1.0).stableHash,
            PluginCellValue.text("1").stableHash,
            PluginCellValue.decimalText("1").stableHash,
            PluginCellValue.bool(true).stableHash
        ]
        #expect(Set(hashes).count == hashes.count)
    }

    @Test("Array hashing is order sensitive")
    func arrayOrderMatters() {
        let ascending = PluginCellValue.array([.int(1), .int(2)])
        let descending = PluginCellValue.array([.int(2), .int(1)])
        #expect(ascending.stableHash == 9_423_397_973_393_806_263)
        #expect(descending.stableHash == 5_346_997_479_484_683_643)
        #expect(ascending.stableHash != descending.stableHash)
    }

    @Test("An empty array and a null hash differently")
    func emptyArrayIsNotNull() {
        #expect(PluginCellValue.array([]).stableHash != PluginCellValue.null.stableHash)
    }

    @Test("Concatenation ambiguity is ruled out by length prefixing")
    func lengthPrefixingPreventsAmbiguity() {
        #expect(
            PluginCellValue.array([.text("ab"), .text("c")]).stableHash
                != PluginCellValue.array([.text("a"), .text("bc")]).stableHash
        )
    }

    @Test("Negative zero hashes as positive zero, matching equality")
    func negativeZeroNormalized() {
        #expect(PluginCellValue.double(-0.0).stableHash == PluginCellValue.double(0.0).stableHash)
        #expect(PluginCellValue.double(-0.0) == PluginCellValue.double(0.0))
    }

    @Test("Two separately built copies of one value hash alike")
    func separateCopiesAgree() {
        let first = PluginCellValue.text("stability")
        let second = PluginCellValue.text(["stab", "ility"].joined())
        #expect(first.stableHash == second.stableHash)
    }
}
