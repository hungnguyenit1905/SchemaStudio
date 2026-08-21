//
//  GenerationEngineTests.swift
//  TableProTests
//

import Foundation
@testable import SchemaStudio
import TableProPluginKit
import Testing

@Suite("GenerationEngine")
struct GenerationEngineTests {
    private static func shopSchema() -> [GenerationTable] {
        [
            GenerationPlanningFixtures.table("customers", columns: [
                GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                GenerationRuntimeFixtures.textColumn("email")
            ]),
            GenerationPlanningFixtures.table(
                "orders",
                columns: [
                    GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                    GenerationRuntimeFixtures.integerColumn("customer_id")
                ],
                foreignKeys: [GenerationPlanningFixtures.foreignKey(from: "customer_id", to: "customers")]
            )
        ]
    }

    private static func shopProfile(
        customers: Int = 4,
        orders: Int = 8,
        emptyFirst: Bool = false,
        referenceParams: JSONValue = .object([:])
    ) -> GenerationProfile {
        GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile(
                "customers",
                rowCount: customers,
                emptyFirst: emptyFirst,
                columns: [
                    GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                    GenerationRuntimeFixtures.columnProfile("email", generator: "RandomString")
                ]
            ),
            GenerationPlanningFixtures.tableProfile(
                "orders",
                rowCount: orders,
                columns: [
                    GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                    GenerationRuntimeFixtures.columnProfile(
                        "customer_id",
                        generator: "Reference",
                        params: referenceParams
                    )
                ]
            )
        ])
    }

    /// `AutoIncrement` keeps the column out of the insert, which leaves the child
    /// with nothing to point at unless the parent's keys are read back. Tests that
    /// care about foreign keys hand the pool over directly instead.
    private static func customerKeys() -> [ReferenceKey: [[PluginCellValue]]] {
        [
            ReferenceKey(schema: "public", table: "customers", columns: ["id"]): [
                [.int(1)], [.int(2)], [.int(3)], [.int(4)]
            ]
        ]
    }

    @Test("Tables are written parent before child")
    func dependencyOrderIsRespected() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        let plan = try GenerationRuntimeFixtures.plan(profile: Self.shopProfile(), schema: Self.shopSchema())
        let engine = GenerationRuntimeFixtures.engine(driver: driver)

        let events = try await GenerationRuntimeFixtures.collect(engine.run(plan: plan))

        #expect(driver.insertedTableOrder == ["public.customers", "public.orders"])
        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        #expect(report.totalRowsWritten == 12)
        #expect(!report.wasCancelled)
    }

    @Test("Every foreign key value comes from the parent pool")
    func foreignKeysPointAtRealParents() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        let plan = try GenerationRuntimeFixtures.plan(profile: Self.shopProfile(), schema: Self.shopSchema())

        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        let columns = driver.columns(for: "orders")
        let position = try #require(columns.firstIndex(of: "customer_id"))
        let values = driver.rows(for: "orders").map { $0[position].textFallback }
        #expect(values.count == 8)
        #expect(values.allSatisfy { ["1", "2", "3", "4"].contains($0) })
    }

    @Test("A one to one foreign key is refused before anything is written when the parent is too small")
    func oneToOneIsMeasuredBeforeTheRun() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.shopProfile(referenceParams: .object(["strategy": .string("oneToOne")])),
            schema: Self.shopSchema()
        )

        await #expect(throws: GenerationError.referencePoolTooSmall(
            table: "public.customers",
            columns: ["id"],
            poolCount: 4,
            rowCount: 8
        )) {
            _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))
        }
        #expect(driver.rows(for: "orders").isEmpty)
    }

    @Test("A one to one foreign key gives every child its own parent")
    func oneToOnePairsRowsWithParents() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.shopProfile(orders: 4, referenceParams: .object(["strategy": .string("oneToOne")])),
            schema: Self.shopSchema()
        )

        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        let position = try #require(driver.columns(for: "orders").firstIndex(of: "customer_id"))
        let values = driver.rows(for: "orders").map { $0[position].textFallback }
        #expect(Set(values).count == values.count)
        #expect(Set(values) == ["1", "2", "3", "4"])
    }

    @Test("Ensure coverage gives every parent at least one child")
    func ensureCoverageReachesEveryParent() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.shopProfile(referenceParams: .object(["strategy": .string("ensureCoverage")])),
            schema: Self.shopSchema()
        )

        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        let position = try #require(driver.columns(for: "orders").firstIndex(of: "customer_id"))
        let values = driver.rows(for: "orders").map { $0[position].textFallback }
        #expect(values.count == 8)
        #expect(Set(values) == ["1", "2", "3", "4"])
    }

    @Test("Emptying a table first is refused on a connection that blocks destructive operations")
    func emptyFirstIsRefusedWhenBlocked() async throws {
        let driver = FakeGenerationDriver(blocksDestructiveOperations: true)
        driver.preloadedValues = Self.customerKeys()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.shopProfile(emptyFirst: true),
            schema: Self.shopSchema()
        )

        await #expect(throws: GenerationError.destructiveOperationBlocked(table: "public.customers")) {
            _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))
        }
        #expect(driver.batches.isEmpty)
        #expect(driver.emptied.isEmpty)
    }

    @Test("Emptying a table uses DELETE when a foreign key points at it")
    func emptyFirstAvoidsTruncateUnderInboundKeys() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        driver.inboundForeignKeyTables = ["customers"]
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.shopProfile(emptyFirst: true),
            schema: Self.shopSchema()
        )

        _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))

        #expect(driver.emptied.count == 1)
        #expect(driver.emptied[0].table.table == "customers")
        #expect(driver.emptied[0].allowsTruncate == false)
    }

    @Test("Cancelling mid-table reports how many rows landed")
    func cancellationReportsRowsWritten() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.shopProfile(customers: 20_000, orders: 1),
            schema: Self.shopSchema()
        )
        let engine = GenerationRuntimeFixtures.engine(driver: driver)
        driver.onInsert = { [engine] batches in
            guard batches == 2 else { return }
            await engine.cancel()
        }

        var cancelled: Int?
        for try await event in engine.run(plan: plan) {
            if case .cancelled(let rows) = event { cancelled = rows }
        }

        let rowsWritten = try #require(cancelled)
        #expect(rowsWritten > 0)
        #expect(rowsWritten < 20_000)
        #expect(driver.rows(for: "orders").isEmpty)
    }

    @Test("A failed batch stops the run unless the profile asks to continue")
    func failedBatchStopsTheRun() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        driver.failInsertsFor = ["orders"]
        let plan = try GenerationRuntimeFixtures.plan(profile: Self.shopProfile(), schema: Self.shopSchema())

        await #expect(throws: GenerationError.self) {
            _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))
        }
    }

    @Test("Continuing on error records the failed batches and finishes the run")
    func continueOnErrorReportsFailedBatches() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        driver.failInsertsFor = ["orders"]
        var options = GenerationRunOptions()
        options.continueOnError = true
        let plan = try GenerationRuntimeFixtures.plan(profile: Self.shopProfile(), schema: Self.shopSchema())

        let events = try await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(driver: driver, options: options).run(plan: plan)
        )

        let report = try #require(GenerationRuntimeFixtures.report(in: events))
        #expect(report.totalRowsWritten == 4)
        #expect(report.totalFailedBatches == 1)
        #expect(GenerationRuntimeFixtures.batchFailures(in: events).count == 1)
    }

    @Test("Foreign key checks are turned back on when a batch throws")
    func constraintsAreRestoredOnThrow() async throws {
        let driver = FakeGenerationDriver()
        driver.failInsertsFor = ["nodes"]
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.cycleProfile(),
            schema: Self.cycleSchema(),
            canDisableConstraints: true
        )
        #expect(plan.requiresConstraintDisable)

        await #expect(throws: GenerationError.self) {
            _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))
        }
        #expect(driver.foreignKeyCheckCalls == [false, true])
    }

    @Test("Foreign key checks are turned back on when the run is cancelled")
    func constraintsAreRestoredOnCancel() async throws {
        let driver = FakeGenerationDriver()
        let plan = try GenerationRuntimeFixtures.plan(
            profile: Self.cycleProfile(rowCount: 20_000),
            schema: Self.cycleSchema(),
            canDisableConstraints: true
        )
        let engine = GenerationRuntimeFixtures.engine(driver: driver)
        driver.onInsert = { [engine] batches in
            guard batches == 1 else { return }
            await engine.cancel()
        }

        var cancelled: Int?
        for try await event in engine.run(plan: plan) {
            if case .cancelled(let rows) = event { cancelled = rows }
        }

        #expect(cancelled != nil)
        #expect(driver.foreignKeyCheckCalls == [false, true])
    }

    @Test("A single-transaction run commits once and rolls back once on failure")
    func singleTransactionRollsBack() async throws {
        let driver = FakeGenerationDriver()
        driver.preloadedValues = Self.customerKeys()
        driver.failInsertsFor = ["orders"]
        var options = GenerationRunOptions()
        options.singleTransaction = true
        let plan = try GenerationRuntimeFixtures.plan(profile: Self.shopProfile(), schema: Self.shopSchema())

        await #expect(throws: GenerationError.self) {
            _ = try await GenerationRuntimeFixtures.collect(
                GenerationRuntimeFixtures.engine(driver: driver, options: options).run(plan: plan)
            )
        }
        #expect(driver.transactionCalls == ["begin", "rollback"])
    }

    @Test("A run against an empty parent fails when the foreign key cannot be null")
    func emptyParentIsRefused() async throws {
        let driver = FakeGenerationDriver()
        let plan = try GenerationRuntimeFixtures.plan(profile: Self.shopProfile(), schema: Self.shopSchema())

        await #expect(throws: GenerationError.self) {
            _ = try await GenerationRuntimeFixtures.collect(GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan))
        }
    }

    @Test("A nullable foreign key degrades to null when the parent is empty")
    func emptyParentDegradesToNull() async throws {
        let driver = FakeGenerationDriver()
        let schema = [
            GenerationPlanningFixtures.table("customers", columns: [
                GenerationRuntimeFixtures.integerColumn("id", primaryKey: true)
            ]),
            GenerationPlanningFixtures.table(
                "orders",
                columns: [
                    GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                    GenerationRuntimeFixtures.integerColumn("customer_id", nullable: true)
                ],
                foreignKeys: [GenerationPlanningFixtures.foreignKey(from: "customer_id", to: "customers")]
            )
        ]
        let profile = GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile("customers", rowCount: 0, columns: [
                GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement")
            ]),
            GenerationPlanningFixtures.tableProfile("orders", rowCount: 3, columns: [
                GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                GenerationRuntimeFixtures.columnProfile("customer_id", generator: "Reference")
            ])
        ])
        let plan = try GenerationRuntimeFixtures.plan(profile: profile, schema: schema)

        let events = try await GenerationRuntimeFixtures.collect(
            GenerationRuntimeFixtures.engine(driver: driver).run(plan: plan)
        )

        let position = try #require(driver.columns(for: "orders").firstIndex(of: "customer_id"))
        #expect(driver.rows(for: "orders").allSatisfy { $0[position].isNull })
        #expect(GenerationRuntimeFixtures.report(in: events) != nil)
    }

    private static func cycleSchema() -> [GenerationTable] {
        [
            GenerationPlanningFixtures.table(
                "nodes",
                columns: [
                    GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                    GenerationRuntimeFixtures.integerColumn("edge_id")
                ],
                foreignKeys: [GenerationPlanningFixtures.foreignKey(from: "edge_id", to: "edges")]
            ),
            GenerationPlanningFixtures.table(
                "edges",
                columns: [
                    GenerationRuntimeFixtures.integerColumn("id", primaryKey: true),
                    GenerationRuntimeFixtures.integerColumn("node_id")
                ],
                foreignKeys: [GenerationPlanningFixtures.foreignKey(from: "node_id", to: "nodes")]
            )
        ]
    }

    private static func cycleProfile(rowCount: Int = 4) -> GenerationProfile {
        GenerationPlanningFixtures.profile(tables: [
            GenerationPlanningFixtures.tableProfile("nodes", rowCount: rowCount, columns: [
                GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                GenerationRuntimeFixtures.columnProfile("edge_id", generator: "Integer")
            ]),
            GenerationPlanningFixtures.tableProfile("edges", rowCount: rowCount, columns: [
                GenerationRuntimeFixtures.columnProfile("id", generator: "AutoIncrement"),
                GenerationRuntimeFixtures.columnProfile("node_id", generator: "Integer")
            ])
        ])
    }
}
