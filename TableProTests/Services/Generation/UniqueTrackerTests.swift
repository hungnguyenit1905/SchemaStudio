//
//  UniqueTrackerTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("UniqueTracker")
struct UniqueTrackerTests {
    @Test("A hundred thousand distinct values are all admitted once")
    func admitsDistinctValues() {
        var tracker = UniqueTracker(expectedCount: 100_000)
        var admittedAll = true
        for value in 0 ..< 100_000 where !tracker.admit(.int(Int64(value))) {
            admittedAll = false
        }
        #expect(admittedAll)
        #expect(tracker.count == 100_000)
        let repeated = tracker.admit(.int(0))
        #expect(!repeated)
    }

    @Test("A repeated value is refused whatever its case, under a case-insensitive collation")
    func caseInsensitiveMatching() {
        var sensitive = UniqueTracker(matching: .exact)
        let mixedCase = sensitive.admit(.text("Alice"))
        let lowerCase = sensitive.admit(.text("alice"))
        #expect(mixedCase)
        #expect(lowerCase)

        var insensitive = UniqueTracker(matching: .caseInsensitive)
        let first = insensitive.admit(.text("Alice"))
        let sameLowered = insensitive.admit(.text("alice"))
        let sameUppered = insensitive.admit(.text("ALICE"))
        let other = insensitive.admit(.text("bob"))
        #expect(first)
        #expect(!sameLowered)
        #expect(!sameUppered)
        #expect(other)
    }

    @Test("Resetting forgets everything and keeps the capacity")
    func resetForgets() {
        var tracker = UniqueTracker()
        let first = tracker.admit(.text("a"))
        #expect(first)
        tracker.reset()
        #expect(tracker.count == 0)
        let again = tracker.admit(.text("a"))
        #expect(again)
    }

    @Test("Types that render alike are still separate values")
    func typesAreDistinct() {
        var tracker = UniqueTracker()
        let integer = tracker.admit(.int(1))
        let text = tracker.admit(.text("1"))
        let decimal = tracker.admit(.decimalText("1"))
        let boolean = tracker.admit(.bool(true))
        #expect(integer)
        #expect(text)
        #expect(decimal)
        #expect(boolean)
    }

    @Test(
        "A collation the server compares case-blind is detected",
        arguments: [
            ("utf8mb4_general_ci", UniqueMatching.caseInsensitive),
            ("utf8mb4_0900_ai_ci", UniqueMatching.caseInsensitive),
            ("NOCASE", UniqueMatching.caseInsensitive),
            ("utf8mb4_bin", UniqueMatching.exact),
            ("en_US.utf8", UniqueMatching.exact),
            ("", UniqueMatching.exact)
        ]
    )
    func collationDetection(collation: String, expected: UniqueMatching) {
        let column = AutoMapFixtures.column("email", "varchar(64)", collation: collation)
        #expect(UniqueMatching.resolve(for: column) == expected)
    }

    @Test("A missing collation is treated as case-sensitive rather than guessed at")
    func missingCollationStaysExact() {
        let column = AutoMapFixtures.column("email", "varchar(64)")
        #expect(UniqueMatching.resolve(for: column) == .exact)
    }

    @Test("PostgreSQL's citext is case-blind whatever the collation says")
    func citextIsCaseInsensitive() {
        let column = AutoMapFixtures.column("email", "citext")
        #expect(UniqueMatching.resolve(for: column) == .caseInsensitive)
    }
}

@Suite("ShuffledRangeSource")
struct ShuffledRangeSourceTests {
    @Test("The whole domain comes out exactly once")
    func coversTheDomainOnce() throws {
        var source = try #require(ShuffledRangeSource(domain: 1 ... 500, seed: 42))
        var drawn: [Int64] = []
        while let value = source.next() { drawn.append(value) }
        #expect(drawn.count == 500)
        #expect(Set(drawn).count == 500)
        #expect(drawn.min() == 1)
        #expect(drawn.max() == 500)
    }

