//
//  QueryClassifierTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("QueryClassifier isExplainStatement")
struct QueryClassifierExplainTests {
    @Test("Detects EXPLAIN and EXPLAIN ANALYZE variants")
    func detectsExplainVariants() {
        #expect(QueryClassifier.isExplainStatement("EXPLAIN SELECT * FROM users"))
        #expect(QueryClassifier.isExplainStatement("explain analyze select o.user_id from orders o"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN ANALYZE SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN FORMAT=JSON SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN (ANALYZE, BUFFERS) SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN(FORMAT JSON) SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("EXPLAIN QUERY PLAN SELECT 1"))
    }

    @Test("Detects MariaDB ANALYZE statements")
    func detectsAnalyzeVariants() {
        #expect(QueryClassifier.isExplainStatement("ANALYZE FORMAT=JSON SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("analyze select 1"))
    }

    @Test("Ignores leading whitespace, newlines, and comments")
    func handlesWhitespaceAndComments() {
        #expect(QueryClassifier.isExplainStatement("   EXPLAIN SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("\n\tEXPLAIN\nSELECT 1"))
        #expect(QueryClassifier.isExplainStatement("-- plan check\nEXPLAIN SELECT 1"))
        #expect(QueryClassifier.isExplainStatement("/* warm cache */ EXPLAIN ANALYZE SELECT 1"))
    }

    @Test("Does not match DESCRIBE, identifiers, or other statements")
    func rejectsNonExplain() {
        #expect(!QueryClassifier.isExplainStatement("DESCRIBE users"))
        #expect(!QueryClassifier.isExplainStatement("DESC users"))
        #expect(!QueryClassifier.isExplainStatement("SELECT * FROM explain_logs"))
        #expect(!QueryClassifier.isExplainStatement("SELECT explain FROM t"))
        #expect(!QueryClassifier.isExplainStatement("EXPLAINING SELECT 1"))
        #expect(!QueryClassifier.isExplainStatement("EXPLAIN"))
        #expect(!QueryClassifier.isExplainStatement(""))
    }
}

@Suite("QueryClassifier classification with leading comments")
struct QueryClassifierLeadingCommentTests {
    @Test("isWriteQuery detects writes preceded by comments")
    func writeDetectionWithComments() {
        #expect(QueryClassifier.isWriteQuery("-- cleanup\nDELETE FROM users", databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery("/* batch */ INSERT INTO t VALUES (1)", databaseType: .postgresql))
        #expect(!QueryClassifier.isWriteQuery("-- note\nSELECT * FROM users", databaseType: .mysql))
    }

    @Test("isDangerousQuery detects destructive statements preceded by comments")
    func dangerousDetectionWithComments() {
        #expect(QueryClassifier.isDangerousQuery("-- reset\nDROP TABLE users", databaseType: .mysql))
        #expect(QueryClassifier.isDangerousQuery("/* wipe */ TRUNCATE users", databaseType: .postgresql))
        #expect(QueryClassifier.isDangerousQuery("-- purge\nDELETE FROM users", databaseType: .mysql))
        #expect(!QueryClassifier.isDangerousQuery("-- purge\nDELETE FROM users WHERE id = 1", databaseType: .mysql))
    }

    @Test("classifyTier classifies statements preceded by comments")
    func tierClassificationWithComments() {
        #expect(QueryClassifier.classifyTier("-- reset\nDROP TABLE users", databaseType: .mysql) == .destructive)
        #expect(QueryClassifier.classifyTier("/* batch */ UPDATE t SET x = 1", databaseType: .mysql) == .write)
        #expect(QueryClassifier.classifyTier("-- note\nSELECT 1", databaseType: .mysql) == .safe)
    }
}

@Suite("QueryClassifier keyword boundary handling")
struct QueryClassifierKeywordBoundaryTests {
    @Test("isWriteQuery detects writes followed by newline or tab")
    func writeDetectionAcrossWhitespace() {
        #expect(QueryClassifier.isWriteQuery("DELETE\nFROM users", databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery("INSERT\tINTO t VALUES (1)", databaseType: .postgresql))
        #expect(!QueryClassifier.isWriteQuery("DELETED_ROWS", databaseType: .mysql))
    }

