//
//  SecondPassUpdaterTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("SecondPassUpdater")
struct SecondPassUpdaterTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func employeesPlan(rowCount: Int = 5) throws -> TablePlan {
        let table = Fixtures.table(
            "employees",
            columns: [
                PluginColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true),
                PluginColumnInfo(name: "manager_id", dataType: "bigint")
            ],
            foreignKeys: [Fixtures.foreignKey(from: "manager_id", to: "employees")]
        )
        let id = try #require(table.column(named: "id"))
        let manager = try #require(table.column(named: "manager_id"))
        return TablePlan(
            reference: GenerationTableReference(schema: "public", table: "employees"),
            rowCount: rowCount,
            emptyFirst: false,
            columns: [
                ColumnPlan(
                    column: id,
                    generator: "AutoIncrement",
                    params: Data(),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                ),
                ColumnPlan(
                    column: manager,
                    generator: "Reference",
                    params: Data(),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                )
            ],
            insertColumns: ["id", "manager_id"],
            deferredColumns: ["manager_id"],
            uniqueConstraints: [],
            primaryKeyColumns: ["id"],
            sequenceBackedColumns: []
        )
    }

    private func driver(keys: [Int64]) -> FakeGenerationDriver {
        let driver = FakeGenerationDriver()
        driver.preloadedValues[
            ReferenceKey(schema: "public", table: "employees", columns: ["id"])
        ] = keys.map { [PluginCellValue.int($0)] }
        return driver
    }

    private func harvested(_ keys: [Int64]) -> [[PluginCellValue]] {
        keys.map { [PluginCellValue.int($0)] }
    }

    @Test("A self-reference is filled from the keys the table now has")
    func selfReferenceIsFilled() async throws {
        let fake = driver(keys: [1, 2, 3, 4, 5])
        let outcome = try await SecondPassUpdater(driver: fake, poolLimit: 100)
            .fill(table: try employeesPlan(), runSeed: 7, harvestedOwnKeys: harvested([1, 2, 3, 4, 5]))

        #expect(outcome.rowsUpdated == 5)
        #expect(outcome.warnings.isEmpty)
        let update = try #require(fake.updates.first)
        #expect(update.table.table == "employees")
        #expect(update.setColumns == ["manager_id"])
        #expect(update.keyColumns == ["id"])
        #expect(update.assignments.count == 5)
        for assignment in update.assignments {
            #expect(assignment.count == 2)
        }
    }

    @Test("No row is made its own parent")
    func neverPointsAtItself() async throws {
        let fake = driver(keys: Array(1 ... 20))
        _ = try await SecondPassUpdater(driver: fake, poolLimit: 100)
            .fill(table: try employeesPlan(rowCount: 20), runSeed: 3, harvestedOwnKeys: harvested(Array(1 ... 20)))
        let update = try #require(fake.updates.first)
        for assignment in update.assignments {
            #expect(assignment[0].stableHash != assignment[1].stableHash)
        }
    }

    @Test("A single row has nobody else to point at, so it stays empty")
    func singleRowStaysEmpty() async throws {
        let fake = driver(keys: [1])
        let outcome = try await SecondPassUpdater(driver: fake, poolLimit: 100)
            .fill(table: try employeesPlan(rowCount: 1), runSeed: 3, harvestedOwnKeys: harvested([1]))
        #expect(outcome.rowsUpdated == 0)
        #expect(fake.updates.isEmpty)
    }

    @Test("The same seed fills the same parents")
    func fillIsDeterministic() async throws {
        func run() async throws -> [[PluginCellValue]] {
            let fake = driver(keys: Array(1 ... 10))
            _ = try await SecondPassUpdater(driver: fake, poolLimit: 100)
                .fill(table: try employeesPlan(rowCount: 10), runSeed: 11, harvestedOwnKeys: harvested(Array(1 ... 10)))
            return fake.updates.first?.assignments ?? []
        }
        let first = try await run()
        let second = try await run()
        #expect(first.map { $0.map(\.textFallback) } == second.map { $0.map(\.textFallback) })
    }

    @Test("A table with no primary key says why it cannot be filled")
    func withoutPrimaryKeyItWarns() async throws {
        var plan = try employeesPlan()
        plan = TablePlan(
            reference: plan.reference,
            rowCount: plan.rowCount,
            emptyFirst: false,
            columns: plan.columns,
            insertColumns: plan.insertColumns,
            deferredColumns: plan.deferredColumns,
            uniqueConstraints: [],
            primaryKeyColumns: [],
            sequenceBackedColumns: []
        )
        let fake = driver(keys: [1, 2, 3])
        let outcome = try await SecondPassUpdater(driver: fake, poolLimit: 100)
            .fill(table: plan, runSeed: 1, harvestedOwnKeys: harvested([1, 2, 3]))
        #expect(outcome.rowsUpdated == 0)
        #expect(fake.updates.isEmpty)
        let warning = try #require(outcome.warnings.first)
        #expect(warning.message.contains("employees"))
        #expect(warning.message.contains("manager_id"))
    }

    @Test("An empty parent leaves the column empty with a warning, not an error")
    func emptyParentWarns() async throws {
        let fake = FakeGenerationDriver()
        let outcome = try await SecondPassUpdater(driver: fake, poolLimit: 100)
            .fill(table: try employeesPlan(), runSeed: 1, harvestedOwnKeys: [])
        #expect(outcome.rowsUpdated == 0)
        #expect(fake.updates.isEmpty)
    }

    @Test("An append run with no harvested keys warns and leaves the column null instead of reading the table")
    func appendWithoutHarvestWarnsAndLeavesColumnNull() async throws {
        let fake = driver(keys: [1, 2, 3])
        let outcome = try await SecondPassUpdater(driver: fake, poolLimit: 100)
            .fill(table: try employeesPlan(), runSeed: 1, harvestedOwnKeys: nil)

        #expect(outcome.rowsUpdated == 0)
        #expect(fake.updates.isEmpty)
        let warning = try #require(outcome.warnings.first)
        #expect(warning.message.contains("employees"))
        #expect(warning.message.contains("manager_id"))
    }

    @Test("A table with nothing deferred is not touched")
    func nothingDeferredDoesNothing() async throws {
        let plan = try employeesPlan()
        let quiet = TablePlan(
            reference: plan.reference,
            rowCount: plan.rowCount,
            emptyFirst: false,
            columns: plan.columns,
            insertColumns: plan.insertColumns,
            deferredColumns: [],
            uniqueConstraints: [],
            primaryKeyColumns: plan.primaryKeyColumns,
            sequenceBackedColumns: []
        )
        let fake = driver(keys: [1, 2])
        let outcome = try await SecondPassUpdater(driver: fake, poolLimit: 100)
            .fill(table: quiet, runSeed: 1, harvestedOwnKeys: nil)
        #expect(outcome.rowsUpdated == 0)
        #expect(fake.updates.isEmpty)
    }
}

