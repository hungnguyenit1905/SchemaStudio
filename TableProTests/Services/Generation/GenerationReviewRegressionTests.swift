//
//  GenerationReviewRegressionTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Dependency resolution regressions")
struct DependencyResolverRegressionTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func nullableColumn(_ name: String) -> PluginColumnInfo {
        PluginColumnInfo(name: name, dataType: "bigint", isNullable: true)
    }

    private func requiredColumn(_ name: String) -> PluginColumnInfo {
        PluginColumnInfo(name: name, dataType: "bigint", isNullable: false)
    }

    @Test("The resolved order does not depend on set iteration order")
    func orderIsStableAcrossResolves() throws {
        let schema = Fixtures.shopSchema + [
            Fixtures.table(
                "invoices",
                columns: [Fixtures.identityColumn(), requiredColumn("customer_id")],
                foreignKeys: [Fixtures.foreignKey(from: "customer_id", to: "customers")]
            ),
            Fixtures.table(
                "shipments",
                columns: [Fixtures.identityColumn(), requiredColumn("order_id")],
                foreignKeys: [Fixtures.foreignKey(from: "order_id", to: "orders")]
            )
        ]
        let first = try DependencyResolver().resolve(schema).ordered.map(\.qualifiedName)
        for _ in 0 ..< 25 {
            #expect(try DependencyResolver().resolve(schema).ordered.map(\.qualifiedName) == first)
        }
    }

    @Test("A NOT NULL key to the same parent is not broken by a nullable sibling")
    func notNullSiblingKeepsTheEdge() throws {
        let schema = [
            Fixtures.table("people", columns: [Fixtures.identityColumn()]),
            Fixtures.table(
                "bookings",
                columns: [
                    Fixtures.identityColumn(),
                    requiredColumn("owner_id"),
                    nullableColumn("approver_id")
                ],
                foreignKeys: [
                    Fixtures.foreignKey(from: "owner_id", to: "people", name: "fk_owner"),
                    Fixtures.foreignKey(from: "approver_id", to: "people", name: "fk_approver")
                ]
            )
        ]
        let order = try DependencyResolver().resolve(schema)
        let people = try #require(order.ordered.firstIndex { $0.table == "people" })
        let bookings = try #require(order.ordered.firstIndex { $0.table == "bookings" })
        #expect(people < bookings)
        #expect(order.deferredColumns.isEmpty)
    }

    @Test("A NOT NULL self reference is refused before the run starts")
    func notNullSelfReferenceIsRejected() {
        let schema = [
            Fixtures.table(
                "category",
                columns: [Fixtures.identityColumn(), requiredColumn("parent_id")],
                foreignKeys: [Fixtures.foreignKey(from: "parent_id", to: "category")]
            )
        ]
        #expect(throws: GenerationError.self) {
            try DependencyResolver().resolve(schema)
        }
    }

    @Test("A nullable self reference is still deferred rather than refused")
    func nullableSelfReferenceIsDeferred() throws {
        let schema = [
            Fixtures.table(
                "employees",
                columns: [Fixtures.identityColumn(), nullableColumn("manager_id")],
                foreignKeys: [Fixtures.foreignKey(from: "manager_id", to: "employees")]
            )
        ]
        let order = try DependencyResolver().resolve(schema)
        #expect(order.deferredColumns.values.flatMap { $0 }.contains("manager_id"))
    }
}

@Suite("Regex quantifier bounds")
struct RegexRepeatCapRegressionTests {
    /// The repeat cap no longer bounds an explicit count: only the
    /// synthesizer's own output budget does, so a runaway `{n}` or `{n,m}` is
    /// still finite, just not by the same number the user set for `*`/`+`/`{n,}`.
    @Test(
        "An explicit or fully bounded count is limited by the output budget, not the repeat cap",
        arguments: ["[a-z]{1,10000000}", "[a-z]{5000}"]
    )
    func explicitCountStaysWithinTheOutputBudget(pattern: String) throws {
        let node = try RegexPatternParser.parse(pattern, repeatCap: 12)
        var rng = SplitMix64(seed: 7)
        for _ in 0 ..< 50 {
            #expect(RegexStringSynthesizer.synthesize(node, budget: 200, using: &rng).count <= 200)
        }
    }

    @Test("An explicit {n} is honoured exactly, uncapped by the repeat cap")
    func explicitCountIsExact() throws {
        let node = try RegexPatternParser.parse("[A-F0-9]{32}", repeatCap: 12)
        var rng = SplitMix64(seed: 7)
        #expect(RegexStringSynthesizer.synthesize(node, using: &rng).count == 32)
    }

