//
//  SplitMix64Tests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("SplitMix64")
struct SplitMix64Tests {
    @Test("Seed 0 matches the published reference vectors")
    func referenceVectorsForZeroSeed() {
        var rng = SplitMix64(seed: 0)
        let produced = (0..<5).map { _ in rng.next() }
        #expect(produced == [
            16_294_208_416_658_607_535,
            7_960_286_522_194_355_700,
            487_617_019_471_545_679,
            17_909_611_376_780_542_444,
            1_961_750_202_426_094_747
        ])
    }

    @Test("A non-zero seed matches its reference vectors")
    func referenceVectorsForNonZeroSeed() {
        var rng = SplitMix64(seed: 1_234_567)
        let produced = (0..<5).map { _ in rng.next() }
        #expect(produced == [
            6_457_827_717_110_365_317,
            3_203_168_211_198_807_973,
            9_817_491_932_198_370_423,
            4_593_380_528_125_082_431,
            16_408_922_859_458_223_821
        ])
    }

    @Test("Two streams from the same seed agree step for step")
    func sameSeedSameStream() {
        var first = SplitMix64(seed: 99)
        var second = SplitMix64(seed: 99)
        for _ in 0..<32 {
            #expect(first.next() == second.next())
        }
    }

    @Test("Different seeds diverge immediately")
    func differentSeedsDiverge() {
        var first = SplitMix64(seed: 1)
        var second = SplitMix64(seed: 2)
        #expect(first.next() != second.next())
    }

    @Test("It drives the standard random APIs")
    func drivesStandardRandomAPIs() {
        var rng = SplitMix64(seed: 7)
        let value = Int.random(in: 0..<10, using: &rng)
        #expect((0..<10).contains(value))

        var replay = SplitMix64(seed: 7)
        #expect(Int.random(in: 0..<10, using: &replay) == value)
    }

    @Test("A unit fraction stays inside the half-open unit interval")
    func unitFractionRange() {
        var rng = SplitMix64(seed: 3)
        for _ in 0..<1_000 {
            let value = rng.nextUnitFraction()
            #expect(value >= 0)
            #expect(value < 1)
        }
    }

    @Test("A bounded draw covers its range and never exceeds it")
    func boundedDraw() {
        var rng = SplitMix64(seed: 11)
        var seen: Set<Int> = []
        for _ in 0..<1_000 {
            let value = rng.nextInt(upperBound: 5)
            #expect(value >= 0)
            #expect(value < 5)
            seen.insert(value)
        }
        #expect(seen == [0, 1, 2, 3, 4])
    }

    @Test("An upper bound of zero or less yields zero")
    func degenerateBound() {
        var rng = SplitMix64(seed: 5)
        #expect(rng.nextInt(upperBound: 0) == 0)
        #expect(rng.nextInt(upperBound: -3) == 0)
    }
}
