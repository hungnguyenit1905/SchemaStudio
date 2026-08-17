//
//  ReferencePoolTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("ReferencePool")
struct ReferencePoolTests {
    private static let key = ReferenceKey(schema: "public", table: "customers", columns: ["id"])

    private static func pool(
        _ strategy: ReferencePoolStrategy,
        values: [Int64] = [1, 2, 3, 4],
        seed: UInt64 = 42,
        rowCount: Int? = nil
    ) throws -> ReferencePool {
        try ReferencePool(
            key: key,
            tuples: values.map { [PluginCellValue.int($0)] },
            strategy: strategy,
            seed: seed,
            rowCount: rowCount
        )
    }

    private static func draw(_ pool: ReferencePool, count: Int) -> [Int64?] {
        (0 ..< count).map { _ in
            guard case .int(let value)? = pool.next()?.first else { return nil }
            return value
        }
    }

    @Test("Random draws stay inside the pool and repeat under the same seed")
    func randomIsSeeded() throws {
        let first = Self.draw(try Self.pool(.random), count: 20)
        let second = Self.draw(try Self.pool(.random), count: 20)
        #expect(first == second)
        #expect(first.allSatisfy { value in [1, 2, 3, 4].contains(value ?? 0) })
    }

    @Test("Round robin walks the pool in order and wraps")
    func roundRobinWraps() throws {
        #expect(Self.draw(try Self.pool(.roundRobin), count: 6) == [1, 2, 3, 4, 1, 2])
    }

    @Test("One to one hands out each parent row once")
    func oneToOneIsExclusive() throws {
        let pool = try Self.pool(.oneToOne, rowCount: 4)
        #expect(Self.draw(pool, count: 4) == [1, 2, 3, 4])
        #expect(pool.next() == nil)
    }

    @Test("One to one is refused when there are more rows than parents")
    func oneToOneRefusesShortPool() {
        #expect(throws: GenerationError.self) {
            _ = try Self.pool(.oneToOne, rowCount: 5)
        }
    }

    @Test("Ensure coverage uses every parent value before repeating one")
    func ensureCoverageCoversPool() throws {
        let drawn = Self.draw(try Self.pool(.ensureCoverage, values: [10, 20, 30, 40, 50]), count: 5)
        #expect(Set(drawn.compactMap { $0 }) == [10, 20, 30, 40, 50])
    }

    @Test("Ensure coverage keeps covering after the pool is exhausted")
    func ensureCoverageCyclesWholePool() throws {
        let pool = try Self.pool(.ensureCoverage, values: [1, 2, 3])
        _ = Self.draw(pool, count: 3)
        #expect(Set(Self.draw(pool, count: 3).compactMap { $0 }) == [1, 2, 3])
    }

    @Test("A reset pool replays its first sequence exactly")
    func resetReplays() throws {
        let pool = try Self.pool(.ensureCoverage)
        let first = Self.draw(pool, count: 8)
        pool.reset()
        #expect(Self.draw(pool, count: 8) == first)
    }

    @Test("An empty pool hands back nothing rather than trapping")
    func emptyPoolIsSafe() throws {
        let pool = try ReferencePool(key: Self.key, tuples: [], strategy: .random, seed: 1)
        #expect(pool.isEmpty)
        #expect(pool.next() == nil)
    }

    @Test("Harvested keys and keys read back from the parent behave identically")
    func harvestedAndLoadedPoolsMatch() throws {
        let harvested = try ReferencePool(
            key: Self.key,
            tuples: [[.int(7)], [.int(8)], [.int(9)]],
            strategy: .random,
            seed: 99
        )
        let loaded = try ReferencePool(
            key: Self.key,
            tuples: [[.int(7)], [.int(8)], [.int(9)]],
            strategy: .random,
            seed: 99
        )
        #expect(Self.draw(harvested, count: 25) == Self.draw(loaded, count: 25))
    }

    @Test("A composite pool hands out whole parent tuples")
    func compositeTuplesStayTogether() throws {
        let key = ReferenceKey(schema: "public", table: "regions", columns: ["country", "code"])
        let tuples: [[PluginCellValue]] = [
            [.text("VN"), .text("HCM")],
            [.text("US"), .text("NY")]
        ]
        let pool = try ReferencePool(key: key, tuples: tuples, strategy: .roundRobin, seed: 5)
        let drawn = (0 ..< 4).compactMap { _ in pool.next()?.map(\.textFallback) }
        #expect(drawn == [["VN", "HCM"], ["US", "NY"], ["VN", "HCM"], ["US", "NY"]])
        #expect(pool.value(forColumn: "code", in: tuples[0])?.textFallback == "HCM")
    }
}

@Suite("GenerationProgressThrottle")
struct GenerationProgressThrottleTests {
    @Test("A million ticks stay inside the throttle budget")
    func millionTicksAreThrottled() {
        var throttle = GenerationProgressThrottle()
        let total = 1_000_000
        var emitted = 0
        var now: TimeInterval = 0
        for row in 1 ... total {
            now += 0.000_01
            if throttle.shouldEmit(rowsWritten: row, totalRows: total, now: now) { emitted += 1 }
        }
        #expect(emitted <= Int(now / GenerationProgressThrottle.defaultInterval) + 2)
        #expect(emitted > 0)
    }

    @Test("A slow table still reports on the time budget")
    func timeBudgetEmits() {
        var throttle = GenerationProgressThrottle()
        var emitted = 0
        var now: TimeInterval = 0
        for row in 1 ... 10 {
            now += 0.25
            if throttle.shouldEmit(rowsWritten: row, totalRows: 1_000_000, now: now) { emitted += 1 }
        }
        #expect(emitted == 10)
    }

    @Test("The same row count is never reported twice")
    func repeatedCountsAreDropped() {
        var throttle = GenerationProgressThrottle()
        let first = throttle.shouldEmit(rowsWritten: 100, totalRows: 100, now: 0)
        let repeated = throttle.shouldEmit(rowsWritten: 100, totalRows: 100, now: 10)
        #expect(first)
        #expect(!repeated)
    }

    @Test("A reset throttle reports the next tick immediately")
    func resetReportsAgain() {
        var throttle = GenerationProgressThrottle()
        let first = throttle.shouldEmit(rowsWritten: 10, totalRows: 100, now: 0)
        throttle.reset()
        let afterReset = throttle.shouldEmit(rowsWritten: 1, totalRows: 100, now: 0)
        #expect(first)
        #expect(afterReset)
    }
}