    @Test("An explicit {n,m} produces a length inside its own range, uncapped")
    func boundedRangeStaysWithinItsOwnBounds() throws {
        let node = try RegexPatternParser.parse("[a-z]{20,30}", repeatCap: 12)
        var rng = SplitMix64(seed: 7)
        for _ in 0 ..< 50 {
            let length = RegexStringSynthesizer.synthesize(node, using: &rng).count
            #expect((20...30).contains(length))
        }
    }

    @Test("An open-ended {n,} still stops at the repeat cap")
    func openEndedRepeatIsStillCapped() throws {
        let node = try RegexPatternParser.parse("[a-z]{9000,}", repeatCap: 12)
        var rng = SplitMix64(seed: 7)
        for _ in 0 ..< 50 {
            #expect(RegexStringSynthesizer.synthesize(node, using: &rng).count == 12)
        }
    }

    @Test("An explicit count longer than the column is refused, naming the limit")
    func explicitCountLongerThanColumnIsRefused() {
        do {
            _ = try RegexGenerator(
                params: GeneratorTestFixtures.params(#"{"pattern":"[a-z]{5000}"}"#),
                column: GeneratorTestFixtures.column(dataType: "varchar(10)"),
                seed: 1
            )
            Issue.record("a pattern whose shortest match cannot fit the column was accepted")
        } catch let error as GenerationError {
            #expect(error.errorDescription?.contains("10") == true)
        } catch {
            Issue.record("threw \(error)")
        }
    }

    @Test("A descending count is still rejected")
    func descendingCountThrows() {
        #expect(throws: RegexPatternError.self) {
            _ = try RegexPatternParser.parse("[a-z]{5,3}", repeatCap: 12)
        }
    }

    @Test("A count inside the cap is honoured exactly")
    func countWithinCapIsExact() throws {
        let node = try RegexPatternParser.parse("[a-z]{4}", repeatCap: 12)
        var rng = SplitMix64(seed: 7)
        #expect(RegexStringSynthesizer.synthesize(node, using: &rng).count == 4)
    }

    @Test("Nested quantifiers synthesize within an output budget instead of multiplying unbounded")
    func nestedQuantifiersStayWithinBudget() throws {
        let node = try RegexPatternParser.parse("(((((\\w{16}){16}){16}){16}){16})", repeatCap: 16)
        var rng = SplitMix64(seed: 11)
        let value = RegexStringSynthesizer.synthesize(node, budget: 1_000, using: &rng)
        #expect(value.count <= 1_000)
    }

    @Test("A pattern nested past the depth cap is refused rather than overflowing the stack")
    func excessiveNestingIsRefused() {
        let pattern = String(repeating: "(", count: 200) + "a" + String(repeating: ")", count: 200)
        #expect(throws: RegexPatternError.self) {
            _ = try RegexPatternParser.parse(pattern, repeatCap: 16)
        }
    }
}

@Suite("Check constraint conjuncts")
struct CheckConstraintGreedyRegressionTests {
    @Test("An IN list followed by another conjunct does not swallow it")
    func inListStopsAtItsOwnParenthesis() {
        let parsed = CheckConstraintParser.parse(
            "status in ('active','closed') and regexp_like(status, '^[a-z]+$')",
            column: "status"
        )
        let allowed = parsed.constraints.compactMap { constraint -> [String]? in
            guard case .allowedValues(let values) = constraint else { return nil }
            return values
        }
        #expect(allowed == [["active", "closed"]])
    }

    @Test("A plain IN list still parses")
    func plainInListParses() {
        let parsed = CheckConstraintParser.parse("status in ('a','b')", column: "status")
        #expect(parsed.isComplete)
        #expect(parsed.constraints == [.allowedValues(["a", "b"])])
    }
}

@Suite("Exponential distribution shape")
struct ExponentialDistributionRegressionTests {
    private func exponential(lambda: String) throws -> Distribution {
        try Distribution(
            params: Data(#"{"distribution":"exponential","lambda":\#(lambda)}"#.utf8),
            generator: "Integer"
        )
    }

    @Test("A low rate does not pile draws onto the maximum")
    func lowLambdaSpreadsAcrossTheRange() throws {
        let distribution = try exponential(lambda: "0.1")
        var rng = SplitMix64(seed: 99)
        let samples = 20_000
        var atMaximum = 0
        for _ in 0 ..< samples where distribution.sample(in: 0 ... 100, using: &rng) >= 99.999 {
            atMaximum += 1
        }
        #expect(Double(atMaximum) / Double(samples) < 0.02)
    }

    @Test("A low rate still leans towards the minimum")
    func lowLambdaStillSkews() throws {
        let distribution = try exponential(lambda: "0.1")
        var rng = SplitMix64(seed: 5)
        let values = (0 ..< 20_000).map { _ in distribution.sample(in: 0 ... 100, using: &rng) }
        #expect(values.allSatisfy { (0 ... 100).contains($0) })
        #expect(values.filter { $0 < 50 }.count > values.filter { $0 >= 50 }.count)
    }
}
