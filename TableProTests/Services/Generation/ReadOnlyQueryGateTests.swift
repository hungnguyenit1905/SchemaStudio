//
//  ReadOnlyQueryGateTests.swift
//  TableProTests
//

@testable import SchemaStudio
import Testing

@Suite("Read-only query gate")
struct ReadOnlyQueryGateTests {
    @Test("A plain SELECT is read-only", arguments: [
        "SELECT id FROM customers",
        "  select id from customers  ",
        "SeLeCt id FROM customers WHERE id = 1"
    ])
    func plainSelectIsReadOnly(query: String) {
        #expect(ReadOnlyQueryGate.isReadOnly(query))
    }

    @Test("A read-only WITH is allowed")
    func readOnlyWithIsAllowed() {
        #expect(
            ReadOnlyQueryGate.isReadOnly(
                "WITH recent AS (SELECT id FROM orders WHERE created_at > now()) SELECT id FROM recent"
            )
        )
    }

    @Test("WITH RECURSIVE stays read-only when its bodies are")
    func withRecursiveIsAllowed() {
        #expect(
            ReadOnlyQueryGate.isReadOnly(
                """
                WITH RECURSIVE chain AS (
                    SELECT id, parent_id FROM categories WHERE parent_id IS NULL
                    UNION ALL
                    SELECT c.id, c.parent_id FROM categories c JOIN chain ON c.parent_id = chain.id
                ) SELECT id FROM chain
                """
            )
        )
    }

    @Test("A leading comment does not smuggle a write past the keyword check")
    func leadingCommentDoesNotHideAWrite() {
        #expect(!ReadOnlyQueryGate.isReadOnly("/* note */ DELETE FROM orders"))
        #expect(!ReadOnlyQueryGate.isReadOnly("-- note\nDELETE FROM orders"))
    }

    @Test("A data-modifying CTE is refused even though the query starts with WITH")
    func writingCTEIsRefused() {
        #expect(!ReadOnlyQueryGate.isReadOnly("WITH gone AS (DELETE FROM orders RETURNING id) SELECT id FROM gone"))
        #expect(!ReadOnlyQueryGate.isReadOnly("WITH x AS (UPDATE orders SET status = 'x' RETURNING id) SELECT id FROM x"))
        #expect(!ReadOnlyQueryGate.isReadOnly("WITH x AS (INSERT INTO orders (id) VALUES (1) RETURNING id) SELECT id FROM x"))
        #expect(!ReadOnlyQueryGate.isReadOnly("WITH x AS (MERGE INTO orders USING src ON true WHEN MATCHED THEN DELETE) SELECT 1"))
    }

    @Test("A comment between two keywords does not hide the write")
    func commentBetweenKeywordsDoesNotHideAWrite() {
        #expect(
            !ReadOnlyQueryGate.isReadOnly(
                "WITH gone AS (/* purge */ DELETE FROM orders RETURNING id) SELECT id FROM gone"
            )
        )
        #expect(
            !ReadOnlyQueryGate.isReadOnly(
                "WITH gone AS (DELETE -- purge\nFROM orders RETURNING id) SELECT id FROM gone"
            )
        )
    }

    @Test("A write keyword inside a string literal is not mistaken for SQL")
    func writeKeywordInsideStringLiteralIsIgnored() {
        #expect(ReadOnlyQueryGate.isReadOnly("SELECT 'delete this row' AS note FROM customers"))
        #expect(ReadOnlyQueryGate.isReadOnly("SELECT \"delete\" FROM customers"))
        #expect(ReadOnlyQueryGate.isReadOnly("SELECT * FROM customers WHERE note = 'it''s a delete request'"))
    }

    @Test("A nested CTE that writes is refused")
    func nestedCTEThatWritesIsRefused() {
        #expect(
            !ReadOnlyQueryGate.isReadOnly(
                """
                WITH outer_cte AS (
                    WITH inner_cte AS (DELETE FROM orders RETURNING id)
                    SELECT id FROM inner_cte
                ) SELECT id FROM outer_cte
                """
            )
        )
    }

    @Test("Mixed case does not evade the writing-keyword scan")
    func mixedCaseIsStillCaught() {
        #expect(!ReadOnlyQueryGate.isReadOnly("WITH x AS (DeLeTe FROM orders) SELECT 1"))
        #expect(!ReadOnlyQueryGate.isReadOnly("wItH x As (dRoP TABLE orders) SELECT 1"))
    }

    @Test("Unicode whitespace between keywords does not evade the scan")
    func unicodeWhitespaceIsStillCaught() {
        #expect(!ReadOnlyQueryGate.isReadOnly("WITH\u{00A0}x\u{2003}AS\u{00A0}(DELETE\u{00A0}FROM\u{00A0}orders) SELECT 1"))
        #expect(ReadOnlyQueryGate.isReadOnly("SELECT\u{00A0}id\u{2003}FROM\u{00A0}customers"))
    }

    @Test("A second statement after a semicolon is refused")
    func secondStatementIsRefused() {
        #expect(!ReadOnlyQueryGate.isReadOnly("SELECT id FROM customers; DELETE FROM customers"))
    }

    @Test("An unterminated string or comment is refused as ambiguous")
    func unterminatedStringOrCommentIsRefused() {
        #expect(!ReadOnlyQueryGate.isReadOnly("SELECT 'unterminated FROM customers"))
        #expect(!ReadOnlyQueryGate.isReadOnly("SELECT id FROM customers /* unterminated"))
    }

    @Test("A statement that is neither SELECT nor WITH is refused")
    func neitherSelectNorWithIsRefused() {
        #expect(!ReadOnlyQueryGate.isReadOnly("DELETE FROM orders"))
        #expect(!ReadOnlyQueryGate.isReadOnly("EXEC dbo.PurgeOrders"))
        #expect(!ReadOnlyQueryGate.isReadOnly(""))
    }

    @Test("A word merely containing a writing keyword as a substring is not flagged")
    func writingKeywordAsSubstringIsNotFlagged() {
        #expect(ReadOnlyQueryGate.isReadOnly("SELECT insert_date, updated_by FROM audit_log"))
    }
}
