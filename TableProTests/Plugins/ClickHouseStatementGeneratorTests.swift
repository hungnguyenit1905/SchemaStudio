//
//  ClickHouseStatementGeneratorTests.swift
//  TableProTests
//
//  ClickHouse mutation SQL comes from the driver, not the app's generic
//  SQLStatementGenerator, because ClickHouse spells row mutation as
//  `ALTER TABLE ... UPDATE/DELETE WHERE`. These tests previously lived in
//  SQLStatementGeneratorPKRegressionTests, where they asserted plugin behavior
//  against a generator that can only ever emit `DELETE FROM`, so they could not
//  pass at any point.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("ClickHouse statement generator")
struct ClickHouseStatementGeneratorTests {
    private let columns = ["id", "name", "email"]

    private func generator(
        primaryKeyColumns: [String] = ["id"],
        keyIsUnique: Bool = true
    ) -> ClickHouseStatementGenerator {
        ClickHouseStatementGenerator(
            table: "users",
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            keyIsUnique: keyIsUnique
        )
    }

    private func deleteChange(originalRow: [String?]) -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0,
            type: .delete,
            cellChanges: [],
            originalRow: originalRow.map(PluginCellValue.fromOptional)
        )
    }

    private func updateChange(column: String, columnIndex: Int, to newValue: String, originalRow: [String?])
        -> PluginRowChange {
        PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(
                columnIndex: columnIndex,
                columnName: column,
                oldValue: PluginCellValue.fromOptional(originalRow[columnIndex]),
                newValue: PluginCellValue.text(newValue)
            )],
            originalRow: originalRow.map(PluginCellValue.fromOptional)
        )
    }

    private func delete(
        _ change: PluginRowChange,
        primaryKeyColumns: [String] = ["id"],
        keyIsUnique: Bool = true
    ) throws -> ClickHouseStatementGenerator.Statement {
        let generator = generator(primaryKeyColumns: primaryKeyColumns, keyIsUnique: keyIsUnique)
        let statements = try #require(generator.generateStatements(
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        ))
        #expect(statements.count == 1)
        return try #require(statements.first)
    }

    // MARK: - DELETE

    @Test("Delete uses ALTER TABLE DELETE WHERE with a primary-key-only match")
    func deleteMatchesOnPrimaryKeyOnly() throws {
        let statement = try delete(deleteChange(originalRow: ["1", "John", "john@test.com"]))

        #expect(statement.statement.contains("ALTER TABLE"))
        #expect(statement.statement.contains("DELETE WHERE"))
        #expect(statement.statement.contains("`id` = ?"))
        #expect(!statement.statement.contains("`name`"))
        #expect(!statement.statement.contains("`email`"))
        #expect(statement.parameters == [.text("1")])
    }

    @Test("A composite primary key matches on every key column and nothing else")
    func compositeKeyMatchesEveryKeyColumn() throws {
        let statement = try delete(
            deleteChange(originalRow: ["1", "John", "john@test.com"]),
            primaryKeyColumns: ["id", "email"]
        )

        #expect(statement.statement.contains("`id` = ?"))
        #expect(statement.statement.contains("`email` = ?"))
        #expect(!statement.statement.contains("`name`"))
        #expect(statement.parameters == [.text("1"), .text("john@test.com")])
    }

    @Test("A table with no detected key falls back to matching the full row")
    func noPrimaryKeyFallsBackToFullRow() throws {
        let statement = try delete(
            deleteChange(originalRow: ["1", "John", "john@test.com"]),
            primaryKeyColumns: []
        )

        #expect(statement.statement.contains("`id` = ?"))
        #expect(statement.statement.contains("`name` = ?"))
        #expect(statement.statement.contains("`email` = ?"))
        #expect(statement.parameters.count == 3)
    }

    @Test("A key the engine does not guarantee unique falls back to matching the full row")
    func nonUniqueKeyFallsBackToFullRow() throws {
        let statement = try delete(
            deleteChange(originalRow: ["1", "John", "john@test.com"]),
            primaryKeyColumns: ["id"],
            keyIsUnique: false
        )

        #expect(statement.statement.contains("`id` = ?"))
        #expect(statement.statement.contains("`name` = ?"))
        #expect(statement.statement.contains("`email` = ?"))
        #expect(statement.parameters.count == 3)
    }

    @Test("A primary key column missing from the result set falls back to the full row")
    func partialKeyFallsBackToFullRow() throws {
        let statement = try delete(
            deleteChange(originalRow: ["1", "John", "john@test.com"]),
            primaryKeyColumns: ["id", "tenant_id"]
        )

        #expect(statement.statement.contains("`name` = ?"))
        #expect(statement.parameters.count == 3)
    }

    @Test("A null key value matches with IS NULL and binds no parameter")
    func nullKeyUsesIsNull() throws {
        let statement = try delete(deleteChange(originalRow: [nil, "John", "john@test.com"]))

        #expect(statement.statement.contains("`id` IS NULL"))
        #expect(statement.parameters.isEmpty)
    }

    @Test("A delete whose row index is not marked deleted produces nothing")
    func unmarkedDeleteIsSkipped() {
        let statements = generator().generateStatements(
            changes: [deleteChange(originalRow: ["1", "John", "john@test.com"])],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )
        #expect(statements == nil)
    }

    @Test("A delete with no original row produces nothing")
    func deleteWithoutOriginalRowIsSkipped() {
        let change = PluginRowChange(rowIndex: 0, type: .delete, cellChanges: [], originalRow: nil)
        let statements = generator().generateStatements(
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )
        #expect(statements == nil)
    }

    // MARK: - UPDATE

    @Test("Update uses ALTER TABLE UPDATE with a primary-key-only match")
    func updateMatchesOnPrimaryKeyOnly() throws {
        let change = updateChange(
            column: "name", columnIndex: 1, to: "Jane", originalRow: ["1", "John", "john@test.com"]
        )
        let statements = try #require(generator().generateStatements(
            changes: [change],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        ))
        let statement = try #require(statements.first)

        #expect(statement.statement.contains("ALTER TABLE `users` UPDATE `name` = ?"))
        #expect(statement.statement.contains("WHERE `id` = ?"))
        #expect(!statement.statement.contains("`email`"))
        #expect(statement.parameters == [.text("Jane"), .text("1")])
    }

    // MARK: - INSERT

    @Test("Insert names every column and binds every value")
    func insertBindsEveryColumn() throws {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let values: [PluginCellValue] = [.text("1"), .text("John"), .text("john@test.com")]
        let statements = try #require(generator().generateStatements(
            changes: [change],
            insertedRowData: [0: values],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        ))
        let statement = try #require(statements.first)

        #expect(statement.statement == "INSERT INTO `users` (`id`, `name`, `email`) VALUES (?, ?, ?)")
        #expect(statement.parameters == values)
    }

    @Test("Insert omits columns left at their server default")
    func insertOmitsDefaultMarkers() throws {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        let values: [PluginCellValue] = [.text("__DEFAULT__"), .text("John"), .text("john@test.com")]
        let statements = try #require(generator().generateStatements(
            changes: [change],
            insertedRowData: [0: values],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        ))
        let statement = try #require(statements.first)

        #expect(statement.statement == "INSERT INTO `users` (`name`, `email`) VALUES (?, ?)")
        #expect(statement.parameters.count == 2)
    }

    // MARK: - Identifier quoting

    @Test("A backtick in an identifier is doubled rather than closing the quote")
    func backticksAreEscaped() throws {
        let generator = ClickHouseStatementGenerator(
            table: "we`ird",
            columns: ["id"],
            primaryKeyColumns: ["id"],
            keyIsUnique: true
        )
        let statements = try #require(generator.generateStatements(
            changes: [deleteChange(originalRow: ["1"])],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        ))
        let statement = try #require(statements.first)

        #expect(statement.statement.contains("`we``ird`"))
    }
}
