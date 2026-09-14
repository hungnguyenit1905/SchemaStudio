//
//  CheckConstraintParserTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// The expressions here are copied from what the servers themselves returned,
/// not hand-written SQL: PostgreSQL 15 via `pg_get_constraintdef`, MySQL 8 via
/// `information_schema.CHECK_CONSTRAINTS`, SQLite via `sqlite_master.sql`. Each
/// vendor rewrites what the user typed, and that rewritten form is the only text
/// a driver can ever hand the mapper.
@Suite("CheckConstraintParser")
struct CheckConstraintParserTests {
    private func parse(_ expression: String, _ column: String) -> ParsedCheckConstraint {
        CheckConstraintParser.parse(expression, column: column)
    }

    @Test(
        "A lower bound is read through every vendor's spelling",
        arguments: [
            "CHECK ((price > (0)::numeric))",
            "(`price` > 0)",
            "price > 0"
        ]
    )
    func lowerBound(expression: String) {
        #expect(parse(expression, "price") == ParsedCheckConstraint(
            constraints: [.lowerBound(value: 0, inclusive: false)],
            isComplete: true
        ))
    }

    @Test(
        "An inclusive lower bound is read through every vendor's spelling",
        arguments: [
            "CHECK ((qty >= 1))",
            "(`qty` >= 1)",
            "qty >= 1"
        ]
    )
    func inclusiveLowerBound(expression: String) {
        #expect(parse(expression, "qty") == ParsedCheckConstraint(
            constraints: [.lowerBound(value: 1, inclusive: true)],
            isComplete: true
        ))
    }

    @Test("An exclusive upper bound is read")
    func upperBound() {
        #expect(parse("CHECK ((score < 100))", "score") == ParsedCheckConstraint(
            constraints: [.upperBound(value: 100, inclusive: false)],
            isComplete: true
        ))
    }

    @Test("Stripping the leading check keyword requires a word boundary after it")
    func checkKeywordRequiresWordBoundary() {
        #expect(parse("CHECK (checkin_count >= 0)", "checkin_count") == ParsedCheckConstraint(
            constraints: [.lowerBound(value: 0, inclusive: true)],
            isComplete: true
        ))
        #expect(parse("CHECK (age > 0)", "age") == ParsedCheckConstraint(
            constraints: [.lowerBound(value: 0, inclusive: false)],
            isComplete: true
        ))
        #expect(parse("check(age > 0)", "age") == ParsedCheckConstraint(
            constraints: [.lowerBound(value: 0, inclusive: false)],
            isComplete: true
        ))
    }

    @Test("A reversed comparison still names the column's side")
    func reversedComparison() {
        #expect(parse("0 <= price", "price") == ParsedCheckConstraint(
            constraints: [.lowerBound(value: 0, inclusive: true)],
            isComplete: true
        ))
    }

    @Test(
        "A range is read whether the vendor kept BETWEEN or expanded it",
        arguments: [
            "CHECK (((age >= 18) AND (age <= 65)))",
            "(`age` between 18 and 65)",
            "age BETWEEN 18 AND 65"
        ]
    )
    func range(expression: String) {
        #expect(parse(expression, "age") == ParsedCheckConstraint(
            constraints: [.lowerBound(value: 18, inclusive: true), .upperBound(value: 65, inclusive: true)],
            isComplete: true
        ))
    }

    @Test("Two bounds on a decimal survive the cast noise")
    func castedRange() {
        let parsed = parse("CHECK (((discount >= (0)::numeric) AND (discount <= (100)::numeric)))", "discount")
        #expect(parsed.isComplete)
        #expect(parsed.constraints == [
            .lowerBound(value: 0, inclusive: true),
            .upperBound(value: 100, inclusive: true)
        ])
    }

    @Test(
        "A value list is read whether the vendor kept IN or rewrote it as ANY",
        arguments: [
            "CHECK (((status)::text = ANY ((ARRAY['new'::character varying, 'paid'::character varying, 'shipped'::character varying])::text[])))",
            "(`status` in (_latin1'new',_latin1'paid',_latin1'shipped'))",
            "status IN ('new','paid','shipped')"
        ]
    )
    func valueList(expression: String) {
        #expect(parse(expression, "status") == ParsedCheckConstraint(
            constraints: [.allowedValues(["new", "paid", "shipped"])],
            isComplete: true
        ))
    }

    @Test("A quote inside a literal survives")
    func escapedQuoteInLiteral() {
        #expect(parse("status IN ('o''brien','smith')", "status") == ParsedCheckConstraint(
            constraints: [.allowedValues(["o'brien", "smith"])],
            isComplete: true
        ))
    }

    @Test(
        "A length cap is read through every vendor's spelling",
        arguments: [
            "CHECK ((length((code)::text) <= 8))",
            "(length(`code`) <= 8)",
            "length(code) <= 8",
            "char_length(code) <= 8"
        ]
    )
    func lengthCap(expression: String) {
        #expect(parse(expression, "code") == ParsedCheckConstraint(
            constraints: [.maximumLength(8)],
            isComplete: true
        ))
    }

    @Test("A strict length cap loses one character")
    func strictLengthCap() {
        #expect(parse("length(code) < 8", "code") == ParsedCheckConstraint(
            constraints: [.maximumLength(7)],
            isComplete: true
        ))
    }

    @Test("A not-null check is understood")
    func notNull() {
        #expect(parse("CHECK ((note IS NOT NULL))", "note") == ParsedCheckConstraint(
            constraints: [.notNull],
            isComplete: true
        ))
    }

    @Test("A non-empty check is understood")
    func nonEmpty() {
        #expect(parse("CHECK ((code <> ''))", "code") == ParsedCheckConstraint(
            constraints: [.nonEmpty],
            isComplete: true
        ))
    }

    @Test(
        "A pattern is recognised even though no generator matches it yet",
        arguments: [
            "CHECK (((sku)::text ~ '^[A-Z]{3}$'::text))",
            "regexp_like(`sku`,_latin1'^[A-Z]{3}$')",
            "sku REGEXP '^[A-Z]{3}$'"
        ]
    )
    func pattern(expression: String) {
        #expect(parse(expression, "sku") == ParsedCheckConstraint(
            constraints: [.pattern("^[A-Z]{3}$")],
            isComplete: true
        ))
    }

    @Test(
        "A check across two columns is reported as not understood",
        arguments: [
            "CHECK ((starts < ends))",
            "(`starts` < `ends`)",
            "starts < ends"
        ]
    )
    func multiColumnCheck(expression: String) {
        #expect(parse(expression, "starts") == .unparsed)
    }

    @Test("A check on a different column is not adopted")
    func otherColumnCheck() {
        #expect(parse("CHECK ((price > (0)::numeric))", "qty") == .unparsed)
    }

    @Test("Alternatives are not half-applied")
    func alternativesAreNotApplied() {
        let parsed = parse("status IN ('new') OR status IS NULL", "status")
        #expect(parsed.constraints.isEmpty)
        #expect(!parsed.isComplete)
    }

    @Test("A partly understood conjunction keeps what it read and says it is incomplete")
    func partiallyUnderstoodConjunction() {
        let parsed = parse("price > 0 AND price < ends", "price")
        #expect(parsed.constraints == [.lowerBound(value: 0, inclusive: false)])
        #expect(!parsed.isComplete)
    }

    @Test("Nonsense is reported as not understood")
    func nonsense() {
        #expect(parse("", "a") == .unparsed)
        #expect(parse("CHECK (my_udf(a) = 1)", "a") == .unparsed)
    }
}

