//
//  DistributionTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Distributions")
struct DistributionTests {
    private static let sampleCount = 100_000

    private func distribution(_ json: String) throws -> Distribution {
        try Distribution(params: Data(json.utf8), generator: "Integer")
    }

    private func samples(
        _ distribution: Distribution,
        in range: ClosedRange<Double>,
        seed: UInt64 = 99
    ) -> [Double] {
        var rng = SplitMix64(seed: seed)
        return (0..<Self.sampleCount).map { _ in distribution.sample(in: range, using: &rng) }
    }

    private func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        let average = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)
        return variance.squareRoot()
    }

    @Test("Uniform spreads evenly over the range")
    func uniformIsFlat() throws {
        let values = samples(try distribution(#"{}"#), in: 0...100)
        #expect(abs(mean(values) - 50) < 1)
        #expect(values.allSatisfy { (0...100).contains($0) })
    }

    @Test("Normal lands on the requested mean and spread")
    func normalStatistics() throws {
        let values = samples(
            try distribution(#"{"distribution":"normal","mean":100,"stddev":15}"#),
            in: 0...200
        )
        #expect(abs(mean(values) - 100) < 1)
        #expect(abs(standardDeviation(values) - 15) < 1)
        #expect(values.allSatisfy { (0...200).contains($0) })
    }

    @Test("Normal centres on the range when no mean is given")
    func normalDefaultsToTheRange() throws {
        let values = samples(try distribution(#"{"distribution":"normal"}"#), in: 0...60)
        #expect(abs(mean(values) - 30) < 1)
        #expect(abs(standardDeviation(values) - 10) < 1)
    }

    @Test("Exponential piles values towards the minimum")
    func exponentialStatistics() throws {
        let values = samples(try distribution(#"{"distribution":"exponential","lambda":2}"#), in: 0...100)
        #expect(abs(mean(values) - 34.3) < 1.5)
        #expect(values.allSatisfy { (0...100).contains($0) })
        let firstQuarter = values.filter { $0 < 25 }.count
        let lastQuarter = values.filter { $0 >= 75 }.count
        #expect(firstQuarter > lastQuarter * 2)
    }

    @Test("A higher rate pushes more values towards the minimum")
    func higherRatesSkewHarder() throws {
        let gentle = mean(samples(try distribution(#"{"distribution":"exponential","lambda":1}"#), in: 0...100))
        let steep = mean(samples(try distribution(#"{"distribution":"exponential","lambda":6}"#), in: 0...100))
        #expect(steep < gentle)
    }

    @Test("Every shape repeats under a fixed seed and moves with a different one")
    func deterministicUnderAFixedSeed() throws {
        for json in [
            #"{}"#,
            #"{"distribution":"normal","mean":10,"stddev":3}"#,
            #"{"distribution":"exponential","lambda":2}"#
        ] {
            let shaped = try distribution(json)
            #expect(samples(shaped, in: 0...50, seed: 4) == samples(shaped, in: 0...50, seed: 4))
            #expect(samples(shaped, in: 0...50, seed: 4) != samples(shaped, in: 0...50, seed: 5))
        }
    }

    @Test("A spread of zero or a rate of zero is refused")
    func invalidParametersThrow() {
        #expect(throws: GenerationError.self) {
            _ = try distribution(#"{"distribution":"normal","stddev":0}"#)
        }
        #expect(throws: GenerationError.self) {
            _ = try distribution(#"{"distribution":"exponential","lambda":0}"#)
        }
    }

    @Test("A non-finite mean, standard deviation or rate is refused rather than sampled")
    func nonFiniteParametersThrow() {
        #expect(throws: GenerationError.self) {
            _ = try distribution(#"{"distribution":"normal","mean":1e400}"#)
        }
        #expect(throws: GenerationError.self) {
            _ = try distribution(#"{"distribution":"normal","stddev":1e400}"#)
        }
        #expect(throws: GenerationError.self) {
            _ = try distribution(#"{"distribution":"exponential","lambda":1e400}"#)
        }
    }

    // MARK: - Zipf

    @Test("Zipf gives the head of the pool most of the draws")
    func zipfIsSkewed() {
        let zipf = ZipfDistribution(count: 1_000, exponent: 1)
        var rng = SplitMix64(seed: 17)
        var counts = [Int](repeating: 0, count: 1_000)
        for _ in 0..<100_000 {
            counts[zipf.nextRank(using: &rng)] += 1
        }
        let head = counts[0..<10].reduce(0, +)
        let tail = counts[990..<1_000].reduce(0, +)
        #expect(head > tail * 20)
        #expect(counts[0] > counts[1])
    }

    @Test("A higher exponent concentrates the draws further")
    func zipfExponentSharpensTheHead() {
        func headShare(exponent: Double) -> Int {
            let zipf = ZipfDistribution(count: 500, exponent: exponent)
            var rng = SplitMix64(seed: 23)
            return (0..<20_000).reduce(0) { total, _ in
                total + (zipf.nextRank(using: &rng) < 5 ? 1 : 0)
            }
        }
        #expect(headShare(exponent: 1.5) > headShare(exponent: 0.5))
    }

    @Test("Zipf repeats under a fixed seed")
    func zipfIsDeterministic() {
        func ranks(seed: UInt64) -> [Int] {
            let zipf = ZipfDistribution(count: 100, exponent: 1)
            var rng = SplitMix64(seed: seed)
            return (0..<1_000).map { _ in zipf.nextRank(using: &rng) }
        }
        #expect(ranks(seed: 8) == ranks(seed: 8))
        #expect(ranks(seed: 8) != ranks(seed: 9))
    }

    // MARK: - Wiring

    private func column(_ dataType: String) -> GenerationColumn {
        GeneratorTestFixtures.column(name: "amount", dataType: dataType)
    }

    private func numbers(_ generator: any ValueGenerator, count: Int) throws -> [Double] {
        try (0..<count).map { index in
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(), index: index)
            switch value {
            case .int(let number): return Double(number)
            case .double(let number): return number
            case .decimalText(let text): return Double(text) ?? .nan
            default:
                Issue.record("\(value) is not a number")
                return .nan
            }
        }
    }

    @Test("Integer honours a normal distribution")
    func integerIsShaped() throws {
        let generator = try IntegerGenerator(
            params: Data(#"{"min":0,"max":100,"distribution":"normal","mean":80,"stddev":5}"#.utf8),
            column: column("integer"),
            seed: 31
        )
        let values = try numbers(generator, count: 20_000)
        #expect(abs(mean(values) - 80) < 1)
        #expect(values.allSatisfy { (0...100).contains($0) })
    }

    @Test("Decimal honours a distribution in the column's own units")
    func decimalIsShaped() throws {
        let generator = try DecimalGenerator(
            params: Data(#"{"min":0,"max":1000,"scale":2,"distribution":"normal","mean":250,"stddev":20}"#.utf8),
            column: column("numeric(10,2)"),
            seed: 31
        )
        let values = try numbers(generator, count: 20_000)
        #expect(abs(mean(values) - 250) < 2)
        #expect(values.allSatisfy { (0...1_000).contains($0) })
    }

    @Test("Double honours an exponential distribution")
    func doubleIsShaped() throws {
        let generator = try DoubleGenerator(
            params: Data(#"{"min":0,"max":10,"distribution":"exponential","lambda":4}"#.utf8),
            column: column("double precision"),
            seed: 31
        )
        let values = try numbers(generator, count: 20_000)
        #expect(mean(values) < 4)
        #expect(values.allSatisfy { (0...10).contains($0) })
    }

    @Test("A uniform numeric generator produces the values it always did")
    func uniformOutputIsUnchanged() throws {
        func values(_ params: String) throws -> [Double] {
            try numbers(
                IntegerGenerator(params: Data(params.utf8), column: column("integer"), seed: 77),
                count: 50
            )
        }
        #expect(try values(#"{"min":0,"max":100}"#) == values(#"{"min":0,"max":100,"distribution":"uniform"}"#))
    }

    @Test("Reference weighted sends most children to a few parents")
    func referenceWeightedIsSkewed() throws {
        let generator = try ReferenceGenerator(
            params: Data(#"{"table":"parent","column":"id","strategy":"weighted","skew":1.2}"#.utf8),
            column: GeneratorTestFixtures.column(name: "parent_id", dataType: "bigint"),
            seed: 13
        )
        let pool = ReferenceValuePool(
            target: generator.referenceTarget,
            values: (1...200).map { PluginCellValue.int(Int64($0)) }
        )
        generator.bind(pool: pool)
        var counts: [PluginCellValue: Int] = [:]
        for index in 0..<20_000 {
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(), index: index)
            counts[value, default: 0] += 1
        }
        let ranked = counts.values.sorted(by: >)
        let head = ranked.prefix(10).reduce(0, +)
        #expect(head > 20_000 / 4)
        #expect(counts.count > 1)
    }

    @Test("Reference weighted repeats under a fixed seed")
    func referenceWeightedIsDeterministic() throws {
        func draws(seed: UInt64) throws -> [PluginCellValue] {
            let generator = try ReferenceGenerator(
                params: Data(#"{"table":"parent","column":"id","strategy":"weighted"}"#.utf8),
                column: GeneratorTestFixtures.column(name: "parent_id", dataType: "bigint"),
                seed: seed
            )
            generator.bind(
                pool: ReferenceValuePool(
                    target: generator.referenceTarget,
                    values: (1...50).map { PluginCellValue.int(Int64($0)) }
                )
            )
            return try (0..<500).map { index in
                try generator.next(row: GeneratorTestFixtures.rowContext(), index: index)
            }
        }
        #expect(try draws(seed: 2) == draws(seed: 2))
        #expect(try draws(seed: 2) != draws(seed: 3))
    }
}
