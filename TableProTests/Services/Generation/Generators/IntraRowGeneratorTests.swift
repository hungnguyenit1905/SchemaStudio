//
//  IntraRowGeneratorTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("Intra-row generators")
struct IntraRowGeneratorTests {
    private static let registry = GeneratorRegistry.standard

    private func generator(
        _ identifier: String,
        params: String,
        dataType: String = "text",
        columnName: String = "value"
    ) throws -> any ValueGenerator {
        try Self.registry.make(
            identifier: identifier,
            params: Data(params.utf8),
            column: GeneratorTestFixtures.column(name: columnName, dataType: dataType),
            seed: 31
        )
    }

    private func row(_ values: [String: PluginCellValue]) -> RowContext {
        RowContext(table: "fixture", rowIndex: 0, values: values)
    }

    // MARK: - Expression

    @Test("A template inserts the columns it names")
    func templateRendersRowValues() throws {
        let expression = try generator(
            ExpressionGenerator.identifier,
            params: #"{"template":"{{first_name}}.{{last_name}}@example.com"}"#
        )
        let value = try expression.next(
            row: row(["first_name": .text("ada"), "last_name": .text("lovelace")]),
            index: 0
        )
        #expect(value == .text("ada.lovelace@example.com"))
    }

    @Test("A template declares each column it reads, once, in the order it reads them")
    func templateDeclaresItsDependencies() throws {
        let expression = try generator(
            ExpressionGenerator.identifier,
            params: #"{"template":"{{a}}-{{b}}-{{a}}"}"#
        )
        #expect(expression.rowDependencies == ["a", "b"])
    }

    @Test("Folding turns a Vietnamese name into something an address can hold")
    func templateFoldsToAscii() throws {
        let expression = try generator(
            ExpressionGenerator.identifier,
            params: #"{"template":"{{first}}.{{last}}@example.com","slugify":true}"#
        )
        let value = try expression.next(
            row: row(["first": .text("Nguyễn"), "last": .text("Đặng Hương")]),
            index: 0
        )
        #expect(value == .text("nguyen.dang.huong@example.com"))
    }