@Suite("AutoMapper check refinement")
struct AutoMapperCheckRefinementTests {
    private typealias Fixtures = AutoMapFixtures

    @Test("A positive-only check lifts the generator's minimum off zero")
    func lowerBoundNarrowsDecimal() {
        let resolution = Fixtures.resolve(
            "price",
            "numeric(10,2)",
            table: "products",
            checkExpressions: ["CHECK ((price > (0)::numeric))"]
        )
        #expect(resolution.identifier == "Price")
        #expect(resolution.params.objectValue?["min"] == .double(0.01))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A strict integer bound moves by one")
    func upperBoundNarrowsInteger() {
        let resolution = Fixtures.resolve(
            "counter",
            "integer",
            table: "stats",
            checkExpressions: ["CHECK ((counter < 100))"]
        )
        #expect(resolution.params.objectValue?["max"] == .int(99))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A range replaces both ends of the name rule's range")
    func rangeNarrowsBothEnds() {
        let resolution = Fixtures.resolve(
            "age",
            "integer",
            table: "users",
            checkExpressions: ["age BETWEEN 21 AND 40"]
        )
        #expect(resolution.params.objectValue?["min"] == .int(21))
        #expect(resolution.params.objectValue?["max"] == .int(40))
    }

    @Test("A value-list check replaces a guessed list and its warning")
    func valueListReplacesTheGuess() {
        let resolution = Fixtures.resolve(
            "status",
            "varchar(16)",
            table: "orders",
            checkExpressions: ["status IN ('new','paid','shipped')"]
        )
        #expect(resolution.identifier == "List")
        #expect(resolution.params.objectValue?["values"] == .array([
            .string("new"), .string("paid"), .string("shipped")
        ]))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A length check caps the string the mapper chose")
    func lengthCheckCapsTheString() {
        let resolution = Fixtures.resolve(
            "code",
            "varchar(64)",
            table: "coupons",
            checkExpressions: ["CHECK ((length((code)::text) <= 8))"]
        )
        #expect(resolution.identifier == "RandomString")
        #expect(resolution.params.objectValue?["maxLength"] == .int(8))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A length check the column already enforces changes nothing")
    func redundantLengthCheckIsQuiet() {
        let resolution = Fixtures.resolve(
            "code",
            "varchar(8)",
            table: "coupons",
            checkExpressions: ["length(code) <= 8"]
        )
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A length check on words switches to a generator that can honour it")
    func lengthCheckSwitchesGenerator() {
        let resolution = Fixtures.resolve(
            "description",
            "text",
            table: "posts",
            checkExpressions: ["length(description) <= 20"]
        )
        #expect(resolution.identifier == "RandomString")
        #expect(resolution.params.objectValue?["maxLength"] == .int(20))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A length check leaves room for the prefix and suffix around the value")
    func lengthCheckAccountsForTheAffix() {
        let resolution = Fixtures.resolve(
            "avatar_url",
            "varchar(60)",
            table: "users",
            checkExpressions: ["CHECK ((length((avatar_url)::text) <= 30))"]
        )
        #expect(resolution.identifier == "RandomString")
        #expect(resolution.common.prefix == "https://example.com/")
        #expect(resolution.common.suffix == ".png")
        #expect(resolution.params.objectValue?["maxLength"] == .int(6))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A length check the prefix and suffix cannot fit inside warns instead")
    func lengthCheckSmallerThanTheAffixWarns() {
        let resolution = Fixtures.resolve(
            "avatar_url",
            "varchar(60)",
            table: "users",
            checkExpressions: ["length(avatar_url) <= 6"]
        )
        #expect(resolution.warnings == [
            .uncheckedConstraint(column: "avatar_url", expression: "length(avatar_url) <= 6")
        ])
    }

    @Test("A length check never throws away the schema's own value list")
    func lengthCheckKeepsAValueList() {
        let column = Fixtures.column(
            "status",
            "enum('new','paid')",
            table: "orders",
            databaseType: .mysql,
            allowedValues: ["new", "paid"],
            checkExpressions: ["length(status) <= 3"]
        )
        let resolution = AutoMapper.resolve(column, table: "orders")
        #expect(resolution.identifier == "List")
        #expect(resolution.params.objectValue?["values"] == .array([.string("new"), .string("paid")]))
    }

    @Test("A pattern check switches the column to the generator that can match it")
    func patternCheckRoutesToRegex() {
        let resolution = Fixtures.resolve(
            "sku",
            "varchar(16)",
            table: "products",
            checkExpressions: ["CHECK (((sku)::text ~ '^[A-Z]{3}$'::text))"]
        )
        #expect(resolution.identifier == RegexGenerator.identifier)
        #expect(resolution.params.objectValue?["pattern"] == .string("^[A-Z]{3}$"))
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A value-list check clears a name rule's prefix and suffix, not just its generator")
    func valueListCheckClearsTheNameRulesAffix() {
        let resolution = Fixtures.resolve(
            "avatar",
            "varchar(64)",
            table: "users",
            checkExpressions: ["avatar IN ('a.png','b.png')"]
        )
        #expect(resolution.identifier == "List")
        #expect(resolution.common.prefix.isEmpty)
        #expect(resolution.common.suffix.isEmpty)
        #expect(resolution.warnings.contains(.affixClearedByCheck(column: "avatar")))
    }

    @Test("A pattern check clears a name rule's prefix and suffix, not just its generator")
    func patternCheckClearsTheNameRulesAffix() {
        let resolution = Fixtures.resolve(
            "avatar",
            "varchar(64)",
            table: "users",
            checkExpressions: ["CHECK (((avatar)::text ~ '^[a-z]{6}$'::text))"]
        )
        #expect(resolution.identifier == RegexGenerator.identifier)
        #expect(resolution.common.prefix.isEmpty)
        #expect(resolution.common.suffix.isEmpty)
        #expect(resolution.warnings.contains(.affixClearedByCheck(column: "avatar")))
    }

    @Test("A pattern outside the supported subset is reported instead of half applied")
    func unsupportedPatternWarns() {
        let expression = "CHECK (((sku)::text ~ '^(?=.*[0-9])[A-Z]+$'::text))"
        let resolution = Fixtures.resolve("sku", "varchar(16)", table: "products", checkExpressions: [expression])
        #expect(resolution.identifier == "SKU")
        #expect(resolution.warnings == [.uncheckedConstraint(column: "sku", expression: expression)])
    }

    @Test("A LIKE check is not read as a regular expression", arguments: [
        "CHECK (((sku)::text ~~ 'AB%'::text))",
        "(`sku` like _latin1'AB%')"
    ])
    func likeCheckWarns(expression: String) {
        let resolution = Fixtures.resolve("sku", "varchar(16)", table: "products", checkExpressions: [expression])
        #expect(resolution.identifier == "SKU")
        #expect(resolution.warnings == [.uncheckedConstraint(column: "sku", expression: expression)])
    }

    @Test("An unparseable check warns and leaves the generator alone")
    func unparseableCheckWarns() throws {
        let resolution = Fixtures.resolve(
            "starts",
            "date",
            table: "events",
            checkExpressions: ["CHECK ((starts < ends))"]
        )
        #expect(resolution.identifier == "Date")
        let warning = try #require(resolution.warnings.first)
        #expect(warning.column == "starts")
        #expect(!warning.message.isEmpty)
    }

    @Test("A server-filled column does not warn about a check it never touches")
    func serverAssignedColumnIsQuiet() {
        let column = Fixtures.column(
            "id",
            "bigint",
            table: "orders",
            isPrimaryKey: true,
            identityKind: .always,
            checkExpressions: ["CHECK ((id > 0))"]
        )
        #expect(AutoMapper.resolve(column, table: "orders").warnings.isEmpty)
    }

    @Test("A foreign key does not warn about a check the parent rows already satisfy")
    func foreignKeyIsQuiet() {
        let column = Fixtures.column(
            "customer_id",
            "bigint",
            table: "orders",
            checkExpressions: ["CHECK ((customer_id > 0))"],
            foreignKeys: [
                PluginForeignKeyInfo(
                    name: "orders_customer_fk",
                    column: "customer_id",
                    referencedTable: "customers",
                    referencedColumn: "id",
                    referencedSchema: "public"
                )
            ]
        )
        let resolution = AutoMapper.resolve(column, table: "orders")
        #expect(resolution.identifier == "Reference")
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A not-null check pins the null percentage to zero")
    func notNullCheckClearsNulls() {
        let resolution = Fixtures.resolve(
            "deleted_at",
            "timestamp",
            table: "users",
            checkExpressions: ["CHECK ((deleted_at IS NOT NULL))"]
        )
        #expect(resolution.common.nullPercent == 0)
        #expect(resolution.warnings.isEmpty)
    }

    @Test("A CHECK literal past Int's range maps without trapping, clamped to the column's range")
    func outOfRangeCheckLiteralDoesNotTrap() throws {
        let column = Fixtures.column(
            "qty",
            "bigint",
            table: "orders",
            checkExpressions: ["CHECK ((qty <= 18446744073709551615))"]
        )
        let resolution = AutoMapper.resolve(column, table: "orders")
        let profile = GenerationColumnProfile(
            column: "qty",
            generator: resolution.identifier,
            params: resolution.params,
            common: resolution.common
        )
        let generator = try GeneratorRegistry.standard.make(
            identifier: resolution.identifier,
            params: profile.paramData,
            column: column,
            seed: 5
        )
        for index in 0..<20 {
            let value = try generator.next(row: RowContext(table: "orders", rowIndex: index), index: index)
            guard case .int(let number) = value else {
                Issue.record("expected an int, got \(value)")
                continue
            }
            #expect(number >= 0)
        }
    }

    @Test("A refined mapping still builds a generator")
    func refinedMappingBuilds() throws {
        let column = Fixtures.column(
            "price",
            "numeric(10,2)",
            table: "products",
            checkExpressions: ["CHECK ((price > (0)::numeric))"]
        )
        let resolution = AutoMapper.resolve(column, table: "products")
        let profile = GenerationColumnProfile(
            column: "price",
            generator: resolution.identifier,
            params: resolution.params,
            common: resolution.common
        )
        let generator = try GeneratorRegistry.standard.make(
            identifier: resolution.identifier,
            params: profile.paramData,
            column: column,
            seed: 3
        )
        _ = try generator.next(row: RowContext(table: "products", rowIndex: 0), index: 0)
    }
}
