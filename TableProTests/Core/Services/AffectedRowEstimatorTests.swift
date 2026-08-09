//
//  AffectedRowEstimatorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("AffectedRowEstimator")
struct AffectedRowEstimatorTests {
    private func statement(
        kind: SingleTableWriteStatement.Kind = .delete,
        table: String = "users",
        whereClause: String?
    ) -> SingleTableWriteStatement {
        SingleTableWriteStatement(kind: kind, table: table, whereClause: whereClause)
    }

    @Test("A predicated statement with a count resolves to an exact number")
    func predicatedStatementIsExact() {
        let resolved = AffectedRowEstimator.resolve(
            statement: statement(whereClause: "id < 100"),
            count: 42
        )

        #expect(resolved == .exact(42))
    }

    @Test("A predicated statement whose count failed resolves to could not determine")
    func predicatedStatementWithoutCount() {
        let resolved = AffectedRowEstimator.resolve(
            statement: statement(whereClause: "id < 100"),
            count: nil
        )

        #expect(resolved == .undetermined(.couldNotDetermine))
    }

    @Test("A statement with no WHERE clause resolves to whole table with its count")
    func wholeTableWithCount() {
        let resolved = AffectedRowEstimator.resolve(
            statement: statement(whereClause: nil),
            count: 900
        )

        #expect(resolved == .wholeTable(900))
    }

    @Test("A statement with no WHERE clause stays whole table even when the count failed")
    func wholeTableWithoutCount() {
        let resolved = AffectedRowEstimator.resolve(
            statement: statement(whereClause: nil),
            count: nil
        )

        #expect(resolved == .wholeTable(nil))
    }

    @Test("The count statement reuses the predicate exactly as written")
    func countStatementWithPredicate() {
        let sql = AffectedRowEstimator.countStatement(
            for: statement(table: "users", whereClause: "id < 100")
        )

        #expect(sql == "SELECT count(*) FROM users WHERE id < 100")
    }

    @Test("The count statement omits WHERE when the statement has no predicate")
    func countStatementWithoutPredicate() {
        let sql = AffectedRowEstimator.countStatement(for: statement(table: "users", whereClause: nil))

        #expect(sql == "SELECT count(*) FROM users")
    }

    @Test("The count statement keeps the table quoting the user wrote")
    func countStatementKeepsQuoting() {
        let sql = AffectedRowEstimator.countStatement(
            for: statement(table: #""public"."users""#, whereClause: "id = 1")
        )

        #expect(sql == #"SELECT count(*) FROM "public"."users" WHERE id = 1"#)
    }

    @Test("The time box is 1.5 seconds")
    func timeBoxIsOneAndAHalfSeconds() {
        #expect(AffectedRowEstimator.timeBox == .milliseconds(1_500))
    }

    @Test("A statement that is neither UPDATE nor DELETE is not countable")
    func nonWriteStatementIsNotCountable() {
        #expect(QuerySqlParser.leadingWriteKind(from: "SELECT * FROM users") == nil)
        #expect(QuerySqlParser.leadingWriteKind(from: "CREATE TABLE t (id int)") == nil)
        #expect(QuerySqlParser.leadingWriteKind(from: "INSERT INTO t VALUES (1)") == nil)
    }

    @Test("An UPDATE or DELETE is recognised as countable even when the full parse refuses")
    func writeStatementIsRecognised() {
        #expect(QuerySqlParser.leadingWriteKind(from: "DELETE FROM a USING b WHERE a.id = b.id") == .delete)
        #expect(QuerySqlParser.leadingWriteKind(from: "update users set a = 1") == .update)
    }
}

@Suite("AffectedRowEstimate messages")
@MainActor
struct AffectedRowEstimateMessageTests {
    @Test("An exact estimate leads with the row count")
    func exactMessage() {
        let text = AlertOperationConfirming.affectedRowsPreamble(.exact(7))

        #expect(text.contains("7"))
        #expect(!text.isEmpty)
    }

    @Test("A whole table estimate says every row is affected")
    func wholeTableMessage() {
        let text = AlertOperationConfirming.affectedRowsPreamble(.wholeTable(nil))

        #expect(text.contains("every row"))
    }

    @Test("A statement that could not be counted says so explicitly")
    func couldNotDetermineMessage() {
        let text = AlertOperationConfirming.affectedRowsPreamble(.undetermined(.couldNotDetermine))

        #expect(!text.isEmpty)
    }

    @Test("A statement that is not an UPDATE or DELETE adds nothing to the dialog")
    func notCountableMessageIsSilent() {
        let text = AlertOperationConfirming.affectedRowsPreamble(.undetermined(.notACountableStatement))

        #expect(text.isEmpty)
    }
}
