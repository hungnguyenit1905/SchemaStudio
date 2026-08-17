//
//  CheckConstraintParser.swift
//  TablePro
//

import Foundation

enum CheckConstraint: Sendable, Hashable {
    case lowerBound(value: Double, inclusive: Bool)
    case upperBound(value: Double, inclusive: Bool)
    case allowedValues([String])
    case maximumLength(Int)
    case nonEmpty
    case notNull
    case pattern(String)
}

/// What a single `CHECK` expression yielded. `isComplete` is false when part of
/// the expression was not understood, which the caller turns into a warning: a
/// half-applied check still lets the server reject the row.
struct ParsedCheckConstraint: Sendable, Hashable {
    let constraints: [CheckConstraint]
    let isComplete: Bool

    static let unparsed = ParsedCheckConstraint(constraints: [], isComplete: false)
}

/// Reads the narrow set of `CHECK` shapes that map onto a generator's settings.
///
/// The input is whatever the server hands back, not what the user typed, and every
/// vendor rewrites it differently. PostgreSQL parenthesizes everything, casts both
/// sides (`(price > (0)::numeric)`), turns `IN` into `= ANY (ARRAY[...])` and
/// expands `BETWEEN` into two comparisons. MySQL keeps `between`, lowercases the
/// keywords, quotes identifiers in backticks, prefixes literals with a charset
/// introducer (`_latin1'new'`) and rewrites `REGEXP` into `regexp_like(col, ...)`.
/// SQLite stores the original DDL text untouched. The patterns here are matched
/// against text captured from each of those servers.
enum CheckConstraintParser {
    static func parse(_ expression: String, column: String) -> ParsedCheckConstraint {
        let normalized = normalize(expression)
        guard !normalized.isEmpty else { return .unparsed }
        if let single = constraints(in: normalized, column: column) {
            return ParsedCheckConstraint(constraints: single, isComplete: true)
        }
        let conjuncts = splitConjuncts(normalized)
        guard conjuncts.count > 1 else { return .unparsed }
        var collected: [CheckConstraint] = []
        var isComplete = true
        for conjunct in conjuncts {
            guard let parsed = constraints(in: conjunct, column: column) else {
                isComplete = false
                continue
            }
            collected.append(contentsOf: parsed)
        }
        return ParsedCheckConstraint(constraints: collected, isComplete: isComplete)
    }

    private static func constraints(in expression: String, column: String) -> [CheckConstraint]? {
        let text = stripRedundantParentheses(expression)
        for matcher in matchers {
            guard let groups = matcher.capture(text) else { continue }
            guard let constraints = matcher.build(groups, column) else { return nil }
            return constraints
        }
        return nil
    }

    private struct Matcher {
        let expression: NSRegularExpression
        let build: ([String], String) -> [CheckConstraint]?

        init(_ pattern: String, _ build: @escaping ([String], String) -> [CheckConstraint]?) {
            expression = NameRules.compile("^" + pattern + "$")
            self.build = build
        }

