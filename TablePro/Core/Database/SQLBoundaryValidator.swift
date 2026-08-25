//
//  SQLBoundaryValidator.swift
//  TablePro
//

import Foundation

/// Guards the raw-SQL filter condition, which reaches the server as text inside a generated
/// `SELECT`. It rejects anything that could end the condition and start something else: a
/// statement separator, or a comment marker that would truncate the `ORDER BY` and `LIMIT` the
/// query builder appends after it.
///
/// This replaced a keyword denylist that only matched `;` followed by one of eleven verbs, so
/// `; DO $$ … $$`, `; WITH … DELETE`, `; CALL …` and `; SET ROLE` all passed and the simple query
/// protocol ran them as a second statement.
///
/// Both markers only mean anything outside a string literal, so this walks the condition instead
/// of pattern matching it. The walk assumes the **earliest** end a literal could have in any
/// dialect, because the dangerous mistake is believing a `;` sits inside a literal when the
/// server reads it as outside one:
///
/// - A doubled quote continues the literal. Every SQL dialect escapes that way, and `'O''Brien'`
///   has to keep working.
/// - A backslash is an ordinary character. PostgreSQL with `standard_conforming_strings` on, and
///   SQLite, read it that way, so `'a\'` ends there. MySQL would keep the literal open
///   (`SqlDialect.requiresBackslashEscapesInSingleQuotes`), so this ends it too early and
///   rejects, which is the safe direction.
/// - Dollar quoting and `E'…'` are not recognised at all, so their contents read as ordinary text
///   and a `;` inside one rejects.
///
/// Assuming the earliest end is what keeps this dialect-independent, and it is why this does not
/// reuse `SQLStatementScanner`: that scanner splits statements for the editor and has to model
/// each dialect exactly, which is the opposite requirement.
///
/// An unterminated literal is rejected too. It is always a syntax error in a condition, and
/// allowing one would let a condition swallow the clauses appended after it.
///
/// This does not, and cannot, stop a condition from reading more than it should through a subquery
/// or a function call. That is inherent to offering a raw-SQL filter and is out of scope. MySQL's
/// `#` comment is not rejected either, because `#` is also a PostgreSQL operator; on MySQL it can
/// truncate the trailing clauses but cannot introduce a statement, since the driver connects
/// without `CLIENT_MULTI_STATEMENTS`.
enum SQLBoundaryValidator {
    private static let singleQuote: unichar = 0x27
    private static let doubleQuote: unichar = 0x22
    private static let backtick: unichar = 0x60
    private static let semicolon: unichar = 0x3B
    private static let hyphen: unichar = 0x2D
    private static let slash: unichar = 0x2F
    private static let asterisk: unichar = 0x2A

    static func isRawFilterConditionSafe(_ sql: String) -> Bool {
        let text = sql as NSString
        let length = text.length
        var openQuote: unichar?
        var index = 0

        while index < length {
            let character = text.character(at: index)

            if let quote = openQuote {
                if character == quote {
                    if index + 1 < length, text.character(at: index + 1) == quote {
                        index += 2
                        continue
                    }
                    openQuote = nil
                }
                index += 1
                continue
            }

            if character == singleQuote || character == doubleQuote || character == backtick {
                openQuote = character
                index += 1
                continue
            }

            if character == semicolon {
                return false
            }

            if character == hyphen, index + 1 < length, text.character(at: index + 1) == hyphen {
                return false
            }

            if character == slash, index + 1 < length, text.character(at: index + 1) == asterisk {
                return false
            }

            index += 1
        }

        return openQuote == nil
    }
}
