//
//  ReferenceStrategyTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The per-column half of the strategy table. `ReferencePoolTests` covers the
/// same vocabulary on the composite path, and both now run the same picker.
@Suite("Reference strategies")
struct ReferenceStrategyTests {
    private static func generator(
        _ strategy: String,
        pool: [Int64] = [1, 2, 3, 4],
        seed: UInt64 = 7,
        skew: Double? = nil
    ) throws -> ReferenceGenerator {
        let skewText = skew.map { ",\"skew\":\($0)" } ?? ""
        let generator = try ReferenceGenerator(
            params: Data(#"{"table":"parent","column":"id","strategy":"\#(strategy)"\#(skewText)}"#.utf8),
            column: GeneratorTestFixtures.column(name: "parent_id", dataType: "bigint"),
            seed: seed
        )
        generator.bind(
            pool: ReferenceValuePool(
                target: generator.referenceTarget,
                values: pool.map { PluginCellValue.int($0) }
            )
        )
        return generator
    }

    private func draw(_ generator: ReferenceGenerator, count: Int) throws -> [Int64] {
        try (0..<count).map { index in
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(rowIndex: index), index: index)
            guard case let .int(number) = value else {
                Issue.record("\(value) is not a key")
                return 0
            }
            return number
        }
    }

    @Test("Round robin walks the pool in order and wraps")
    func roundRobinWraps() throws {
        #expect(try draw(Self.generator("roundRobin"), count: 6) == [1, 2, 3, 4, 1, 2])
    }

    @Test("One to one uses each parent row exactly once")
    func oneToOneIsExclusive() throws {
        #expect(try draw(Self.generator("oneToOne"), count: 4) == [1, 2, 3, 4])
    }

    @Test("One to one refuses to hand out a parent row twice")
    func oneToOneRefusesToRepeat() throws {
        let generator = try Self.generator("oneToOne")
        _ = try draw(generator, count: 4)
        #expect(throws: GenerationError.self) {
            _ = try generator.next(row: GeneratorTestFixtures.rowContext(rowIndex: 4), index: 4)
        }
    }

    @Test("Ensure coverage uses every parent before repeating one")
    func ensureCoverageCoversPool() throws {
        let drawn = try draw(Self.generator("ensureCoverage", pool: [10, 20, 30, 40, 50]), count: 5)
        #expect(Set(drawn) == [10, 20, 30, 40, 50])
    }

    @Test("Ensure coverage keeps covering after the pool is used up")
    func ensureCoverageCyclesWholePool() throws {
        let generator = try Self.generator("ensureCoverage", pool: [1, 2, 3])
        _ = try draw(generator, count: 3)
        #expect(try Set(draw(generator, count: 3)) == [1, 2, 3])
    }

    @Test("Every strategy repeats under a fixed seed", arguments: ReferenceStrategy.allCases)
    func deterministicUnderAFixedSeed(strategy: ReferenceStrategy) throws {
        let first = try draw(Self.generator(strategy.rawValue, pool: Array(1...20)), count: 20)
        let second = try draw(Self.generator(strategy.rawValue, pool: Array(1...20)), count: 20)
        #expect(first == second)
    }

    @Test("A reset column replays its first sequence exactly", arguments: ReferenceStrategy.allCases)
    func resetReplays(strategy: ReferenceStrategy) throws {
        let generator = try Self.generator(strategy.rawValue, pool: Array(1...8))
        let first = try draw(generator, count: 8)
        generator.reset()
        generator.bind(
            pool: ReferenceValuePool(
                target: generator.referenceTarget,
                values: (1...8).map { PluginCellValue.int(Int64($0)) }
            )
        )
        #expect(try draw(generator, count: 8) == first)
    }

    @Test("The strategy is readable before the run so the pool can be measured")
    func strategyIsDeclared() throws {
        #expect(try Self.generator("oneToOne").poolStrategy == .oneToOne)
        #expect(try Self.generator("random").poolStrategy == .random)
    }

    @Test("A query column refuses a strategy that needs a parent row per row")
    func queriesRefusePairingStrategies() {
        for strategy in [ReferenceStrategy.oneToOne, .ensureCoverage] {
            #expect(throws: GenerationError.self) {
                _ = try SqlQueryGenerator(
                    params: Data(#"{"query":"SELECT id FROM users","strategy":"\#(strategy.rawValue)"}"#.utf8),
                    column: GeneratorTestFixtures.column(),
                    seed: 1
                )
            }
        }
    }

    @Test("Only the free-drawing strategies are offered to a query column")
    func queryStrategyChoices() throws {
        let field = try #require(SqlQueryGenerator.paramSchema.fields.first { $0.key == "strategy" })
        guard case let .choice(choices) = field.type else {
            Issue.record("the strategy field is not a choice")
            return
        }
        #expect(choices.map(\.value) == ["random", "roundRobin", "weighted"])
    }

    @Test("A reference column offers the whole strategy table")
    func referenceStrategyChoices() throws {
        let field = try #require(ReferenceGenerator.paramSchema.fields.first { $0.key == "strategy" })
        guard case let .choice(choices) = field.type else {
            Issue.record("the strategy field is not a choice")
            return
        }
        #expect(choices.map(\.value) == ReferenceStrategy.allCases.map(\.rawValue))
    }
}
