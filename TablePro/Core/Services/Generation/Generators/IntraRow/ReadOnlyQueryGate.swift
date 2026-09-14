//
//  ReadOnlyQueryGate.swift
//  TablePro
//

import Foundation

/// Decides whether a user-typed query is safe to run against the connection
/// being generated into: a `SELECT`, or a `WITH` whose common table expressions
/// never write.
///
/// This is a security boundary, not a syntax checker. It never tries to parse
/// SQL; it masks string literals and comments, then scans what is left for a
/// writing keyword on a word boundary. Anything it cannot confidently read
/// (an unterminated string or comment) is refused rather than allowed, because
/// the safe default here is "no".
enum ReadOnlyQueryGate {
    private static let readOnlyLeadingKeywords: Set<String> = ["select", "with"]

    private static let writingKeywords: Set<String> = [
        "insert", "update", "delete", "merge", "replace",
        "create", "alter", "drop", "truncate",
        "grant", "revoke", "call", "exec", "execute"
    ]

    static func isReadOnly(_ query: String) -> Bool {
        guard let masked = maskStringsAndComments(query) else { return false }
        let tokens = words(in: masked)
        guard let leading = tokens.first, readOnlyLeadingKeywords.contains(leading) else { return false }
        guard !hasSecondStatement(masked) else { return false }
        guard !tokens.contains(where: writingKeywords.contains) else { return false }
        return true
    }

    private static func hasSecondStatement(_ masked: String) -> Bool {
        let trimmed = masked.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
        return body.contains(";")
    }

    private static func words(in masked: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in masked.unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                tokens.append(String(current).lowercased())
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty {
            tokens.append(String(current).lowercased())
        }
        return tokens
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    /// Replaces every string literal and comment with blanks of the same shape,
    /// so the keyword scan never reads inside one. `nil` means the query holds a
    /// string or comment that never closes, which is refused rather than guessed
    /// at.
    private static func maskStringsAndComments(_ query: String) -> String? {
        let scalars = Array(query.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar == "-", index + 1 < scalars.count, scalars[index + 1] == "-" {
                while index < scalars.count, scalars[index] != "\n" {
                    result.append(" ")
                    index += 1
                }
                continue
            }

            if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                result.append(" ")
                result.append(" ")
                index += 2
                var closed = false
                while index + 1 < scalars.count {
                    if scalars[index] == "*", scalars[index + 1] == "/" {
                        result.append(" ")
                        result.append(" ")
                        index += 2
                        closed = true
                        break
                    }
                    result.append(scalars[index] == "\n" ? "\n" : " ")
                    index += 1
                }
                guard closed else { return nil }
                continue
            }

            if scalar == "'" || scalar == "\"" || scalar == "`" {
                let quote = scalar
                result.append(" ")
                index += 1
                var closed = false
                while index < scalars.count {
                    if scalars[index] == quote {
                        if quote == "'", index + 1 < scalars.count, scalars[index + 1] == "'" {
                            result.append(" ")
                            result.append(" ")
                            index += 2
                            continue
                        }
                        result.append(" ")
                        index += 1
                        closed = true
                        break
                    }
                    result.append(scalars[index] == "\n" ? "\n" : " ")
                    index += 1
                }
                guard closed else { return nil }
                continue
            }

            result.append(scalar)
            index += 1
        }

        return String(result)
    }
}
