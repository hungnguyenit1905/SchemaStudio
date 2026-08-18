//
//  RegexPatternParser.swift
//  TablePro
//

import Foundation

/// Reads the subset of regular expressions that can be run backwards: literals,
/// character classes, the class escapes, quantifiers, alternation, groups and
/// anchors. Anything outside that subset throws here, at `init`, naming the
/// construct, rather than at row 500,000.
///
/// A backreference or a lookaround cannot be produced by generating left to
/// right, so they are refused rather than half-supported.
struct RegexPatternParser {
    private let characters: [Character]
    private let repeatCap: Int
    private var position = 0

    private init(pattern: String, repeatCap: Int) {
        characters = Array(pattern)
        self.repeatCap = max(1, repeatCap)
    }

    static func parse(_ pattern: String, repeatCap: Int) throws -> RegexPatternNode {
        guard !pattern.isEmpty else { throw RegexPatternError.emptyPattern }
        var parser = RegexPatternParser(pattern: pattern, repeatCap: repeatCap)
        let node = try parser.parseAlternation()
        guard parser.isAtEnd else {
            throw RegexPatternError.malformedPattern(reason: "there is an unmatched ')'")
        }
        return node
    }

    private var isAtEnd: Bool { position >= characters.count }

    private func peek(_ offset: Int = 0) -> Character? {
        let index = position + offset
        guard index < characters.count else { return nil }
        return characters[index]
    }

    private mutating func advance() -> Character? {
        guard let character = peek() else { return nil }
        position += 1
        return character
    }

    private mutating func parseAlternation() throws -> RegexPatternNode {
        var branches = [try parseSequence()]
        while peek() == "|" {
            position += 1
            branches.append(try parseSequence())
        }
        guard branches.count > 1 else { return branches[0] }
        return .alternation(branches)
    }

    private mutating func parseSequence() throws -> RegexPatternNode {
        var nodes: [RegexPatternNode] = []
        while let character = peek(), character != "|", character != ")" {
            nodes.append(try parseQuantified())
        }
        guard !nodes.isEmpty else { return .empty }
        guard nodes.count > 1 else { return nodes[0] }
        return .sequence(nodes)
    }

    private mutating func parseQuantified() throws -> RegexPatternNode {
        let atom = try parseAtom()
        guard let bounds = try parseQuantifier() else { return atom }
        try rejectLazyOrPossessive()
        return .repeated(atom, minimum: bounds.minimum, maximum: bounds.maximum)
    }

    private mutating func rejectLazyOrPossessive() throws {
        guard let modifier = peek(), modifier == "?" || modifier == "+" else { return }
        throw RegexPatternError.unsupportedConstruct(String(modifier) + " after a quantifier")
    }

    private mutating func parseQuantifier() throws -> (minimum: Int, maximum: Int)? {
        switch peek() {
        case "*":
            position += 1
            return (0, repeatCap)
        case "+":
            position += 1
            return (1, repeatCap)
        case "?":
            position += 1
            return (0, 1)
        case "{":
            return try parseBracedQuantifier()
        default:
            return nil
        }
    }

    /// A `{` that does not open a count is a literal brace, which is what every
    /// engine does with it, so it is left for `parseAtom` to pick up.
    private mutating func parseBracedQuantifier() throws -> (minimum: Int, maximum: Int)? {
        guard let close = closingBraceIndex() else { return nil }
        let body = String(characters[(position + 1)..<close])
        guard let bounds = Self.bounds(in: body, cap: repeatCap) else { return nil }
        guard bounds.minimum <= bounds.maximum else {
            throw RegexPatternError.malformedPattern(reason: "the count {\(body)} counts down")
        }
        position = close + 1
        return bounds
    }

    private func closingBraceIndex() -> Int? {
        var index = position + 1
        while index < characters.count, characters[index] != "}" {
            index += 1
        }
        return index < characters.count ? index : nil
    }

    private static func bounds(in body: String, cap: Int) -> (minimum: Int, maximum: Int)? {
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let minimum = Int(parts[0]), minimum >= 0 else { return nil }
        guard parts.count == 2 else { return (minimum, minimum) }
        guard !parts[1].isEmpty else { return (minimum, Swift.max(minimum, minimum + cap)) }
        guard let maximum = Int(parts[1]), maximum >= 0 else { return nil }
        return (minimum, maximum)
    }

