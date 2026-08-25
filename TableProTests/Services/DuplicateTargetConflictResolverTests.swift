//
//  DuplicateTargetConflictResolverTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import Testing

@Suite("Duplicate target conflict resolver")
struct DuplicateTargetConflictResolverTests {
    private let target = DuplicateTableRef(schema: "public", name: "orders_copy")

    private var quoting: DuplicateSQLQuoting {
        DuplicateSQLQuoting(
            identifier: { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" },
            stringLiteral: { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
        )
    }

    private func referencing(_ count: Int) -> [ReferencingForeignKey] {
        (1 ... count).map { index in
            ReferencingForeignKey(
                constraintName: "fk_\(index)",
                owningSchema: "public",
                owningTable: "invoices_\(index)"
            )
        }
    }

    @Test("Nothing points at the target, so the drop is plain and carries no CASCADE")
    func plainDropWithoutReferences() {
        for catalog: any DuplicateVendorCatalog in [PostgreSqlDuplicateCatalog(), MySqlDuplicateCatalog()] {
            let statements = DuplicateTargetConflictResolver(catalog: catalog)
                .dropPlan(target: target, referencing: [], quoting: quoting)

            #expect(statements.map(\.kind) == [.dropTarget])
            #expect(sql(statements) == ["DROP TABLE IF EXISTS \"public\".\"orders_copy\""])
        }
    }

    @Test("PostgreSQL cascades in one statement once the user has said so")
    func postgresCascade() {
        let statements = DuplicateTargetConflictResolver(catalog: PostgreSqlDuplicateCatalog())
            .dropPlan(target: target, referencing: referencing(2), quoting: quoting)

        #expect(statements.map(\.kind) == [.dropTarget])
        #expect(sql(statements) == ["DROP TABLE IF EXISTS \"public\".\"orders_copy\" CASCADE"])
    }

    @Test("MySQL drops each referencing foreign key by name and never writes CASCADE")
    func mysqlDropsForeignKeysExplicitly() {
        let statements = DuplicateTargetConflictResolver(catalog: MySqlDuplicateCatalog())
            .dropPlan(target: target, referencing: referencing(2), quoting: quoting)

        #expect(statements.map(\.kind) == [.dropReferencingForeignKey, .dropReferencingForeignKey, .dropTarget])
        #expect(sql(statements) == [
            "ALTER TABLE \"public\".\"invoices_1\" DROP FOREIGN KEY \"fk_1\"",
            "ALTER TABLE \"public\".\"invoices_2\" DROP FOREIGN KEY \"fk_2\"",
            "DROP TABLE IF EXISTS \"public\".\"orders_copy\"",
        ])
        #expect(!sql(statements).contains { $0.contains("CASCADE") })
    }

    @Test("The PostgreSQL read binds the target name instead of writing it into the SQL")
    func postgresBindsTargetName() async throws {
        let driver = DuplicateDrivingStub()
        let quoted = DuplicateTableRef(schema: "public", name: "it's a table")
        _ = try await PostgreSqlDuplicateCatalog().referencingForeignKeys(quoted, driver: driver)

        let call = try #require(driver.calls.first)
        guard case .parameterized(let sql, let parameters) = call else {
            Issue.record("The read did not take the parameterized path: \(call)")
            return
        }
        #expect(sql.contains("$1::regclass"))
        #expect(!sql.contains("it's a table"))
        #expect(parameters == ["\"public\".\"it's a table\""])
    }

    @Test("The MySQL read binds the schema and the target name")
    func mysqlBindsTargetName() async throws {
        let driver = DuplicateDrivingStub()
        _ = try await MySqlDuplicateCatalog().referencingForeignKeys(
            DuplicateTableRef(schema: "shop", name: "it's a table"),
            driver: driver
        )

        let call = try #require(driver.calls.first)
        guard case .parameterized(let sql, let parameters) = call else {
            Issue.record("The read did not take the parameterized path: \(call)")
            return
        }
        #expect(!sql.contains("it's a table"))
        #expect(!sql.contains("shop"))
        #expect(parameters == ["shop", "it's a table"])
    }

    @Test("With no schema, MySQL asks the server for the current database instead of binding one")
    func mysqlFallsBackToCurrentDatabase() async throws {
        let driver = DuplicateDrivingStub()
        _ = try await MySqlDuplicateCatalog().referencingForeignKeys(
            DuplicateTableRef(schema: nil, name: "orders_copy"),
            driver: driver
        )

        let call = try #require(driver.calls.first)
        guard case .parameterized(let sql, let parameters) = call else {
            Issue.record("The read did not take the parameterized path: \(call)")
            return
        }
        #expect(sql.contains("DATABASE()"))
        #expect(parameters == ["orders_copy"])
    }

    @Test("Rows missing a constraint or a table name are skipped rather than half-read")
    func readerSkipsIncompleteRows() {
        let keys = DuplicateReferencingForeignKeyReader.read([
            ["fk_orders", "public", "invoices"],
            ["", "public", "invoices"],
            [nil, "public", "invoices"],
            ["fk_missing_table", "public", nil],
            ["fk_no_schema", "", "invoices"],
        ])

        #expect(keys == [
            ReferencingForeignKey(constraintName: "fk_orders", owningSchema: "public", owningTable: "invoices"),
            ReferencingForeignKey(constraintName: "fk_no_schema", owningSchema: nil, owningTable: "invoices"),
        ])
    }

    private func sql(_ statements: [DuplicateStatement]) -> [String] {
        statements.compactMap { statement in
            guard case .sql(let sql) = statement.body else { return nil }
            return sql
        }
    }
}