    @Test("isDangerousQuery detects destructive statements followed by newline")
    func dangerousDetectionAcrossWhitespace() {
        #expect(QueryClassifier.isDangerousQuery("DROP\nTABLE users", databaseType: .mysql))
        #expect(QueryClassifier.isDangerousQuery("DELETE\nFROM users", databaseType: .mysql))
        #expect(!QueryClassifier.isDangerousQuery("DELETE\nFROM users WHERE id = 1", databaseType: .mysql))
    }

    @Test("classifyTier classifies statements followed by newline")
    func tierClassificationAcrossWhitespace() {
        #expect(QueryClassifier.classifyTier("TRUNCATE\nusers", databaseType: .mysql) == .destructive)
        #expect(QueryClassifier.classifyTier("UPDATE\nt SET x = 1", databaseType: .mysql) == .write)
    }
}

@Suite("QueryClassifier unbounded write detection")
struct QueryClassifierUnboundedWriteTests {
    @Test("UPDATE without WHERE is unbounded and stays out of the legacy dangerous set")
    func updateWithoutWhereIsUnbounded() {
        #expect(!QueryClassifier.isDangerousQuery("UPDATE users SET active = 0", databaseType: .mysql))
        #expect(QueryClassifier.isUnboundedWrite("UPDATE users SET active = 0", databaseType: .mysql))
    }