    @Test("A template reads a non-text column the way the driver would")
    func templateRendersNonTextValues() throws {
        let expression = try generator(ExpressionGenerator.identifier, params: #"{"template":"order-{{id}}"}"#)
        #expect(try expression.next(row: row(["id": .int(42)]), index: 0) == .text("order-42"))
    }

    @Test("An unclosed placeholder stays literal rather than failing the run")
    func templateKeepsUnclosedBracesLiteral() throws {
        let expression = try generator(ExpressionGenerator.identifier, params: #"{"template":"{{ok}} {{broken"}"#)
        #expect(try expression.next(row: row(["ok": .text("yes")]), index: 0) == .text("yes {{broken"))
    }

    @Test("A template that names a column with no value says which one")
    func templateReportsAMissingColumn() throws {
        let expression = try generator(ExpressionGenerator.identifier, params: #"{"template":"{{missing}}"}"#)
        #expect(throws: GenerationError.self) {
            _ = try expression.next(row: row([:]), index: 0)
        }
    }

    @Test("A template refuses to read itself or to be empty")
    func templateRejectsBadInput() {
        #expect(throws: GenerationError.self) {
            _ = try generator(ExpressionGenerator.identifier, params: #"{"template":"{{value}}"}"#)
        }
        #expect(throws: GenerationError.self) {
            _ = try generator(ExpressionGenerator.identifier, params: #"{"template":""}"#)
        }
    }

    @Test("A rendered template fits the column it is written into")
    func templateTruncatesToTheColumn() throws {
        let expression = try generator(
            ExpressionGenerator.identifier,
            params: #"{"template":"{{name}}@example.com"}"#,
            dataType: "varchar(8)"
        )
        #expect(try expression.next(row: row(["name": .text("ada")]), index: 0) == .text("ada@exam"))
    }

    // MARK: - RelativeDateTime

    @Test("An offset is never negative when the smallest offset is zero")
    func offsetsStayAfterTheBase() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let relative = try generator(
            RelativeDateTimeGenerator.identifier,
            params: #"{"baseColumn":"created_at","unit":"minute","offsetMin":0,"offsetMax":600}"#,
            dataType: "timestamp"
        )
        for index in 0..<2_000 {
            let value = try relative.next(row: row(["created_at": .timestamp(base)]), index: index)
            guard case let .timestamp(moment) = value else {
                Issue.record("expected a timestamp, got \(value)")
                continue
            }
            #expect(moment >= base)
            #expect(moment.timeIntervalSince(base) <= 600 * 60)
        }
    }

    @Test("A base can be a timestamp, a date, text or a Unix time", arguments: [
        PluginCellValue.timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
        PluginCellValue.date(year: 2_023, month: 11, day: 14),
        PluginCellValue.text("2023-11-14 22:13:20"),
        PluginCellValue.int(1_700_000_000)
    ])
    func baseValuesAreRead(base: PluginCellValue) throws {
        let relative = try generator(
            RelativeDateTimeGenerator.identifier,
            params: #"{"baseColumn":"created_at","unit":"day","offsetMin":1,"offsetMax":1}"#
        )
        let value = try relative.next(row: row(["created_at": base]), index: 0)
        guard case let .text(text) = value else {
            Issue.record("expected text, got \(value)")
            return
        }
        #expect(text.hasPrefix("2023-11-15"))
    }

    @Test("A date column gets a calendar day, not an instant")
    func dateColumnsGetCalendarDays() throws {
        let relative = try generator(
            RelativeDateTimeGenerator.identifier,
            params: #"{"baseColumn":"created_at","unit":"day","offsetMin":2,"offsetMax":2}"#,
            dataType: "date"
        )
        let value = try relative.next(row: row(["created_at": .date(year: 2_024, month: 2, day: 27)]), index: 0)
        #expect(value == .date(year: 2_024, month: 2, day: 29))
    }

    @Test("A null base gives a null offset rather than an error")
    func nullBaseGivesNull() throws {
        let relative = try generator(
            RelativeDateTimeGenerator.identifier,
            params: #"{"baseColumn":"created_at"}"#
        )
        #expect(try relative.next(row: row(["created_at": .null]), index: 0) == .null)
    }

    @Test("A base that is not a date is reported rather than silently skipped")
    func nonDateBaseThrows() throws {
        let relative = try generator(
            RelativeDateTimeGenerator.identifier,
            params: #"{"baseColumn":"created_at"}"#
        )
        #expect(throws: GenerationError.self) {
            _ = try relative.next(row: row(["created_at": .text("not a date")]), index: 0)
        }
        #expect(throws: GenerationError.self) {
            _ = try relative.next(row: row([:]), index: 0)
        }
    }

    @Test("An inverted offset range is clamped rather than trapping")
    func invertedOffsetRangeIsClamped() throws {
        let relative = try generator(
            RelativeDateTimeGenerator.identifier,
            params: #"{"baseColumn":"created_at","unit":"day","offsetMin":9,"offsetMax":2}"#
        )
        let value = try relative.next(row: row(["created_at": .date(year: 2_024, month: 1, day: 1)]), index: 0)
        #expect(value == .text("2024-01-03 00:00:00"))
    }

    @Test("An offset column refuses to measure from itself")
    func offsetRejectsSelfReference() {
        #expect(throws: GenerationError.self) {
            _ = try generator(RelativeDateTimeGenerator.identifier, params: #"{"baseColumn":"value"}"#)
        }
        #expect(throws: GenerationError.self) {
            _ = try generator(RelativeDateTimeGenerator.identifier, params: #"{"baseColumn":""}"#)
        }
    }

    // MARK: - SQLQuery

    /// The query runs against the user's own database with their own rights, so
    /// anything that is not a plain read is refused before it is ever sent.
    @Test("Only a single read-only statement is accepted", arguments: [
        ("SELECT id FROM users", true),
        ("  select id from users  ", true),
        ("WITH recent AS (SELECT id FROM users) SELECT id FROM recent", true),
        ("SELECT id FROM users;", true),
        ("-- a note\nSELECT id FROM users", true),
        ("/* a note */ SELECT id FROM users", true),
        ("DELETE FROM users", false),
        ("/* a note */ DELETE FROM users", false),
        ("-- SELECT id\nDROP TABLE users", false),
        ("INSERT INTO users (id) VALUES (1)", false),
        ("UPDATE users SET id = 1", false),
        ("SELECT id FROM users; DROP TABLE users", false),
        ("TRUNCATE users", false)
    ])
    func readOnlyStatementsOnly(query: String, isAccepted: Bool) {
        #expect(SqlQueryGenerator.isReadOnly(query) == isAccepted)
    }

    @Test("A query that is not a read is refused when the generator is built")
    func nonReadQueryIsRefusedAtBuildTime() {
        #expect(throws: GenerationError.self) {
            _ = try generator(SqlQueryGenerator.identifier, params: #"{"query":"DELETE FROM users"}"#)
        }
        #expect(throws: GenerationError.self) {
            _ = try generator(SqlQueryGenerator.identifier, params: #"{"query":"  "}"#)
        }
    }

    @Test("A query column draws in order when asked to")
    func roundRobinDrawsFollowTheResult() throws {
        let query = try generator(
            SqlQueryGenerator.identifier,
            params: #"{"query":"SELECT id FROM users","strategy":"roundRobin"}"#
        )
        let consumer = try #require(query as? any SqlQueryConsuming)
        consumer.bind(queryValues: [.int(7), .int(8)])
        let drawn = try (0..<4).map { try query.next(row: row([:]), index: $0) }
        #expect(drawn == [.int(7), .int(8), .int(7), .int(8)])
    }

    @Test("A query column with nothing bound says what it was waiting for")
    func unboundQueryThrows() throws {
        let query = try generator(SqlQueryGenerator.identifier, params: #"{"query":"SELECT id FROM users"}"#)
        #expect(throws: GenerationError.self) {
            _ = try query.next(row: row([:]), index: 0)
        }
    }

    @Test("The column named in the result is carried to the driver")
    func querySourceCarriesTheColumn() throws {
        let query = try generator(
            SqlQueryGenerator.identifier,
            params: #"{"query":"SELECT id, email FROM users","column":"email"}"#
        )
        let consumer = try #require(query as? any SqlQueryConsuming)
        #expect(consumer.querySource == SqlQuerySource(query: "SELECT id, email FROM users", column: "email"))
    }
}