@Suite("SequenceResetter")
struct SequenceResetterTests {
    private typealias Fixtures = GenerationPlanningFixtures

    private func plan(sequenceBacked: [SequenceBackedColumn]) throws -> TablePlan {
        let table = Fixtures.table(
            "orders",
            columns: [PluginColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true)]
        )
        let id = try #require(table.column(named: "id"))
        return TablePlan(
            reference: GenerationTableReference(schema: "public", table: "orders"),
            rowCount: 3,
            emptyFirst: false,
            columns: [
                ColumnPlan(
                    column: id,
                    generator: "Integer",
                    params: Data(),
                    common: .none,
                    excludedFromInsert: false,
                    dependencies: []
                )
            ],
            insertColumns: ["id"],
            deferredColumns: [],
            uniqueConstraints: [],
            primaryKeyColumns: ["id"],
            sequenceBackedColumns: sequenceBacked
        )
    }

    @Test("Every sequence the run wrote into is reset")
    func resetsEachSequence() async throws {
        let fake = FakeGenerationDriver()
        let warnings = await SequenceResetter(driver: fake).reset(
            table: try plan(sequenceBacked: [
                SequenceBackedColumn(column: "id", sequenceName: "orders_id_seq")
            ])
        )
        #expect(fake.sequenceResets == [
            FakeGenerationDriver.SequenceReset(table: "orders", column: "id", sequenceName: "orders_id_seq")
        ])
        #expect(warnings.isEmpty)
    }

    @Test("A table the server filled itself has no sequence to reset")
    func nothingToReset() async throws {
        let fake = FakeGenerationDriver()
        let warnings = await SequenceResetter(driver: fake).reset(table: try plan(sequenceBacked: []))
        #expect(fake.sequenceResets.isEmpty)
        #expect(warnings.isEmpty)
    }

    @Test("A column with no named sequence still asks the driver, which knows its own vendor")
    func unnamedSequenceStillResets() async throws {
        let fake = FakeGenerationDriver()
        let warnings = await SequenceResetter(driver: fake).reset(
            table: try plan(sequenceBacked: [SequenceBackedColumn(column: "id", sequenceName: nil)])
        )
        #expect(fake.sequenceResets.first?.sequenceName == nil)
        #expect(fake.sequenceResets.count == 1)
        #expect(warnings.isEmpty)
    }

    @Test("A column whose reset fails is reported back as a warning, not thrown")
    func failedResetBecomesAWarning() async throws {
        let fake = FakeGenerationDriver()
        fake.failsSequenceReset = true
        let warnings = await SequenceResetter(driver: fake).reset(
            table: try plan(sequenceBacked: [SequenceBackedColumn(column: "id", sequenceName: "orders_id_seq")])
        )
        #expect(fake.sequenceResets.isEmpty)
        #expect(warnings.count == 1)
        #expect(warnings.first?.column == "public.orders.id")
    }
}

