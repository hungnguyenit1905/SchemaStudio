//
//  SQLBoundaryValidatorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("SQLBoundaryValidator")
struct SQLBoundaryValidatorTests {
    @Test("Plain filter conditions are allowed")
    func allowsPlainConditions() {
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("age > 18"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("status IN ('active','pending')"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("created_at BETWEEN '2020-01-01' AND '2021-01-01'"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("name = 'O''Brien'"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("data @> '{\"k\": 1}'"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("email ~ '^[a-z]+@example\\.com$'"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("total - discount > 0"))
    }

    @Test("Stacked destructive statements are rejected")
    func rejectsStackedStatements() {
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; DROP TABLE users"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("x = 1 ; delete from t"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("a = 1;TRUNCATE t"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("id = 1; UPDATE t SET x = 2"))
    }

    /// Every one of these passed the keyword denylist this validator replaced. The payload that
    /// actually executed also closes the parenthesis `FilterSQLGenerator` wraps the condition in,
    /// so the generated SQL is three syntactically valid statements.
    @Test("Statements the keyword denylist missed are rejected")
    func rejectsPayloadsThatDefeatedTheDenylist() {
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1); DO $$ BEGIN DROP TABLE t; END $$; SELECT (1"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; DO $$ BEGIN DROP TABLE users; END $$"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; WITH x AS (SELECT 1) DELETE FROM users"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; COPY t TO PROGRAM 'curl example.com'"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; CALL some_proc()"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; SET ROLE postgres"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1; SELECT pg_sleep(60)"))
    }

    /// A semicolon inside a literal is legitimate and stays allowed, so the walk has to agree with
    /// the server about where a literal ends. Where dialects disagree it assumes the earliest end,
    /// which rejects.
    @Test("Semicolons are judged by whether they sit inside a literal")
    func judgesSemicolonsByLiteralContext() {
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("status = 'semi;colon'"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("label = 'a;b' AND other = 'c;d'"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("\"odd;column\" = 1"))

        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("note = 'x\\'; DROP TABLE t; SELECT (1='1"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("note = $$a; b$$"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("note = 'closed'; DROP TABLE t"))
    }

    /// An unterminated literal would otherwise swallow the clauses the query builder appends.
    @Test("Unterminated literals are rejected")
    func rejectsUnterminatedLiterals() {
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("note = 'abc"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("note = 'a''b"))
    }

    /// Comment markers inside a literal are ordinary text, so they no longer reject. The rule this
    /// replaced matched `--` after any whitespace, so `note = 'a --b'` was refused.
    @Test("Comment markers inside literals are allowed")
    func allowsCommentMarkersInsideLiterals() {
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("note = 'a--b'"))
        #expect(SQLBoundaryValidator.isRawFilterConditionSafe("note = 'a /* b'"))
    }

    @Test("Comment injection is rejected")
    func rejectsCommentInjection() {
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("id = 1 -- ignored"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("id = 1 /* block */"))
    }

    /// The previous rule anchored `--` to start-of-string or whitespace, so a comment opened
    /// directly after a closing parenthesis slipped through and truncated the `ORDER BY` and
    /// `LIMIT` clauses the query builder appends.
    @Test("Comment markers are rejected without a leading space")
    func rejectsCommentMarkersWithoutLeadingWhitespace() {
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1)--"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1) UNION ALL SELECT a, b FROM secrets--"))
        #expect(!SQLBoundaryValidator.isRawFilterConditionSafe("1=1)/*"))
    }
}
