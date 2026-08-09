//
//  QuerySqlParserWhereClauseTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("QuerySqlParser single table writes")
struct QuerySqlParserWhereClauseTests {
    @Test("DELETE with a WHERE clause yields the table and the predicate")
    func deleteWithWhere() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: "DELETE FROM users WHERE id < 100")

        #expect(parsed?.kind == .delete)
        #expect(parsed?.table == "users")
        #expect(parsed?.whereClause == "id < 100")
    }

    @Test("UPDATE with a WHERE clause yields the table and the predicate")
    func updateWithWhere() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: "UPDATE users SET name = 'x' WHERE status = 'y'")

        #expect(parsed?.kind == .update)
        #expect(parsed?.table == "users")
        #expect(parsed?.whereClause == "status = 'y'")
    }

    @Test("DELETE with no WHERE clause parses with a nil predicate")
    func deleteWithoutWhere() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: "DELETE FROM users")

        #expect(parsed?.kind == .delete)
        #expect(parsed?.table == "users")
        #expect(parsed?.whereClause == nil)
    }

    @Test("UPDATE with no WHERE clause parses with a nil predicate")
    func updateWithoutWhere() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: "UPDATE users SET active = 0")

        #expect(parsed?.kind == .update)
        #expect(parsed?.whereClause == nil)
    }

    @Test("A schema qualified table is kept as written")
    func schemaQualifiedTable() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: #"DELETE FROM "public"."users" WHERE id = 1"#)

        #expect(parsed?.table == #""public"."users""#)
        #expect(parsed?.whereClause == "id = 1")
    }

    @Test("A trailing semicolon is accepted")
    func trailingSemicolon() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: "DELETE FROM users WHERE id = 1;")

        #expect(parsed?.whereClause == "id = 1")
    }

    @Test("A quoted identifier containing the word where does not confuse the parser")
    func quotedIdentifierNamedWhere() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: #"DELETE FROM "my where table" WHERE id = 1"#)

        #expect(parsed?.table == #""my where table""#)
        #expect(parsed?.whereClause == "id = 1")
    }

    @Test("A string literal containing the word where does not confuse the parser")
    func stringLiteralNamedWhere() {
        let parsed = QuerySqlParser.parseSingleTableWrite(
            from: "UPDATE notes SET body = 'where is it' WHERE id = 1"
        )

        #expect(parsed?.whereClause == "id = 1")
    }

    @Test("A JOIN form is refused")
    func joinIsRefused() {
        #expect(QuerySqlParser.parseSingleTableWrite(from: "DELETE a FROM a JOIN b ON a.id = b.id") == nil)
    }

    @Test("A USING form is refused")
    func usingIsRefused() {
        #expect(QuerySqlParser.parseSingleTableWrite(from: "DELETE FROM a USING b WHERE a.id = b.id") == nil)
    }

    @Test("A subquery in the predicate is refused")
    func subqueryIsRefused() {
        #expect(
            QuerySqlParser.parseSingleTableWrite(
                from: "DELETE FROM users WHERE id IN (SELECT id FROM banned)"
            ) == nil
        )
    }

    @Test("A CTE prefixed statement is refused")
    func cteIsRefused() {
        #expect(
            QuerySqlParser.parseSingleTableWrite(
                from: "WITH doomed AS (SELECT id FROM users) DELETE FROM users WHERE id = 1"
            ) == nil
        )
    }

    @Test("Multi statement input is refused")
    func multiStatementIsRefused() {
        #expect(
            QuerySqlParser.parseSingleTableWrite(
                from: "DELETE FROM users WHERE id = 1; DELETE FROM logs WHERE id = 2"
            ) == nil
        )
    }

    @Test("Two WHERE keywords are refused as ambiguous")
    func twoWhereKeywordsRefused() {
        #expect(
            QuerySqlParser.parseSingleTableWrite(
                from: "UPDATE a SET x = 1 WHERE y = 2 WHERE z = 3"
            ) == nil
        )
    }

    @Test("A SELECT is refused")
    func selectIsRefused() {
        #expect(QuerySqlParser.parseSingleTableWrite(from: "SELECT * FROM users WHERE id = 1") == nil)
    }

    @Test("An INSERT is refused")
    func insertIsRefused() {
        #expect(QuerySqlParser.parseSingleTableWrite(from: "INSERT INTO users (id) VALUES (1)") == nil)
    }

    @Test("A comma separated multi table delete is refused")
    func multiTableDeleteRefused() {
        #expect(QuerySqlParser.parseSingleTableWrite(from: "DELETE FROM a, b WHERE a.id = b.id") == nil)
    }

    @Test("An empty predicate after WHERE is refused")
    func emptyPredicateRefused() {
        #expect(QuerySqlParser.parseSingleTableWrite(from: "DELETE FROM users WHERE   ") == nil)
    }

    @Test("A line comment mentioning where is ignored")
    func lineCommentIsIgnored() {
        let parsed = QuerySqlParser.parseSingleTableWrite(
            from: "DELETE FROM users -- where clause follows\nWHERE id = 1"
        )

        #expect(parsed?.whereClause == "id = 1")
    }

    @Test("Lowercase keywords parse the same way")
    func lowercaseKeywords() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: "delete from users where id = 1")

        #expect(parsed?.kind == .delete)
        #expect(parsed?.whereClause == "id = 1")
    }

    @Test("A backtick quoted table is kept as written")
    func backtickTable() {
        let parsed = QuerySqlParser.parseSingleTableWrite(from: "DELETE FROM `users` WHERE id = 1")

        #expect(parsed?.table == "`users`")
    }

    @Test("Empty input is refused")
    func emptyInputRefused() {
        #expect(QuerySqlParser.parseSingleTableWrite(from: "   ") == nil)
    }
}