@Suite("GenerationPlanCompiler sequence and unique facts")
struct GenerationPlanSequenceFactsTests {
    private typealias Fixtures = GenerationPlanningFixtures

    @Test("A column the run writes into a sequence-backed key is recorded for the reset")
    func writtenSequenceColumnIsRecorded() throws {
        let schema = [Fixtures.table("orders", columns: [
            PluginColumnInfo(
                name: "id",
                dataType: "bigint",
                isNullable: false,
                isPrimaryKey: true,
                checkExpressions: [],
                sequenceName: "orders_id_seq"
            )
        ])]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("orders", columns: [
                GenerationColumnProfile(column: "id", generator: "AutoIncrement")
            ])
        ])
        let explicit = Fixtures.profile(tables: [
            Fixtures.tableProfile("orders", columns: [
                GenerationColumnProfile(column: "id", generator: "Integer")
            ])
        ])

        let leftToServer = try GenerationPlanCompiler().compile(profile: profile, schema: schema)
        #expect(leftToServer.tables.first?.sequenceBackedColumns.isEmpty == true)

        let written = try GenerationPlanCompiler().compile(profile: explicit, schema: schema)
        #expect(written.tables.first?.sequenceBackedColumns == [
            SequenceBackedColumn(column: "id", sequenceName: "orders_id_seq")
        ])
    }

    @Test("A composite unique constraint reaches the plan")
    func compositeConstraintReachesThePlan() throws {
        let schema = [Fixtures.table(
            "stores",
            columns: [
                PluginColumnInfo(name: "country", dataType: "varchar(2)", isNullable: false),
                PluginColumnInfo(name: "slug", dataType: "varchar(32)", isNullable: false)
            ],
            indexes: [
                PluginIndexInfo(name: "stores_country_slug_key", columns: ["country", "slug"], isUnique: true)
            ]
        )]
        let profile = Fixtures.profile(tables: [
            Fixtures.tableProfile("stores", columns: [
                GenerationColumnProfile(column: "country", generator: "RandomString"),
                GenerationColumnProfile(column: "slug", generator: "RandomString")
            ])
        ])
        let plan = try GenerationPlanCompiler().compile(profile: profile, schema: schema)
        #expect(plan.tables.first?.uniqueConstraints.first?.columns == ["country", "slug"])
        #expect(plan.tables.first?.primaryKeyColumns.isEmpty == true)
    }
}