    private mutating func parseAtom() throws -> RegexPatternNode {
        guard let character = advance() else { return .empty }
        switch character {
        case "(":
            return try parseGroup()
        case "[":
            return try parseCharacterClass()
        case ".":
            return .anyOf(RegexCharacterSets.printable)
        case "^", "$":
            return .empty
        case "\\":
            return try parseEscape()
        case "*", "+", "?":
            throw RegexPatternError.malformedPattern(reason: "'\(character)' has nothing to repeat")
        default:
            return .literal(character)
        }
    }

    private mutating func parseGroup() throws -> RegexPatternNode {
        if peek() == "?" {
            guard peek(1) == ":" else {
                let construct = "(?" + String(peek(1).map(String.init) ?? "")
                throw RegexPatternError.unsupportedConstruct(construct)
            }
            position += 2
        }
        let node = try parseAlternation()
        guard advance() == ")" else {
            throw RegexPatternError.malformedPattern(reason: "there is an unclosed '('")
        }
        return node
    }

    private static let classEscapes: [Character: [Character]] = [
        "d": RegexCharacterSets.digits,
        "D": RegexCharacterSets.complement(of: RegexCharacterSets.digits),
        "w": RegexCharacterSets.word,
        "W": RegexCharacterSets.complement(of: RegexCharacterSets.word),
        "s": RegexCharacterSets.whitespace,
        "S": RegexCharacterSets.complement(of: RegexCharacterSets.whitespace)
    ]

    private static let literalEscapes: [Character: Character] = [
        "n": "\n", "t": "\t", "r": "\r"
    ]

    private static let unsupportedEscapes: Set<Character> = [
        "b", "B", "A", "z", "Z", "G", "p", "P", "k", "Q", "E", "R", "X", "N", "K"
    ]

    private mutating func parseEscape() throws -> RegexPatternNode {
        guard let escaped = advance() else {
            throw RegexPatternError.malformedPattern(reason: "the pattern ends in a backslash")
        }
        if let set = Self.classEscapes[escaped] { return .anyOf(set) }
        if let literal = Self.literalEscapes[escaped] { return .literal(literal) }
        if escaped.isNumber {
            throw RegexPatternError.unsupportedConstruct("\\\(escaped)")
        }
        if Self.unsupportedEscapes.contains(escaped) {
            throw RegexPatternError.unsupportedConstruct("\\\(escaped)")
        }
        return .literal(escaped)
    }

    private mutating func parseCharacterClass() throws -> RegexPatternNode {
        var negated = false
        if peek() == "^" {
            negated = true
            position += 1
        }
        var members: [Character] = []
        var closed = false
        while let character = advance() {
            if character == "]", !members.isEmpty {
                closed = true
                break
            }
            if character == "\\" {
                try appendEscape(to: &members)
                continue
            }
            if peek() == "-", let upper = peek(1), upper != "]" {
                position += 2
                try appendRange(from: character, to: upper, into: &members)
                continue
            }
            members.append(character)
        }
        guard closed else {
            throw RegexPatternError.malformedPattern(reason: "there is an unclosed '['")
        }
        guard !members.isEmpty else {
            throw RegexPatternError.malformedPattern(reason: "the character class is empty")
        }
        let resolved = negated ? RegexCharacterSets.complement(of: members) : members
        guard !resolved.isEmpty else {
            throw RegexPatternError.malformedPattern(reason: "the character class excludes every character")
        }
        return .anyOf(Self.deduplicated(resolved))
    }

    private mutating func appendEscape(to members: inout [Character]) throws {
        guard let escaped = advance() else {
            throw RegexPatternError.malformedPattern(reason: "the pattern ends in a backslash")
        }
        if let set = Self.classEscapes[escaped] {
            members.append(contentsOf: set)
            return
        }
        if let literal = Self.literalEscapes[escaped] {
            members.append(literal)
            return
        }
        if escaped.isNumber || Self.unsupportedEscapes.contains(escaped) {
            throw RegexPatternError.unsupportedConstruct("\\\(escaped)")
        }
        members.append(escaped)
    }

    private func appendRange(from lower: Character, to upper: Character, into members: inout [Character]) throws {
        guard
            let start = lower.unicodeScalars.first?.value,
            let end = upper.unicodeScalars.first?.value,
            lower.unicodeScalars.count == 1,
            upper.unicodeScalars.count == 1,
            start <= end
        else {
            throw RegexPatternError.malformedPattern(reason: "the range \(lower)-\(upper) runs backwards")
        }
        for scalar in start...end {
            guard let unicode = UnicodeScalar(scalar) else { continue }
            members.append(Character(unicode))
        }
    }

    private static func deduplicated(_ members: [Character]) -> [Character] {
        var seen = Set<Character>()
        return members.filter { seen.insert($0).inserted }
    }
}
