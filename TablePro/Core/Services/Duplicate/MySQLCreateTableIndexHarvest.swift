//
//  MySQLCreateTableIndexHarvest.swift
//  TablePro
//

import Foundation

/// Reads the secondary index definitions out of `SHOW CREATE TABLE`.
///
/// This is the only place the duplicate feature reads text DDL, and it exists because MySQL has
/// no `pg_get_indexdef`: an index definition lives inside the create statement and nowhere else.
/// The reading is deliberately bounded. It splits on lines, keeps the ones that begin with an
/// index keyword, and hands the rest of the line back **verbatim**. Nothing inside the
/// parentheses is interpreted, so a prefix length, a collation, a `USING BTREE`, an index comment
/// and a visibility flag all survive because they are never looked at.
///
/// A line the reader cannot place is skipped rather than guessed at. MySQL and MariaDB do not
/// print the same create statement, and neither do two minor versions of either, so guessing is
/// how an index gets replayed wrong.
enum MySQLCreateTableIndexHarvest {
    struct Index: Sendable, Hashable {
        /// The index name with its backquotes removed, used for the `DROP INDEX` clause.
        let name: String
        /// The line exactly as the server printed it, minus the trailing comma. Replayed as the
        /// body of an `ADD` clause.
        let definition: String
    }

    /// Keywords that introduce a secondary index, longest first so `UNIQUE KEY` is never read as
    /// a bare `KEY`. MariaDB prints `INDEX` where MySQL prints `KEY` for some index kinds, so
    /// both spellings are accepted.
    private static let indexKeywords = [
        "FULLTEXT KEY", "FULLTEXT INDEX",
        "SPATIAL KEY", "SPATIAL INDEX",
        "UNIQUE KEY", "UNIQUE INDEX",
        "KEY", "INDEX"
    ]

    /// Keywords that introduce something this feature must not touch. A primary key and a unique
    /// constraint are carried by `CREATE TABLE … LIKE` as constraints, so dropping and replaying
    /// them would fight the engine rather than help it.
    private static let skippedKeywords = ["PRIMARY KEY", "CONSTRAINT", "FOREIGN KEY", "CHECK"]

    static func indexes(inCreateTable statement: String) -> [Index] {
        statement
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { index(inLine: String($0)) }
    }

    // MARK: - One line

    private static func index(inLine line: String) -> Index? {
        let definition = withoutTrailingComma(line)
        guard !definition.isEmpty else { return nil }
        let upper = definition.uppercased()
        guard !skippedKeywords.contains(where: { upper.hasPrefix($0) }) else { return nil }
        guard let keyword = indexKeywords.first(where: { upper.hasPrefix("\($0) ") }) else { return nil }

        let remainder = String(definition.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
        guard let name = backquotedIdentifier(atStartOf: Array(remainder)) else { return nil }
        guard isBalanced(definition) else { return nil }
        return Index(name: name.value, definition: definition)
    }

    /// A definition ends at the comma the next column or index starts after. That comma belongs to
    /// the create statement's list syntax, not to the index, so it never travels into the replay.
    private static func withoutTrailingComma(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespaces)
        while value.hasSuffix(",") {
            value = String(value.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    // MARK: - Lexing

    private struct QuotedIdentifier {
        let value: String
        /// Offset of the first character after the closing backquote.
        let end: Int
    }

    /// MySQL doubles an embedded backquote, so `` `a``b` `` is the single name `` a`b ``.
    private static func backquotedIdentifier(atStartOf characters: [Character]) -> QuotedIdentifier? {
        guard characters.first == "`" else { return nil }
        var offset = 1
        var value = ""
        while offset < characters.count {
            let character = characters[offset]
            offset += 1
            guard character == "`" else {
                value.append(character)
                continue
            }
            guard offset < characters.count, characters[offset] == "`" else {
                return value.isEmpty ? nil : QuotedIdentifier(value: value, end: offset)
            }
            value.append("`")
            offset += 1
        }
        return nil
    }

    /// Parentheses are counted outside backquoted names and string literals, so an index on a
    /// column called `payload)` or a comment containing a bracket does not look unbalanced. A line
    /// that still does not balance is a definition that continued onto another line, which this
    /// reader does not handle and therefore refuses.
    private static func isBalanced(_ text: String) -> Bool {
        let characters = Array(text)
        var depth = 0
        var sawOpening = false
        var offset = 0

        while offset < characters.count {
            let character = characters[offset]
            switch character {
            case "`":
                guard let identifier = backquotedIdentifier(atStartOf: Array(characters[offset...])) else {
                    return false
                }
                offset += identifier.end
                continue
            case "'", "\"":
                guard let end = endOfStringLiteral(characters, from: offset, quote: character) else { return false }
                offset = end
                continue
            case "(":
                depth += 1
                sawOpening = true
            case ")":
                depth -= 1
                guard depth >= 0 else { return false }
            default:
                break
            }
            offset += 1
        }
        return sawOpening && depth == 0
    }

    /// Returns the offset just past the closing quote. MySQL escapes a quote inside a literal
    /// either by doubling it or with a backslash, and both forms appear in index comments.
    private static func endOfStringLiteral(_ characters: [Character], from start: Int, quote: Character) -> Int? {
        var offset = start + 1
        while offset < characters.count {
            let character = characters[offset]
            if character == "\\" {
                offset += 2
                continue
            }
            offset += 1
            guard character == quote else { continue }
            guard offset < characters.count, characters[offset] == quote else { return offset }
            offset += 1
        }
        return nil
    }
}
