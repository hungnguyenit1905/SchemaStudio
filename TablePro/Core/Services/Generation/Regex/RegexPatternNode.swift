//
//  RegexPatternNode.swift
//  TablePro
//

import Foundation

/// The parsed form of a pattern. Built once at `init` and walked per row, so the
/// pattern text is never read again after the first parse.
indirect enum RegexPatternNode: Sendable, Hashable {
    case empty
    case literal(Character)
    case anyOf([Character])
    case sequence([RegexPatternNode])
    case alternation([RegexPatternNode])
    case repeated(RegexPatternNode, minimum: Int, maximum: Int)
}

enum RegexPatternError: Error, Equatable {
    case unsupportedConstruct(String)
    case malformedPattern(reason: String)
    case emptyPattern

    var reason: String {
        switch self {
        case .unsupportedConstruct(let construct):
            return "'\(construct)' is not supported"
        case .malformedPattern(let reason):
            return reason
        case .emptyPattern:
            return "the pattern is empty"
        }
    }
}

/// The characters a `.`, a negated class or a negated escape draws from.
/// Printable ASCII only: a generated value has to be readable and has to survive
/// every column encoding the app writes into.
enum RegexCharacterSets {
    static let printable: [Character] = (0x20...0x7E).compactMap {
        UnicodeScalar($0).map(Character.init)
    }

    static let digits: [Character] = Array("0123456789")
    static let word: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
    static let whitespace: [Character] = [" ", "\t"]

    static func complement(of excluded: [Character]) -> [Character] {
        let removed = Set(excluded)
        return printable.filter { !removed.contains($0) }
    }
}