        func capture(_ text: String) -> [String]? {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, options: [], range: range) else { return nil }
            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let captured = Range(match.range(at: index), in: text) else {
                    groups.append("")
                    continue
                }
                groups.append(String(text[captured]))
            }
            return groups
        }
    }

    private static let identifierPattern = "([A-Za-z_][A-Za-z_0-9$.]*)"
    private static let numberPattern = "(-?[0-9]+(?:\\.[0-9]+)?)"

    private static let matchers: [Matcher] = [
        Matcher("\(identifierPattern)\\s*(>=|>)\\s*\(numberPattern)") { groups, column in
            guard names(groups[0], column), let value = Double(groups[2]) else { return nil }
            return [.lowerBound(value: value, inclusive: groups[1] == ">=")]
        },
        Matcher("\(identifierPattern)\\s*(<=|<)\\s*\(numberPattern)") { groups, column in
            guard names(groups[0], column), let value = Double(groups[2]) else { return nil }
            return [.upperBound(value: value, inclusive: groups[1] == "<=")]
        },
        Matcher("\(numberPattern)\\s*(<=|<)\\s*\(identifierPattern)") { groups, column in
            guard names(groups[2], column), let value = Double(groups[0]) else { return nil }
            return [.lowerBound(value: value, inclusive: groups[1] == "<=")]
        },
        Matcher("\(numberPattern)\\s*(>=|>)\\s*\(identifierPattern)") { groups, column in
            guard names(groups[2], column), let value = Double(groups[0]) else { return nil }
            return [.upperBound(value: value, inclusive: groups[1] == ">=")]
        },
        Matcher("\(identifierPattern)\\s+between\\s+\(numberPattern)\\s+and\\s+\(numberPattern)") { groups, column in
            guard names(groups[0], column), let lower = Double(groups[1]), let upper = Double(groups[2]) else {
                return nil
            }
            return [.lowerBound(value: lower, inclusive: true), .upperBound(value: upper, inclusive: true)]
        },
        Matcher("\(identifierPattern)\\s+in\\s*\\((.*)\\)") { groups, column in
            guard names(groups[0], column) else { return nil }
            let values = literals(in: groups[1])
            guard !values.isEmpty else { return nil }
            return [.allowedValues(values)]
        },
        Matcher("\(identifierPattern)\\s*=\\s*any\\s*\\(+\\s*array\\s*\\[(.*)\\]\\s*\\)+") { groups, column in
            guard names(groups[0], column) else { return nil }
            let values = literals(in: groups[1])
            guard !values.isEmpty else { return nil }
            return [.allowedValues(values)]
        },
        Matcher(
            "(?:length|char_length|character_length|octet_length)\\s*\\(\\s*\(identifierPattern)\\s*\\)"
                + "\\s*(<=|<)\\s*([0-9]+)"
        ) { groups, column in
            guard names(groups[0], column), let limit = Int(groups[2]) else { return nil }
            return [.maximumLength(groups[1] == "<=" ? limit : limit - 1)]
        },
        Matcher("\(identifierPattern)\\s+is\\s+not\\s+null") { groups, column in
            guard names(groups[0], column) else { return nil }
            return [.notNull]
        },
        Matcher("\(identifierPattern)\\s*(?:<>|!=)\\s*''") { groups, column in
            guard names(groups[0], column) else { return nil }
            return [.nonEmpty]
        },
        Matcher("\(identifierPattern)\\s*(?:~\\*|~|regexp|rlike|like|ilike)\\s*'(.*)'") { groups, column in
            guard names(groups[0], column) else { return nil }
            return [.pattern(groups[1])]
        },
        Matcher("regexp_like\\s*\\(\\s*\(identifierPattern)\\s*,\\s*'(.*)'\\s*\\)") { groups, column in
            guard names(groups[0], column) else { return nil }
            return [.pattern(groups[1])]
        }
    ]

    private static func names(_ identifier: String, _ column: String) -> Bool {
        let unqualified = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return unqualified.compare(column, options: .caseInsensitive) == .orderedSame
    }

    private static func literals(in list: String) -> [String] {
        var values: [String] = []
        var current = ""
        var insideQuotes = false
        var index = list.startIndex
        while index < list.endIndex {
            let character = list[index]
            if character == "'" {
                let next = list.index(after: index)
                if insideQuotes, next < list.endIndex, list[next] == "'" {
                    current.append("'")
                    index = list.index(after: next)
                    continue
                }
                insideQuotes.toggle()
                index = next
                continue
            }
            if character == ",", !insideQuotes {
                values.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index = list.index(after: index)
                continue
            }
            current.append(character)
            index = list.index(after: index)
        }
        values.append(current.trimmingCharacters(in: .whitespaces))
        return values.filter { !$0.isEmpty }
    }

    private static let multiWordTypes = [
        "character varying", "double precision", "timestamp without time zone",
        "timestamp with time zone", "time without time zone", "time with time zone",
        "bit varying", "character large object"
    ]

    private static let castPattern = NameRules.compile(
        "::\\s*[A-Za-z_][A-Za-z_0-9]*(\\s*\\(\\s*\\d+\\s*(,\\s*\\d+\\s*)?\\))?(\\[\\])?"
    )

    private static let introducerPattern = NameRules.compile(
        "_(?:utf8mb4|utf8mb3|utf8|latin1|ascii|binary|utf16|utf32|ucs2)(?=')"
    )

    private static let whitespacePattern = NameRules.compile("\\s+")

    /// The lookbehind keeps `length(code)` intact: dropping the parentheses after
    /// a function name would splice it into one identifier.
    private static let parenthesizedTokenPattern = NameRules.compile(
        "(?<![A-Za-z_0-9])\\(\\s*([A-Za-z_][A-Za-z_0-9$.]*|-?[0-9]+(?:\\.[0-9]+)?)\\s*\\)"
    )

    private static func normalize(_ expression: String) -> String {
        var text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("check") {
            text = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        for type in multiWordTypes {
            text = text.replacingOccurrences(
                of: "::\(type)",
                with: "",
                options: [.caseInsensitive]
            )
        }
        text = replacing(castPattern, in: text, with: "")
        text = replacing(introducerPattern, in: text, with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "\"", with: "")
        text = replacing(whitespacePattern, in: text, with: " ")
        return strippingOuterParentheses(text.trimmingCharacters(in: .whitespaces))
    }

    private static func stripRedundantParentheses(_ expression: String) -> String {
        var text = strippingOuterParentheses(expression.trimmingCharacters(in: .whitespaces))
        while true {
            let reduced = replacing(parenthesizedTokenPattern, in: text, with: "$1")
            let stripped = strippingOuterParentheses(reduced)
            guard stripped != text else { return text }
            text = stripped
        }
    }

    private static func strippingOuterParentheses(_ expression: String) -> String {
        var text = expression
        while text.hasPrefix("("), text.hasSuffix(")"), enclosesWholeExpression(text) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func enclosesWholeExpression(_ text: String) -> Bool {
        var depth = 0
        var insideQuotes = false
        for (offset, character) in text.enumerated() {
            if character == "'" {
                insideQuotes.toggle()
                continue
            }
            guard !insideQuotes else { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return offset == text.count - 1 }
            }
        }
        return false
    }

    /// A top-level `or` means the expression describes alternatives, and applying
    /// one branch would forbid values the server allows. Those are reported as
    /// not understood rather than half-applied.
    private static func splitConjuncts(_ expression: String) -> [String] {
        let keywords = keywordPositions(in: expression)
        guard !keywords.contains(where: { $0.keyword == "or" }) else { return [] }
        let separators = keywords.filter { $0.keyword == "and" }
        guard !separators.isEmpty else { return [] }
        var parts: [String] = []
        var start = expression.startIndex
        for separator in separators {
            parts.append(String(expression[start..<separator.range.lowerBound]))
            start = separator.range.upperBound
        }
        parts.append(String(expression[start...]))
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private struct KeywordPosition {
        let keyword: String
        let range: Range<String.Index>
    }

    private static func keywordPositions(in expression: String) -> [KeywordPosition] {
        var positions: [KeywordPosition] = []
        var depth = 0
        var insideQuotes = false
        var index = expression.startIndex
        var betweenDepth = 0
        while index < expression.endIndex {
            let character = expression[index]
            if character == "'" {
                insideQuotes.toggle()
                index = expression.index(after: index)
                continue
            }
            if !insideQuotes {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0, let keyword = keyword(in: expression, at: index) {
                    if keyword.keyword == "between" {
                        betweenDepth += 1
                    } else if keyword.keyword == "and", betweenDepth > 0 {
                        betweenDepth -= 1
                    } else {
                        positions.append(keyword)
                    }
                    index = keyword.range.upperBound
                    continue
                }
            }
            index = expression.index(after: index)
        }
        return positions
    }

    private static func keyword(in expression: String, at index: String.Index) -> KeywordPosition? {
        guard index == expression.startIndex || expression[expression.index(before: index)] == " " else { return nil }
        for candidate in ["and", "or", "between"] {
            let end = expression.index(index, offsetBy: candidate.count, limitedBy: expression.endIndex)
            guard let end, expression[index..<end].lowercased() == candidate else { continue }
            guard end == expression.endIndex || expression[end] == " " else { continue }
            return KeywordPosition(keyword: candidate, range: index..<end)
        }
        return nil
    }

    private static func replacing(
        _ pattern: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