    @Test("A drawn-out domain reports itself exhausted instead of repeating")
    func exhaustionIsReported() throws {
        var source = try #require(ShuffledRangeSource(domain: 1 ... 3, seed: 7))
        let drawn = [source.next(), source.next(), source.next()]
        let exhausted = source.next()
        #expect(drawn.compactMap { $0 }.count == 3)
        #expect(exhausted == nil)
    }

    @Test("The same seed draws the same order, a different seed does not")
    func orderIsSeeded() throws {
        func draw(seed: UInt64) throws -> [Int64] {
            var source = try #require(ShuffledRangeSource(domain: 1 ... 200, seed: seed))
            var values: [Int64] = []
            while let value = source.next() { values.append(value) }
            return values
        }
        let first = try draw(seed: 99)
        #expect(try first == draw(seed: 99))
        #expect(try first != draw(seed: 100))
    }

    @Test("The order is shuffled, not the domain in ascending order")
    func orderIsNotSequential() throws {
        var source = try #require(ShuffledRangeSource(domain: 1 ... 1_000, seed: 3))
        var drawn: [Int64] = []
        while let value = source.next() { drawn.append(value) }
        #expect(drawn != drawn.sorted())
    }

    @Test("Resetting draws the same order again")
    func resetRepeatsTheOrder() throws {
        var source = try #require(ShuffledRangeSource(domain: 1 ... 50, seed: 11))
        let first = (0 ..< 50).compactMap { _ in source.next() }
        source.reset()
        let second = (0 ..< 50).compactMap { _ in source.next() }
        #expect(first == second)
    }

    @Test("A negative domain is handled like any other")
    func negativeDomain() throws {
        var source = try #require(ShuffledRangeSource(domain: -10 ... 10, seed: 5))
        var drawn: [Int64] = []
        while let value = source.next() { drawn.append(value) }
        #expect(Set(drawn).count == 21)
        #expect(drawn.min() == -10)
    }

    @Test("A domain too wide to shuffle is refused, so the caller tracks instead")
    func oversizedDomainIsRefused() {
        #expect(ShuffledRangeSource(domain: 0 ... Int64(ShuffledRangeSource.maximumDomain), seed: 1) == nil)
        #expect(ShuffledRangeSource(domain: Int64.min ... Int64.max, seed: 1) == nil)
        #expect(ShuffledRangeSource(domain: 0 ... Int64(ShuffledRangeSource.maximumDomain - 1), seed: 1) != nil)
    }

    @Test("Drawing a few values from a wide domain costs a few values of memory")
    func lazyShuffleStaysSmall() throws {
        var source = try #require(ShuffledRangeSource(domain: 1 ... 9_000_000, seed: 1))
        let drawn = (0 ..< 1_000).compactMap { _ in source.next() }
        #expect(Set(drawn).count == 1_000)
        #expect(source.remaining == 9_000_000 - 1_000)
    }
}

@Suite("DecoratedGenerator uniqueness")
struct DecoratedGeneratorUniquenessTests {
    private func generator(
        _ identifier: String,
        column: GenerationColumn,
        params: JSONValue = .object([:]),
        common: CommonParams = CommonParams(unique: true),
        rowCount: Int = 100
    ) throws -> DecoratedGenerator {
        let profile = GenerationColumnProfile(column: column.name, generator: identifier, params: params)
        let inner = try GeneratorRegistry.standard.make(
            identifier: identifier,
            params: profile.paramData,
            column: column,
            seed: 21
        )
        return DecoratedGenerator(
            inner: inner,
            column: column,
            common: common,
            truncator: GenerationStringTruncator(unit: .unicodeScalars),
            seed: 21,
            rowCount: rowCount
        )
    }

    private func values(_ generator: DecoratedGenerator, count: Int) throws -> [PluginCellValue] {
        let context = RowContext(table: "t", rowIndex: 0)
        return try (0 ..< count).map { try generator.next(row: context, index: $0) }
    }