    @Test("UPDATE with WHERE is bounded")
    func updateWithWhereIsBounded() {
        #expect(!QueryClassifier.isDangerousQuery(
            "UPDATE users SET active = 0 WHERE id = 1", databaseType: .mysql
        ))
        #expect(!QueryClassifier.isUnboundedWrite(
            "UPDATE users SET active = 0 WHERE id = 1", databaseType: .mysql
        ))
    }

    @Test("DELETE without WHERE stays dangerous and is also unbounded")
    func deleteWithoutWhereIsBothDangerousAndUnbounded() {
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM users", databaseType: .mysql))
        #expect(QueryClassifier.isUnboundedWrite("DELETE FROM users", databaseType: .mysql))
    }

    @Test("DELETE with WHERE is bounded")
    func deleteWithWhereIsBounded() {
        #expect(!QueryClassifier.isDangerousQuery("DELETE FROM users WHERE id = 1", databaseType: .mysql))
        #expect(!QueryClassifier.isUnboundedWrite("DELETE FROM users WHERE id = 1", databaseType: .mysql))
    }

    @Test("DELETE with LIMIT, RETURNING, or ONLY stays dangerous (floor rule regression guard)")
    func deleteFloorRuleRegressionGuard() {
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM audit LIMIT 100", databaseType: .mysql))
        #expect(QueryClassifier.isUnboundedWrite("DELETE FROM audit LIMIT 100", databaseType: .mysql))

        #expect(QueryClassifier.isDangerousQuery("DELETE FROM t RETURNING id", databaseType: .postgresql))
        #expect(QueryClassifier.isUnboundedWrite("DELETE FROM t RETURNING id", databaseType: .postgresql))

        #expect(QueryClassifier.isDangerousQuery("DELETE FROM ONLY t", databaseType: .postgresql))
        #expect(QueryClassifier.isUnboundedWrite("DELETE FROM ONLY t", databaseType: .postgresql))
    }

    @Test("A WHERE inside a comment does not count")
    func whereInCommentDoesNotCount() {
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM t /* WHERE */", databaseType: .mysql))
        #expect(QueryClassifier.isUnboundedWrite("DELETE FROM t /* WHERE */", databaseType: .mysql))
    }

    @Test("A WHERE inside a string literal does not count")
    func whereInLiteralDoesNotCount() {
        #expect(!QueryClassifier.isDangerousQuery("UPDATE t SET c = 'WHERE x'", databaseType: .mysql))
        #expect(QueryClassifier.isUnboundedWrite("UPDATE t SET c = 'WHERE x'", databaseType: .mysql))
    }

    @Test("Splitting: DELETE FROM a; DELETE FROM b is unbounded")
    func splittingCatchesSecondDelete() {
        let sql = "DELETE FROM a;\nDELETE FROM b"
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .mysql))
        #expect(QueryClassifier.isUnboundedWrite(sql, databaseType: .mysql))
    }

    @Test("Splitting: bounded UPDATE followed by unbounded DELETE is unbounded on the second statement")
    func splittingCatchesSecondStatementUnbounded() {
        let sql = "UPDATE a SET x=1 WHERE id=1;\nDELETE FROM b"
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .mysql))
        #expect(QueryClassifier.isUnboundedWrite(sql, databaseType: .mysql))
    }

    @Test("A JOIN UPDATE with a real WHERE is not blocked")
    func joinUpdateWithWhereIsBounded() {
        let sql = "UPDATE a JOIN b ON a.id=b.id SET a.x=1 WHERE b.y=2"
        #expect(!QueryClassifier.isUnboundedWrite(sql, databaseType: .mysql))
    }

    @Test("Known hole: a WHERE that belongs to a subquery reads as bounded")
    func subqueryWhereReadsAsBounded() {
        let sql = "UPDATE t SET x = (SELECT y FROM u WHERE z=1)"
        #expect(!QueryClassifier.isUnboundedWrite(sql, databaseType: .mysql))
    }

    @Test("An UPDATE with no WHERE anywhere, including in a subquery, is unbounded")
    func updateWithNoWhereAnywhereIsUnbounded() {
        let sql = "UPDATE orders SET total = (SELECT SUM(amount) FROM items)"
        #expect(QueryClassifier.isUnboundedWrite(sql, databaseType: .mysql))
    }

    @Test("TRUNCATE and DROP are dangerous but not unbounded writes")
    func truncateAndDropAreNotUnboundedWrites() {
        #expect(QueryClassifier.isDangerousQuery("TRUNCATE TABLE users", databaseType: .mysql))
        #expect(!QueryClassifier.isUnboundedWrite("TRUNCATE TABLE users", databaseType: .mysql))

        #expect(QueryClassifier.isDangerousQuery("DROP TABLE users", databaseType: .mysql))
        #expect(!QueryClassifier.isUnboundedWrite("DROP TABLE users", databaseType: .mysql))
    }

    @Test("Redis dangerous commands are untouched and never unbounded writes")
    func redisIsUntouchedByUnboundedWrite() {
        #expect(QueryClassifier.isDangerousQuery("FLUSHALL", databaseType: .redis))
        #expect(!QueryClassifier.isUnboundedWrite("FLUSHALL", databaseType: .redis))

        #expect(!QueryClassifier.isDangerousQuery(#"SET k "a;b""#, databaseType: .redis))
        #expect(!QueryClassifier.isUnboundedWrite(#"SET k "a;b""#, databaseType: .redis))
    }

    @Test("A statement above the length cap falls back to an unmasked keyword check")
    func lengthCapFallsBackToUnmaskedCheck() {
        let padding = String(repeating: "a", count: 12000)
        let sql = "UPDATE t SET c = '\(padding)'"
        #expect(QueryClassifier.isUnboundedWrite(sql, databaseType: .mysql))
    }
}

@Suite("QueryClassifier isMultiStatement")
struct QueryClassifierMultiStatementTests {
    @Test("A trailing comment after the terminating semicolon is not a second statement")
    func trailingCommentIsNotMultiStatement() {
        #expect(!QueryClassifier.isMultiStatement("SELECT 1; -- note", databaseType: .mysql))
        #expect(!QueryClassifier.isMultiStatement("SELECT 1; /* note */", databaseType: .postgresql))
    }

    @Test("Two real statements are still multi-statement")
    func twoRealStatementsAreMultiStatement() {
        #expect(QueryClassifier.isMultiStatement("SELECT 1; SELECT 2", databaseType: .mysql))
    }

    @Test("A comment-only query is not multi-statement")
    func commentOnlyQueryIsNotMultiStatement() {
        #expect(!QueryClassifier.isMultiStatement("-- note", databaseType: .mysql))
    }
}
