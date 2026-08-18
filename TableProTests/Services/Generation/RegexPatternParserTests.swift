//
//  RegexPatternParserTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

/// Every generated string is checked with `NSRegularExpression` rather than with
/// the synthesizer's own idea of the pattern, so a parser that misreads a
/// construct fails here instead of producing rows the server rejects.
@Suite("Reverse regex")
struct RegexPatternParserTests {
    private static let patterns = [
        "abc",
        "^abc$",
        "[a-z]",
        "[a-z]{5}",
        "[A-Z]{3}-[0-9]{4}",
        "^[A-Z]{3}$",
        "[0-9]{2,4}",
        "[a-z0-9_]{1,12}",
        "[^0-9]{4}",
        "[abc]+",
        "x*",
        "y+",
        "z?",
        "colou?r",
        "cat|dog|bird",
        "(cat|dog)-[0-9]{2}",
        "(ab){3}",
        "(?:ab|cd){2,3}",
        "\\d{4}-\\d{2}-\\d{2}",
        "\\w{6}",
        "\\D{3}",
        "\\W{2}",
        "\\S{5}",
        "SKU-[A-Z]{2}[0-9]{6}",
        "[A-F0-9]{8}",
        "\\+[0-9]{1,3} [0-9]{7,10}",
        "v[0-9]+\\.[0-9]+\\.[0-9]+",
        "[a-z]{3}@[a-z]{4}\\.(com|org|net)",
        "(0|1){8}",
        "a{0,3}b{2}",
        "[-a-z]{4}",
        "[\\d\\-]{6}"
    ]

    private func generate(_ pattern: String, count: Int, seed: UInt64 = 11) throws -> [String] {
        let node = try RegexPatternParser.parse(pattern, repeatCap: RegexGenerator.defaultRepeatCap)
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in RegexStringSynthesizer.synthesize(node, using: &rng) }
    }

    @Test("Every generated string matches its pattern", arguments: patterns)
    func generatedStringsMatch(pattern: String) throws {
        let expression = try NSRegularExpression(pattern: pattern)
        for value in try generate(pattern, count: 1_000) {
            let range = NSRange(value.startIndex..., in: value)
            let match = expression.firstMatch(in: value, options: [], range: range)
            #expect(match != nil, "\(pattern) did not match \(value)")
        }
    }

    @Test("An anchored pattern matches the whole value", arguments: ["^[A-Z]{3}$", "^abc$", "^(cat|dog)[0-9]{2}$"])
    func anchoredPatternsMatchWholeValue(pattern: String) throws {
        let expression = try NSRegularExpression(pattern: pattern)
        for value in try generate(pattern, count: 200) {
            let range = NSRange(value.startIndex..., in: value)
            let match = expression.firstMatch(in: value, options: [], range: range)
            #expect(match?.range == range)
        }
    }

    @Test(
        "An unsupported construct throws at parse time and names itself",
        arguments: [
            ("(a)\\1", "\\1"),
            ("(?=abc)x", "(?="),
            ("(?!abc)x", "(?!"),
            ("(?<name>a)", "(?<"),
            ("\\bword\\b", "\\b"),
            ("a*?", "? after a quantifier"),
            ("a++", "+ after a quantifier"),
            ("\\p{L}{3}", "\\p")
        ]
    )
    func unsupportedConstructsThrow(pattern: String, construct: String) {
        do {
            _ = try RegexPatternParser.parse(pattern, repeatCap: 16)
            Issue.record("\(pattern) parsed but should not have")
        } catch let error as RegexPatternError {
            #expect(error == .unsupportedConstruct(construct))
            #expect(error.reason.contains(construct))
        } catch {
            Issue.record("\(pattern) threw \(error)")
        }
    }

    @Test(
        "A malformed pattern throws rather than generating half of it",
        arguments: ["[a-z", "(abc", "abc)", "a{3,1}", "*abc", "[]"]
    )
    func malformedPatternsThrow(pattern: String) {
        #expect(throws: RegexPatternError.self) {
            _ = try RegexPatternParser.parse(pattern, repeatCap: 16)
        }
    }

    @Test("An unbounded quantifier stops at the repeat cap")
    func unboundedQuantifiersAreCapped() throws {
        let node = try RegexPatternParser.parse("a*", repeatCap: 4)
        var rng = SplitMix64(seed: 3)
        for _ in 0..<500 {
            #expect(RegexStringSynthesizer.synthesize(node, using: &rng).count <= 4)
        }
    }

    @Test("The same seed produces the same values")
    func deterministicUnderAFixedSeed() throws {
        #expect(try generate("[a-z]{4}-[0-9]{3}", count: 200) == generate("[a-z]{4}-[0-9]{3}", count: 200))
        #expect(try generate("[a-z]{4}", count: 50, seed: 1) != generate("[a-z]{4}", count: 50, seed: 2))
    }

    @Test("The generator refuses an unsupported pattern with a legible message")
    func generatorReportsTheConstruct() {
        do {
            _ = try RegexGenerator(
                params: GeneratorTestFixtures.params(#"{"pattern":"(a)\\1"}"#),
                column: GeneratorTestFixtures.column(),
                seed: 1
            )
            Issue.record("the generator accepted a backreference")
        } catch let error as GenerationError {
            #expect(error.errorDescription?.contains("\\1") == true)
        } catch {
            Issue.record("threw \(error)")
        }
    }

    @Test("The column's length caps how far an unbounded quantifier repeats")
    func columnLengthCapsRepeats() throws {
        let generator = try RegexGenerator(
            params: GeneratorTestFixtures.params(#"{"pattern":"a+"}"#),
            column: GeneratorTestFixtures.column(dataType: "varchar(6)"),
            seed: 5
        )
        for index in 0..<200 {
            let value = try generator.next(row: GeneratorTestFixtures.rowContext(), index: index)
            guard case let .text(text) = value else {
                Issue.record("the regex generator produced \(value) rather than text")
                return
            }
            #expect(text.count <= 6)
        }
    }
}