    @Test("A unique integer column over a finite domain fills it exactly")
    func shuffledRangeFillsTheDomain() throws {
        let column = AutoMapFixtures.column("code", "integer", isNullable: false)
        let decorated = try generator(
            "Integer",
            column: column,
            params: .object(["min": .int(1), "max": .int(100)]),
            rowCount: 100
        )
        let drawn = try values(decorated, count: 100)
        #expect(Set(drawn.map(\.stableHash)).count == 100)
    }

    @Test("A domain smaller than the row count fails instead of retrying forever")
    func shuffledRangeExhausts() throws {
        let column = AutoMapFixtures.column("code", "integer", isNullable: false)
        let decorated = try generator(
            "Integer",
            column: column,
            params: .object(["min": .int(1), "max": .int(10)]),
            rowCount: 20
        )
        _ = try values(decorated, count: 10)
        #expect(throws: GenerationError.self) {
            _ = try decorated.next(row: RowContext(table: "t", rowIndex: 10), index: 10)
        }
    }

    @Test("A tracked column refuses duplicates and gives up with an actionable error")
    func trackedColumnExhausts() throws {
        let column = AutoMapFixtures.column("flag", "boolean", isNullable: false)
        let decorated = try generator("Boolean", column: column, rowCount: 10)
        _ = try values(decorated, count: 2)
        let error = #expect(throws: GenerationError.self) {
            _ = try decorated.next(row: RowContext(table: "t", rowIndex: 2), index: 2)
        }
        #expect(error?.recoverySuggestion?.isEmpty == false)
        #expect(error?.errorDescription?.contains("flag") == true)
    }

    @Test("An inherently sequential generator is trusted with no tracking")
    func trustedStrategyForSequentialGenerators() throws {
        let column = AutoMapFixtures.column("serial", "bigint", isNullable: false)
        let strategy = DecoratedGenerator.strategy(
            inner: try CountingTestGenerator(params: Data(), column: column, seed: 1),
            column: column,
            common: CommonParams(unique: true),
            rowCount: 10,
            seed: 1
        )
        guard case .trusted = strategy else {
            Issue.record("expected the counter strategy, got \(strategy)")
            return
        }
    }

    @Test("A column the server fills is never tracked, whatever the schema says about it")
    func serverAssignedColumnIsNotTracked() throws {
        let column = AutoMapFixtures.column(
            "id",
            "bigint",
            isNullable: false,
            isPrimaryKey: true,
            identityKind: .always
        )
        let inner = try GeneratorRegistry.standard.make(
            identifier: "Default",
            params: Data(),
            column: column,
            seed: 1
        )
        let strategy = DecoratedGenerator.strategy(
            inner: inner,
            column: column,
            common: CommonParams(unique: true),
            rowCount: 10,
            seed: 1
        )
        guard case .off = strategy else {
            Issue.record("expected no tracking, got \(strategy)")
            return
        }
    }

    @Test("Nulls are not constrained by a unique index, so they are not tracked")
    func nullsAreNotTracked() throws {
        let column = AutoMapFixtures.column("manager_id", "bigint")
        let inner = try GeneratorRegistry.standard.make(
            identifier: "Null",
            params: Data(),
            column: column,
            seed: 1
        )
        let decorated = DecoratedGenerator(
            inner: inner,
            column: column,
            common: CommonParams(unique: true),
            truncator: GenerationStringTruncator(unit: .unicodeScalars),
            seed: 1,
            rowCount: 10
        )
        let context = RowContext(table: "t", rowIndex: 0)
        for index in 0 ..< 5 {
            #expect(try decorated.next(row: context, index: index) == PluginCellValue.null)
        }
    }

    @Test("A column with nothing to keep distinct is not tracked at all")
    func noStrategyWithoutUniqueness() throws {
        let column = AutoMapFixtures.column("note", "varchar(40)")
        let inner = try GeneratorRegistry.standard.make(
            identifier: "LoremWords",
            params: Data(),
            column: column,
            seed: 1
        )
        let strategy = DecoratedGenerator.strategy(
            inner: inner,
            column: column,
            common: .none,
            rowCount: 10,
            seed: 1
        )
        guard case .off = strategy else {
            Issue.record("expected no tracking, got \(strategy)")
            return
        }
    }

    @Test("A unique column carrying an affix is tracked, not shuffled")
    func affixForcesTracking() throws {
        let column = AutoMapFixtures.column("code", "integer", isNullable: false)
        let inner = try GeneratorRegistry.standard.make(
            identifier: "Integer",
            params: Data(#"{"min":1,"max":100}"#.utf8),
            column: column,
            seed: 1
        )
        let strategy = DecoratedGenerator.strategy(
            inner: inner,
            column: column,
            common: CommonParams(unique: true, prefix: "x-"),
            rowCount: 10,
            seed: 1
        )
        guard case .tracked = strategy else {
            Issue.record("expected tracking, got \(strategy)")
            return
        }
    }

    @Test("A column that sometimes writes null is tracked, not shuffled")
    func nullPercentForcesTracking() throws {
        let column = AutoMapFixtures.column("code", "integer")
        let inner = try GeneratorRegistry.standard.make(
            identifier: "Integer",
            params: Data(#"{"min":1,"max":100}"#.utf8),
            column: column,
            seed: 1
        )
        let strategy = DecoratedGenerator.strategy(
            inner: inner,
            column: column,
            common: CommonParams(nullPercent: 5, unique: true),
            rowCount: 100,
            seed: 1
        )
        guard case .tracked = strategy else {
            Issue.record("expected tracking, got \(strategy)")
            return
        }
    }

    @Test("A domain sized to the row count survives a run that also writes nulls")
    func nullsDoNotConsumeTheDomain() throws {
        let column = AutoMapFixtures.column("code", "integer")
        let profile = GenerationColumnProfile(
            column: "code",
            generator: "Integer",
            params: .object(["min": .int(1), "max": .int(50)])
        )
        let inner = try GeneratorRegistry.standard.make(
            identifier: "Integer",
            params: profile.paramData,
            column: column,
            seed: 21
        )
        let decorated = DecoratedGenerator(
            inner: inner,
            column: column,
            common: CommonParams(nullPercent: 40, unique: true),
            truncator: GenerationStringTruncator(unit: .unicodeScalars),
            seed: 21,
            rowCount: 50
        )
        let context = RowContext(table: "t", rowIndex: 0)
        var written: [PluginCellValue] = []
        for index in 0 ..< 50 {
            written.append(try decorated.next(row: context, index: index))
        }
        let values = written.filter { if case .null = $0 { return false } else { return true } }
        #expect(values.count < 50)
        #expect(Set(values.map(\.stableHash)).count == values.count)
    }

    @Test("A column the schema declares unique is kept distinct without being asked")
    func schemaUniquenessIsEnough() throws {
        let column = AutoMapFixtures.column(
            "email",
            "varchar(64)",
            isNullable: false,
            indexes: [PluginIndexInfo(name: "t_email_key", columns: ["email"], isUnique: true)]
        )
        let decorated = try generator("Boolean", column: column, common: .none, rowCount: 10)
        _ = try values(decorated, count: 2)
        #expect(throws: GenerationError.self) {
            _ = try decorated.next(row: RowContext(table: "t", rowIndex: 2), index: 2)
        }
    }
}

/// Stands in for the sequential generators the catalog will grow (`Sequence`):
/// its values never repeat and it does write to the column, which is the pair of
/// facts the counter strategy needs.
private final class CountingTestGenerator: ValueGenerator {
    static let identifier = "CountingTestGenerator"

    private var emitted: Int64 = 0

    init(params: Data, column: GenerationColumn, seed: UInt64) throws {}

    var producesDistinctValues: Bool { true }

    func next(row: RowContext, index: Int) throws -> PluginCellValue {
        defer { emitted += 1 }
        return .int(emitted)
    }

    func reset() {
        emitted = 0
    }
}
