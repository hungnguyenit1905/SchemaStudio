//
//  PostgreSQLApproximateRowCountTests.swift
//  TableProTests
//
//  Regression cover for a row estimate that ignored the schema it was asked
//  about and resolved the table through `current_schema()` instead, so a table
//  outside the search path was estimated from a same-named table in it.
//

import Foundation
import Testing

@Suite("PostgreSQLSchemaQueries.approximateRowCount")
struct PostgreSQLApproximateRowCountTests {
    private func query(schema: String?, currentSchema: String = "public", table: String = "orders") -> String {
        PostgreSQLSchemaQueries.approximateRowCount(
            schemaLiteral: schema,
            currentSchemaLiteral: currentSchema,
            tableLiteral: table
        )
    }

    /// The bug this suite exists for: the requested schema was dropped and the connection's own
    /// schema used instead, so `s2.orders` reported the size of `public.orders`.
    @Test("A requested schema wins over the connection's current schema")
    func requestedSchemaWins() {
        let sql = query(schema: "s2", currentSchema: "public")
        #expect(sql.contains("n.nspname = 's2'"))
        #expect(!sql.contains("'public'"))
    }

    @Test("No requested schema falls back to the current one")
    func fallsBackToCurrentSchema() {
        #expect(query(schema: nil, currentSchema: "reporting").contains("n.nspname = 'reporting'"))
    }

    /// A qualified reference that resolved to an empty string is absent, not a schema named "".
    @Test("An empty requested schema falls back too")
    func emptySchemaFallsBack() {
        #expect(query(schema: "", currentSchema: "reporting").contains("n.nspname = 'reporting'"))
    }

    @Test("The table filter and the schema filter are both applied")
    func filtersOnBothNames() {
        let sql = query(schema: "public")
        #expect(sql.contains("c.relname = 'orders'"))
        #expect(sql.contains("n.nspname = 'public'"))
    }

    @Test("The estimate comes from reltuples")
    func readsReltuples() {
        #expect(query(schema: "public").contains("reltuples::bigint"))
    }

    @Test("Nothing resolves the table through the search path")
    func neverUsesCurrentSchemaFunction() {
        #expect(!query(schema: "s2").contains("current_schema()"))
    }

    /// The caller escapes before passing, and a name carrying a quote must not end the literal.
    @Test("An escaped name is embedded as given")
    func embedsTheEscapedName() {
        #expect(query(schema: "public", table: "o''rders").contains("c.relname = 'o''rders'"))
    }
}
